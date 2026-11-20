import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// 摄像头源 v2。
///
/// v0.15 在发送节拍里同步做 CI 渲染（720p→仪表尺寸），渲染+编码挤在同一线程，
/// 一拍超时就掉帧——实测「超级卡」。v2 改成和视频源同样的架构：
/// - 采集回调只存最新原始帧（零开销）；
/// - 独立渲染线程按投屏帧率把最新原始帧渲染成目标尺寸
///   （原始帧没变化就跳过，静态场景几乎零 CPU）；
/// - 3 块目标 buffer 轮换；发送端只取渲染好的成品，零等待。
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "ninebotcast.camera")
    private let renderQueue = DispatchQueue(label: "ninebotcast.camerarender")
    private let lock = NSLock()
    private var latestRaw: CVPixelBuffer?
    private var latestRendered: CVPixelBuffer?
    private var lastRenderedRaw: CVPixelBuffer?
    private var destBuffers: [CVPixelBuffer] = []
    private var destIndex = 0
    private var targetWidth = 0
    private var targetHeight = 0
    private var rotation = 0
    private var fps = 25
    private var ciContext: CIContext?
    private var renderInFlight = false
    private var configured = false
    private(set) var active = false

    /// 启动采集 + 渲染线程；err 非 nil 表示失败原因
    func start(position: AVCaptureDevice.Position,
               targetWidth: Int, targetHeight: Int,
               rotation: Int, fps: Int,
               completion: ((String?) -> Void)? = nil) {
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.rotation = rotation
        self.fps = max(1, fps)
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            sessionQueue.async { [weak self] in
                guard let self else { return }
                let err = self.configure(position: position)
                completion?(err)
            }
        case .notDetermined:
            Diag.log("camera: 首次使用，请求相机权限")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.start(position: position, targetWidth: targetWidth,
                                targetHeight: targetHeight, rotation: rotation,
                                fps: fps, completion: completion)
                } else {
                    Diag.log("camera: 相机权限被拒绝")
                    completion?("相机权限被拒绝：去 设置 > 隐私与安全性 > 相机 里打开")
                }
            }
        case .denied, .restricted:
            Diag.log("camera: 相机权限被拒绝/受限")
            completion?("相机权限被拒绝：去 设置 > 隐私与安全性 > 相机 里打开")
        @unknown default:
            completion?("相机权限状态未知")
        }
    }

    private func configure(position: AVCaptureDevice.Position) -> String? {
        Diag.log("camera: 开始配置（\(position == .front ? "前置" : "后置")）目标 \(targetWidth)x\(targetHeight) rot=\(rotation) @\(fps)fps")
        guard !configured else { return nil }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position) else {
            session.commitConfiguration()
            Diag.log("camera: 找不到摄像头设备")
            return "没有找到\(position == .front ? "前置" : "后置")摄像头"
        }
        Diag.log("camera: 设备 OK \(device.localizedName)")
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                Diag.log("camera: canAddInput false")
                return "摄像头输入添加失败"
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            Diag.log("camera: 输入创建异常 \(error.localizedDescription)")
            return "摄像头输入创建失败：\(error.localizedDescription)"
        }
        Diag.log("camera: 输入 OK")

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            Diag.log("camera: canAddOutput false")
            return "摄像头输出添加失败"
        }
        session.addOutput(output)
        Diag.log("camera: 输出 OK")

        // v0.14 的闪退真凶：commit 必须发生在 startRunning 之前
        session.commitConfiguration()
        Diag.log("camera: commitConfiguration 完成，启动 session")
        session.startRunning()
        configured = true
        active = true
        Diag.log("camera: 已启动，开始出帧")
        return nil
    }

    // MARK: - 实时渲染（帧到即渲染，不靠定时器，少一层等待）

    /// 渲染线程调用：把最新原始帧渲染成目标尺寸
    private func renderLatest() {
        lock.lock()
        let raw = latestRaw
        lock.unlock()
        guard let raw else { return }

        let w = targetWidth, h = targetHeight
        guard w > 16, h > 16 else { return }
        if ciContext == nil { ciContext = CIContext(options: nil) }
        guard let ciContext else { return }

        // 3 块 buffer 轮换，避免覆盖还在编码的帧
        let dest: CVPixelBuffer
        lock.lock()
        let sizeOK = !destBuffers.isEmpty
            && CVPixelBufferGetWidth(destBuffers[0]) == w
            && CVPixelBufferGetHeight(destBuffers[0]) == h
        if destBuffers.count < 3 || !sizeOK {
            guard let fresh = FrameRenderer.makeBuffer(width: w, height: h) else {
                lock.unlock()
                return
            }
            if destBuffers.count >= 3 { destBuffers.removeAll() }
            destBuffers.append(fresh)
            destIndex = destBuffers.count - 1
            dest = fresh
        } else {
            destIndex = (destIndex + 1) % destBuffers.count
            dest = destBuffers[destIndex]
        }
        lock.unlock()

        var ci = CIImage(cvPixelBuffer: raw)
        switch rotation {
        case 90: ci = ci.oriented(.right)
        case 180: ci = ci.oriented(.down)
        case 270: ci = ci.oriented(.left)
        default: break
        }
        ci = FrameRenderer.aspectFillTransform(ci, destWidth: w, destHeight: h)
        ciContext.render(ci, to: dest,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h),
                         colorSpace: CGColorSpaceCreateDeviceRGB())

        lock.lock()
        latestRendered = dest
        lastRenderedRaw = raw
        lock.unlock()
    }

    // MARK: - 采集回调：只存原始帧 + 触发渲染

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latestRaw = pb
        // 上一帧还在渲染就跳过这一帧；渲染完成后下一帧自然会再触发
        let go = !renderInFlight
        if go { renderInFlight = true }
        lock.unlock()
        guard go else { return }
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.renderLatest()
            self.lock.lock()
            self.renderInFlight = false
            self.lock.unlock()
        }
    }

    /// 发送线程调用：拿最新渲染好的成品（零等待）
    func renderedFrame() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestRendered
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.configured else { return }
            self.session.stopRunning()
            self.configured = false
            self.active = false
            self.lock.lock()
            self.latestRaw = nil
            self.latestRendered = nil
            self.lastRenderedRaw = nil
            self.lock.unlock()
            Diag.log("camera: 已停止")
        }
    }
}
