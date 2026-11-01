import AVFoundation
import Synchronization

/// Rolling window of compressed HEVC frames plus the glasses' PCM audio, holding the
/// longest clip length so any shorter clip can be cut from it after the fact. Clips
/// always start on a keyframe so they decode; audio is trimmed to the video's range.
nonisolated final class ClipBuffer: Sendable {
    private struct Frame {
        let sample: CMSampleBuffer
        let pts: CMTime
        let isKeyframe: Bool
    }

    private struct AudioChunk {
        let buffer: AVAudioPCMBuffer
        let pts: CMTime
    }

    private let seconds: Double
    private let frames = Mutex<[Frame]>([])
    private let audio = Mutex<[AudioChunk]>([])

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

    func appendAudio(_ sdkBuffer: AVAudioPCMBuffer, pts: CMTime) {
        guard let buffer = sdkBuffer.copy() else { return }
        audio.withLock { chunks in
            chunks.append(AudioChunk(buffer: buffer, pts: pts))
            // Generous margin: writeClip trims to the video's actual start.
            while let oldest = chunks.first, (pts - oldest.pts).seconds > seconds + 5 {
                chunks.removeFirst()
            }
        }
    }

    /// Writes the last `clipSeconds` (rounded back to a keyframe) to an mp4: video passed
    /// through, audio encoded to AAC. `hasAudio` is false when no audio overlapped it.
    func writeClip(seconds clipSeconds: Double) async throws -> (url: URL, hasAudio: Bool) {
        let buffered = frames.withLock { $0 }
        guard let latest = buffered.last else { throw ClipError.empty }
        // Latest keyframe that still gives at least the requested length; if the buffer
        // is shorter than that, take all of it.
        let start = buffered.lastIndex { $0.isKeyframe && (latest.pts - $0.pts).seconds >= clipSeconds } ?? 0
        let snapshot = buffered[start...]
        guard let first = snapshot.first, let last = snapshot.last,
            let format = CMSampleBufferGetFormatDescription(first.sample)
        else { throw ClipError.empty }
        let audioChunks = audio.withLock { $0 }.filter { $0.pts >= first.pts && $0.pts <= last.pts }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        writer.add(input)
        var audioInput: AVAssetWriterInput?
        if let pcmFormat = audioChunks.first?.buffer.format {
            let aac = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: pcmFormat.sampleRate,
                AVNumberOfChannelsKey: pcmFormat.channelCount,
            ])
            writer.add(aac)
            audioInput = aac
        }
        guard writer.startWriting() else { throw writer.error ?? ClipError.empty }
        writer.startSession(atSourceTime: .zero)

        var videoSamples: [CMSampleBuffer] = []

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
            videoSamples.append(retimed)
        }
        var tracks = [(input: input, samples: videoSamples[...])]
        if let audioInput {
            let audioSamples = audioChunks.compactMap { $0.buffer.sampleBuffer(pts: $0.pts - first.pts) }
            tracks.append((audioInput, audioSamples[...]))
        }

        // AVAssetWriter interleaves: an input that's ahead in time reports not-ready
        // until the other catches up or is marked finished. So feed tracks in turn and
        // finish each the moment it runs dry. A failed writer is also not-ready forever.
        var finished = Set<Int>()
        while finished.count < tracks.count {
            var progressed = false
            for i in tracks.indices where !finished.contains(i) {
                while tracks[i].input.isReadyForMoreMediaData, let sample = tracks[i].samples.first {
                    guard tracks[i].input.append(sample) else { throw writer.error ?? ClipError.empty }
                    tracks[i].samples.removeFirst()
                    progressed = true
                }
                if tracks[i].samples.isEmpty {
                    tracks[i].input.markAsFinished()
                    finished.insert(i)
                    progressed = true
                }
            }
            if !progressed {
                guard writer.status == .writing else { throw writer.error ?? ClipError.empty }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ClipError.empty }
        return (url, audioInput != nil)
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

extension AVAudioPCMBuffer {
    /// Our own copy; the SDK says not to hold or modify the buffers it delivers.
    nonisolated func copy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            memcpy(toData, fromData, Int(from.mDataByteSize))
        }
        return copy
    }

    /// Wraps the PCM in a CMSampleBuffer so AVAssetWriter can encode it.
    nonisolated func sampleBuffer(pts: CMTime) -> CMSampleBuffer? {
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        )
        guard let description else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: CMItemCount(frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        )
        guard let sample,
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                bufferList: audioBufferList
            ) == noErr
        else { return nil }
        return sample
    }
}
