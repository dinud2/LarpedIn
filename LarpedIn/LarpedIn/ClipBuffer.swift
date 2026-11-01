import AVFoundation
import Synchronization

/// Rolling window of compressed HEVC frames. Always starts on a keyframe so the
/// clip decodes, which means it holds `seconds` plus up to one GOP.
nonisolated final class ClipBuffer: Sendable {
    private struct Frame {
        let sample: CMSampleBuffer
        let pts: CMTime
        let isKeyframe: Bool
    }

    private let seconds: Double
    private let frames = Mutex<[Frame]>([])

    init(seconds: Double) {
        self.seconds = seconds
    }

    func append(_ sdkSample: CMSampleBuffer) {
        guard let sample = sdkSample.deepCopy() else { return }
        let frame = Frame(
            sample: sample,
            pts: CMSampleBufferGetPresentationTimeStamp(sample),
            isKeyframe: sample.isHEVCKeyframe()
        )
        frames.withLock { frames in
            guard !frames.isEmpty || frame.isKeyframe else { return }
            frames.append(frame)
            // Drop the oldest GOP while the next keyframe still leaves a full window.
            while let next = frames.dropFirst().firstIndex(where: \.isKeyframe),
                (frame.pts - frames[next].pts).seconds >= seconds
            {
                frames.removeFirst(next)
            }
        }
    }

    /// Writes the current window to an mp4 without re-encoding.
    func writeClip() async throws -> URL {
        let snapshot = frames.withLock { $0 }
        guard let first = snapshot.first,
            let format = CMSampleBufferGetFormatDescription(first.sample)
        else { throw ClipError.empty }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ClipError.empty }
        writer.startSession(atSourceTime: .zero)

        // SDK frames can lack durations and sync flags; without them the mp4 has no
        // seekable timeline or keyframe index.
        let fallbackDuration = CMTime(value: 1, timescale: 24)
        var lastPTS = CMTime.negativeInfinity
        for frame in snapshot {
            var pts = frame.pts - first.pts
            if pts <= lastPTS { pts = lastPTS + fallbackDuration }
            lastPTS = pts
            let duration = CMSampleBufferGetDuration(frame.sample)
            var timing = CMSampleTimingInfo(
                duration: duration.isValid && duration > .zero ? duration : fallbackDuration,
                presentationTimeStamp: pts,
                decodeTimeStamp: pts
            )
            var retimed: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: nil, sampleBuffer: frame.sample, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleBufferOut: &retimed
            )
            guard let retimed else { continue }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(retimed, createIfNecessary: true) as? [NSMutableDictionary],
                let dict = attachments.first
            {
                dict[kCMSampleAttachmentKey_NotSync] = !frame.isKeyframe
                dict[kCMSampleAttachmentKey_DependsOnOthers] = !frame.isKeyframe
            }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            input.append(retimed)
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ClipError.empty }
        return url
    }
}

enum ClipError: LocalizedError {
    case empty
    var errorDescription: String? { "No video buffered yet" }
}

extension CMSampleBuffer {
    /// Copies the frame's bytes into memory we own. Holding the SDK's buffers for
    /// 10s starves its frame pool and the stream fails with videoStreamingError.
    nonisolated func deepCopy() -> CMSampleBuffer? {
        guard let source = CMSampleBufferGetDataBuffer(self),
            let format = CMSampleBufferGetFormatDescription(self)
        else { return nil }
        let length = CMBlockBufferGetDataLength(source)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(source, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr
        else { return nil }

        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard let block,
            CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == kCMBlockBufferNoErr
        else { return nil }

        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(self, at: 0, timingInfoOut: &timing)
        var size = length
        var copy: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &copy
        )
        return copy
    }

    /// True if any NAL unit is an HEVC keyframe (BLA 16-18, IDR 19-20, CRA 21).
    /// Lifted from Meta's CameraAccess sample: SDK buffers don't reliably carry NotSync.
    nonisolated func isHEVCKeyframe() -> Bool {
        guard let data = CMSampleBufferGetDataBuffer(self) else { return false }
        let total = CMBlockBufferGetDataLength(data)
        var offset = 0
        // HVCC: 4-byte big-endian length prefix, then the NAL unit.
        while offset + 4 < total {
            var lengthBE: UInt32 = 0
            guard CMBlockBufferCopyDataBytes(data, atOffset: offset, dataLength: 4, destination: &lengthBE) == kCMBlockBufferNoErr
            else { return false }
            let length = Int(UInt32(bigEndian: lengthBE))
            offset += 4
            guard length > 0, offset + length <= total else { return false }
            var header: UInt8 = 0
            guard CMBlockBufferCopyDataBytes(data, atOffset: offset, dataLength: 1, destination: &header) == kCMBlockBufferNoErr
            else { return false }
            if (16...21).contains((header >> 1) & 0x3F) { return true }
            offset += length
        }
        return false
    }
}
