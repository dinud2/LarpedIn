import CoreImage
import UIKit
import VideoToolbox
import os

/// Decodes hvc1 frames into images for the preview, the way Meta's CameraAccess
/// sample does. Never touches the SDK's buffers beyond reading them.
nonisolated final class FrameDecoder: @unchecked Sendable {
    private struct State {
        var session: VTDecompressionSession?
        var format: CMFormatDescription?
        var sawKeyframe = false
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let context = CIContext()

    func decode(_ sample: CMSampleBuffer) -> UIImage? {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let isKeyframe = sample.isHEVCKeyframe()

        let pixelBuffer: CVPixelBuffer? = state.withLockUnchecked { state in
            if state.session == nil || state.format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) }) ?? true {
                if let old = state.session { VTDecompressionSessionInvalidate(old) }
                state.session = Self.makeSession(format)
                state.format = format
                state.sawKeyframe = false
            }
            if isKeyframe { state.sawKeyframe = true }
            guard state.sawKeyframe, let session = state.session else { return nil }

            // No async flags, so the handler runs before DecodeFrame returns.
            var output: CVPixelBuffer?
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                if status == noErr { output = image }
            }
            if status == kVTInvalidSessionErr { state.session = nil }
            // Any failure means later frames reference garbage until the next keyframe.
            if status != noErr { state.sawKeyframe = false }
            return output
        }

        guard let pixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func makeSession(_ format: CMFormatDescription) -> VTDecompressionSession? {
        // Software decoding survives backgrounding, per Meta's sample.
        let spec = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: false] as CFDictionary
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        var session: VTDecompressionSession?
        VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: spec,
            imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session
        )
        return session
    }
}
