import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 decoding with VideoToolbox: NAL units in, BGRA pixel buffers out.
/// Not thread-safe; use from one queue.
final class H264Decoder {
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    /// Frames before the first keyframe reference pictures we never saw; skip them.
    private(set) var waitingForKeyframe = true

    deinit { invalidate() }

    /// SPS/PPS announced out of band (the SDP's sprop-parameter-sets).
    func setParameterSets(_ sets: [Data]) {
        for nal in sets { absorbParameterSet(nal) }
    }

    /// Decodes one access unit. Returns nil while waiting for a keyframe or on error.
    func decode(_ nals: [Data], timestamp: UInt32) -> CVPixelBuffer? {
        var slices: [Data] = []
        var keyframe = false
        for nal in nals {
            guard let header = nal.first else { continue }
            switch header & 0x1F {
            case 7, 8: absorbParameterSet(nal)
            case 5: keyframe = true; slices.append(nal)
            case 1...4: slices.append(nal)
            default: break                                 // SEI, AUD, filler
            }
        }
        guard !slices.isEmpty else { return nil }
        if waitingForKeyframe && !keyframe { return nil }
        guard let session = makeSessionIfNeeded(), let format else { return nil }
        guard let sample = Self.sampleBuffer(slices, format: format, timestamp: timestamp) else { return nil }

        var output: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, image, _, _ in
            if status == noErr { output = image }
        }
        if status == kVTInvalidSessionErr {
            // E.g. after the Mac slept: start over with a fresh session at the next keyframe.
            invalidate()
            waitingForKeyframe = true
            return nil
        }
        if status != noErr || output == nil {
            if keyframe { waitingForKeyframe = true }
            return nil
        }
        if keyframe { waitingForKeyframe = false }
        return output
    }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    // MARK: - Private

    private func absorbParameterSet(_ nal: Data) {
        guard let header = nal.first else { return }
        switch header & 0x1F {
        case 7 where nal != sps: sps = nal; format = nil
        case 8 where nal != pps: pps = nal; format = nil
        default: return
        }
    }

    private func makeSessionIfNeeded() -> VTDecompressionSession? {
        if format == nil {
            invalidate()
            guard let sps, let pps else { return nil }
            format = Self.formatDescription(sps: sps, pps: pps)
            waitingForKeyframe = true
        }
        if let session { return session }
        guard let format else { return nil }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard status == noErr, let s else { return nil }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        return s
    }

    static func formatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        let spsBytes = [UInt8](sps), ppsBytes = [UInt8](pps)
        var format: CMVideoFormatDescription?
        let status = spsBytes.withUnsafeBufferPointer { s in
            ppsBytes.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [spsBytes.count, ppsBytes.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    /// AVCC sample: each NAL unit prefixed with its 4-byte big-endian length.
    static func sampleBuffer(_ nals: [Data], format: CMVideoFormatDescription, timestamp: UInt32) -> CMSampleBuffer? {
        var avcc = Data(capacity: nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: 90_000), decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
