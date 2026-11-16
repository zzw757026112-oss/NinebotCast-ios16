import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox
import os.log

/// VideoToolbox H.264 硬编码器（主 App H264Encoder 的精简版，输出 Annex-B 流）。
///
/// 录屏扩展专用：没有 Diag 依赖，用 os_log 记录；参数与主 App 的五寸预设
/// 完全一致（848x480 / 20fps / 2Mbps / GOP 10 / Main profile / 零延迟）。
final class ScreenEncoder {
    /// (annexB 数据, 是否关键帧)
    var onAnnexBFrame: ((Data, Bool) -> Void)?

    private let log = Logger(subsystem: "com.corpsezhao.ninebotcast", category: "broadcast")
    private var session: VTCompressionSession?
    private var parameterSets: Data?
    private var isTornDown = true
    private var encodedCount = 0

    func setup(width: Int, height: Int, fps: Int32, bitrate: UInt32, gop: Int = 10) -> Bool {
        teardown()
        guard width > 0, height > 0, fps > 0 else {
            log.error("VT setup 参数非法 \(width)x\(height) fps=\(fps)")
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
                let encoder = Unmanaged<ScreenEncoder>.fromOpaque(refcon).takeUnretainedValue()
                guard !encoder.isTornDown else { return }
                encoder.handleOutput(sampleBuffer: sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &sessionOut)

        guard status == noErr, let session = sessionOut else {
            log.error("VTCompressionSessionCreate 失败 status=\(status)")
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
                             value: NSNumber(value: max(1, gop)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        // 低延迟：编码器不许攒帧，出一帧交一帧
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                             value: NSNumber(value: 0))
        // 码率限幅（1.25 倍均值）：不让关键帧远超均值
        let bytesPerSecond = max(1, Int(bitrate) / 8 * 5 / 4)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: "\(bytesPerSecond),1" as CFString)

        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            log.error("VTCompressionSessionPrepareToEncodeFrames 失败")
            VTCompressionSessionInvalidate(session)
            return false
        }
        self.session = session
        log.info("VT 编码器就绪 \(width)x\(height) fps=\(fps) \(bitrate / 1000)kbps")
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
            log.error("VT encode 返回 \(status)")
        }
    }

    func teardown() {
        isTornDown = true
        if let session {
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
            log.error("CMBlockBufferCopyDataBytes 失败 \(copyStatus)")
            return
        }

        var annexB = Data()
        if let ps = parameterSets { annexB.append(ps) }
        annexB.append(Self.avccToAnnexB(raw))
        guard annexB.count > 4 else { return }

        encodedCount += 1
        if encodedCount == 1 {
            log.info("VT 首帧 编码完成 \(annexB.count) 字节 key=\(isKeyFrame)")
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
