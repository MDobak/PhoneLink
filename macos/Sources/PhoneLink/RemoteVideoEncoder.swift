import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 (VideoToolbox), real-time, no B-frames. Outputs Annex B for the phone's MediaCodec.
/// Use from one serial queue only.
final class RemoteVideoEncoder {
    /// Flags: 1 = config (SPS and PPS), 2 = key frame, 0 = other frame.
    struct Unit { let flags: UInt8; let ptsUs: UInt64; let data: Data }

    let width: Int32
    let height: Int32
    private var session: VTCompressionSession?
    /// Called on a VideoToolbox thread in frame order, with no units when a frame fails.
    private let output: ([Unit]) -> Void
    private var forceKey = true

    init?(width: Int, height: Int, fps: Int, bitRate: Int, output: @escaping ([Unit]) -> Void) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.output = output
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { return nil }
        session = s
        func set(_ k: CFString, _ v: Any) -> Bool { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) == noErr }
        if !set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel) {
            _ = set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        }
        _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        _ = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
        _ = set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue!)
        // The host requests key frames itself (on request, after a drop, every 10 s).
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameInterval, max(fps, 1) * 3600)
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 3600)
        _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        _ = set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        setBitRate(bitRate)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { invalidate() }

    /// Pending frames are not sent.
    func invalidate() {
        guard let s = session else { return }
        session = nil
        VTCompressionSessionInvalidate(s)
    }

    /// Peak is 1.5x the mean per second.
    func setBitRate(_ bps: Int) {
        guard let s = session else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        let limits = [Double(bps) * 1.5 / 8, 1.0] as CFArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    func requestKeyFrame() { forceKey = true }

    /// The pixel buffer must match the encoder size.
    func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        guard let s = session else { return }
        var props: CFDictionary?
        if forceKey {
            forceKey = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
        }
        let out = output
        let st = VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                                 frameProperties: props, infoFlagsOut: nil) { status, _, sb in
            guard status == noErr, let sb, let units = RemoteVideoEncoder.units(from: sb) else { out([]); return }
            out(units)
        }
        if st != noErr { forceKey = true; out([]) }
    }

    /// The config unit before a key frame, then the frame.
    static func units(from sb: CMSampleBuffer) -> [Unit]? {
        guard CMSampleBufferDataIsReady(sb), let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let us = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000)) : 0
        var key = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let a = atts.first, (a[kCMSampleAttachmentKey_NotSync] as? Bool) == true { key = false }
        var nalLen = 4
        var result: [Unit] = []
        if let fd = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            var hl: Int32 = 4
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &hl)
            nalLen = Int(hl)
            if key {
                var cfg = Data()
                for i in 0..<count {
                    var p: UnsafePointer<UInt8>?
                    var n = 0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                                          parameterSetSizeOut: &n, parameterSetCountOut: nil,
                                                                          nalUnitHeaderLengthOut: nil) == noErr, let p {
                        cfg.append(contentsOf: [0, 0, 0, 1])
                        cfg.append(p, count: n)
                    }
                }
                if !cfg.isEmpty { result.append(Unit(flags: 1, ptsUs: us, data: cfg)) }
            }
        }
        let len = CMBlockBufferGetDataLength(block)
        guard len > 0 else { return nil }
        var avcc = Data(count: len)
        let st = avcc.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
        guard st == noErr, let annexB = annexB(fromAVCC: avcc, lengthSize: nalLen) else { return nil }
        result.append(Unit(flags: key ? 2 : 0, ptsUs: us, data: annexB))
        return result
    }

    /// AVCC (length-prefixed) to Annex B (start codes). Nil if the data is bad.
    static func annexB(fromAVCC d: Data, lengthSize: Int) -> Data? {
        guard (1...4).contains(lengthSize) else { return nil }
        var out = Data(capacity: d.count + 16)
        var ok = true
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < b.count {
                guard i + lengthSize <= b.count else { ok = false; return }
                var n = 0
                for k in 0..<lengthSize { n = (n << 8) | Int(b[i + k]) }
                i += lengthSize
                guard n > 0, i + n <= b.count else { ok = false; return }
                out.append(contentsOf: [0, 0, 0, 1])
                out.append(b.baseAddress! + i, count: n)
                i += n
            }
        }
        return ok ? out : nil
    }
}
