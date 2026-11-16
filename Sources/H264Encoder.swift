import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox

/// VideoToolbox H.264 硬编码器，输出 Annex-B 流（每帧前自带 SPS/PPS）
///
/// 本版为「防闪退」加固版，重点修两个真实隐患：
/// 1. `CMBlockBufferGetDataPointer` 拿到的指针不一定覆盖整帧（块缓冲可能不连续），
///    按 totalLength 强行读会越界崩溃 —— 改为 `CMBlockBufferCopyDataBytes` 拷贝。
/// 2. refcon 里存的是未持有的 self，若编码器对象先被释放、VT 回调后到，
///    就是 use-after-free。现在由 CastEngine 负责保活（退役实例不释放），
///    并在 teardown 时先 CompleteFrames 再 Invalidate。
final class H264Encoder {
    /// (annexB 数据, 是否关键帧)
    var onAnnexBFrame: ((Data, Bool) -> Void)?

    private var session: VTCompressionSession?
    private var parameterSets: Data?
    private var isTornDown = true
    private var encodedCount = 0

    func setup(width: Int, height: Int, fps: Int32, bitrate: UInt32, gop: Int = 10) -> Bool {
        teardown()
        guard width > 0, height > 0, fps > 0 else {
            Diag.log("VT setup 参数非法 \(width)x\(height) fps=\(fps)")
            return false
        }
        isTornDown = false
        encodedCount = 0

        var sessionOut: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: { refcon, _, status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer, let refcon else { return }
                let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
                guard !encoder.isTornDown else { return }
                encoder.handleOutput(sampleBuffer: sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &sessionOut)

        guard status == noErr, let session = sessionOut else {
            Diag.log("VTCompressionSessionCreate 失败 status=\(status)")
            return false
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: Int(fps)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: max(1, gop))) // 官方 gopSize = 10
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        // 低延迟：编码器不许攒帧，出一帧交一帧
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                             value: NSNumber(value: 0))
        // 码率限幅（1.25 倍均值）：不让关键帧远超均值，
        // 大 I 帧会在发送队列里排队，排在后面的包全跟着延迟
        let bytesPerSecond = max(1, Int(bitrate) / 8 * 5 / 4)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: "\(bytesPerSecond),1" as CFString)

        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            Diag.log("VTCompressionSessionPrepareToEncodeFrames 失败")
            VTCompressionSessionInvalidate(session)
            return false
        }
        self.session = session
        Diag.log("VT 编码器就绪 \(width)x\(height) fps=\(fps) \(bitrate / 1000)kbps")
        return true
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session, !isTornDown else { return }
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil)
        if status != noErr && status != kVTVideoEncoderMalfunctionErr {
            Diag.log("VT encode 返回 \(status)")
        }
    }

    /// 仪表通过 RTCP APP 子类型 3 请求改码率时调用
    func updateBitrate(_ bitrate: UInt32) {
        guard let session, !isTornDown,
              bitrate >= 200_000, bitrate <= 8_000_000 else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))
    }

    func teardown() {
        isTornDown = true
        if let session {
            // 先把在飞的帧全部编码完，再失效，避免回调打到已失效会话上
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        parameterSets = nil
    }

    deinit {
        teardown()
    }

    private func handleOutput(sampleBuffer: CMSampleBuffer) {
        if let desc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = Self.parameterSets(from: desc)
        }

        var isKeyFrame = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[String: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            isKeyFrame = !notSync
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return }

        // 不依赖「块缓冲一定连续」：整段拷出来，天然没有越界风险
        var raw = Data(count: totalLength)
        let copyStatus: OSStatus = raw.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: totalLength, destination: base)
        }
        guard copyStatus == noErr else {
            Diag.log("CMBlockBufferCopyDataBytes 失败 \(copyStatus)")
            return
        }

        var annexB = Data()
        if let ps = parameterSets { annexB.append(ps) }
        annexB.append(Self.avccToAnnexB(raw))
        guard annexB.count > 4 else { return }

        encodedCount += 1
        if encodedCount == 1 {
            Diag.log("VT 首帧 编码完成 \(annexB.count) 字节 key=\(isKeyFrame)")
        }
        onAnnexBFrame?(annexB, isKeyFrame)
    }

    /// VT 输出为 AVCC（4 字节长度前缀），转成 Annex-B
    private static func avccToAnnexB(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = Data()
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) << 24
                | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= bytes.count else { break }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(contentsOf: bytes[offset..<offset + length])
            offset += length
        }
        return out
    }

    private static func parameterSets(from desc: CMVideoFormatDescription) -> Data? {
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        guard
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: 0,
                parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
            let sps = spsPointer, let pps = ppsPointer
        else { return nil }

        var data = Data([0, 0, 0, 1])
        data.append(contentsOf: UnsafeBufferPointer(start: sps, count: spsSize))
        data.append(contentsOf: [0, 0, 0, 1])
        data.append(contentsOf: UnsafeBufferPointer(start: pps, count: ppsSize))
        return data
    }
}
