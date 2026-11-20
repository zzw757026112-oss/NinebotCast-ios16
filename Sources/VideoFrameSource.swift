import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// 相册视频源 v3。
///
/// v0.14（v2）用固定 40ms 定时器解码，且让 AVAssetReader 每帧把视频转成 BGRA
/// （这步软件转换最贵），一帧耗时超预算就掉帧——实测还是「一帧一帧播」。
/// v3 改成：
/// - 专用解码线程循环跑，节奏跟随视频自身时间戳（PTS 差值），原速播放，和
///   视频帧率 / 投屏帧率无关；
/// - 读出端直接要原生 420YpCbCr（解码器原生格式，跳过每帧 BGRA 转换），
///   CIImage 渲染时自动做色彩矩阵转换；
/// - 3 块目标 buffer 轮换，latestFrame() 供发送端取最新帧，互不阻塞。
final class VideoFrameSource {
    private let url: URL
    private let width: Int
    private let height: Int
    private let rotation: Int
    private let fps: Int
    private let ciContext: CIContext
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var destBuffers: [CVPixelBuffer] = []
    private var destIndex = 0
    private var latestBuffer: CVPixelBuffer?
    private var running = false
    private(set) var failed = false

    init(url: URL, width: Int, height: Int, rotation: Int, fps: Int) {
        self.url = url
        self.width = width
        self.height = height
        self.rotation = rotation
        self.fps = max(1, fps)
        self.ciContext = CIContext(options: nil)
    }

    func start() {
        guard !running else { return }
        running = true
        let thread = Thread { [weak self] in
            self?.decodeLoop()
        }
        thread.name = "ninebotcast.videodecode"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// 解码线程主循环：解一帧 → 渲染 → 按视频 PTS 差值睡到下一帧时刻
    private func decodeLoop() {
        var lastPTS: Double = -1
        while running {
            autoreleasepool {
                lock.lock()
                if reader == nil || output == nil {
                    if !failed {
                        openReaderLocked()
                    }
                }
                let sample = (reader?.status == .reading) ? output?.copyNextSampleBuffer() : nil
                if sample == nil {
                    // 播完一轮或 reader 失效：重开实现循环；若已 failed 则退出线程
                    if failed {
                        lock.unlock()
                        running = false
                        return
                    }
                    reader?.cancelReading()
                    reader = nil
                    output = nil
                    openReaderLocked()
                    if reader == nil {
                        lock.unlock()
                        running = false
                        return
                    }
                    lastPTS = -1
                    lock.unlock()
                    Thread.sleep(forTimeInterval: 0.05)
                    return
                }
                // 3 块 buffer 轮换，避免覆盖还在编码的帧
                let dest: CVPixelBuffer
                if destBuffers.count < 3 {
                    if let fresh = FrameRenderer.makeBuffer(width: width, height: height) {
                        destBuffers.append(fresh)
                        dest = fresh
                    } else {
                        lock.unlock()
                        return
                    }
                } else {
                    destIndex = (destIndex + 1) % destBuffers.count
                    dest = destBuffers[destIndex]
                }
                renderLocked(sample!, into: dest)
                latestBuffer = dest
                lock.unlock()

                // 按 PTS 差值节奏睡：这是「原速播放」的关键
                let pts = CMSampleBufferGetPresentationTimeStamp(sample!).seconds
                if lastPTS >= 0, pts > lastPTS {
                    var delta = pts - lastPTS
                    if delta > 0.25 { delta = 0.25 }      // 掉帧后不猛追
                    if delta < 0.005 { delta = 0.005 }    // 变帧率视频兜底
                    Thread.sleep(forTimeInterval: delta)
                }
                lastPTS = pts
            }
        }
    }

    /// 需已持有 lock
    private func openReaderLocked() {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            Diag.log("视频源：没有视频轨道 \(url.lastPathComponent)")
            failed = true
            return
        }
        guard let newReader = try? AVAssetReader(asset: asset) else {
            Diag.log("视频源：AVAssetReader 创建失败")
            failed = true
            return
        }
        // 原生 YUV：解码器直接输出，跳过每帧 BGRA 软件转换（v2 卡顿主因）
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        trackOutput.alwaysCopiesSampleData = false
        newReader.add(trackOutput)
        guard newReader.startReading() else {
            Diag.log("视频源：startReading 失败 \(String(describing: newReader.error))")
            failed = true
            return
        }
        self.reader = newReader
        self.output = trackOutput
        let size = track.naturalSize
        Diag.log("视频源已打开 \(Int(size.width))x\(Int(size.height)) → \(width)x\(height) rot=\(rotation) 原速PTS节奏")
    }

    /// 需已持有 lock
    private func renderLocked(_ sample: CMSampleBuffer, into dest: CVPixelBuffer) {
        guard let src = CMSampleBufferGetImageBuffer(sample) else { return }
        var ci = CIImage(cvPixelBuffer: src)
        switch rotation {
        case 90: ci = ci.oriented(.right)
        case 180: ci = ci.oriented(.down)
        case 270: ci = ci.oriented(.left)
        default: break
        }
        ci = FrameRenderer.aspectFillTransform(ci, destWidth: width, destHeight: height,
                                               mode: UserDefaults.standard.integer(forKey: "nbc.displayMode"))
        ciContext.render(ci, to: dest,
                         bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    /// 发送线程调用：拿最新解码好的帧（解码跟不上时重复取同一帧，画面依然连续）
    func latestFrame() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestBuffer
    }

    func stop() {
        running = false
        lock.lock()
        reader?.cancelReading()
        reader = nil
        output = nil
        latestBuffer = nil
        lock.unlock()
    }
}
