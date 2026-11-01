import AVFoundation
import UIKit
import MWDATCamera
import MWDATCore
import MWDATInputs
import Observation

/// Owns the glasses connection: streams HEVC into a 10s ring buffer. On the glasses
/// capture button (or in-app buttons), a short press uploads a photo and a hold
/// uploads the last 10s as an mp4.
@Observable final class Glasses {
    var isRegistered = false
    var hasDevice = false
    var isStreaming = false
    var isSending = false
    var status = "Idle"
    var streamError = ""
    var buttonStatus = ""
    var lastResult = ""
    var sessionState = ""
    var frameCount = 0
    var previewImage: UIImage?

    @ObservationIgnored private let decoder = FrameDecoder()
    /// Long-lived: it fills in from `devicesStream()` asynchronously, so a fresh
    /// one created at tap time has no device yet and the session fails.
    @ObservationIgnored private let deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
    @ObservationIgnored private let buffer = ClipBuffer(seconds: 10)
    @ObservationIgnored private let tokens = ListenerTokenBag()
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var inputs: Inputs?
    @ObservationIgnored private var stream: MWDATCamera.Stream?
    @ObservationIgnored private var inputTask: Task<Void, Never>?

    init() {
        Task {
            for await state in Wearables.shared.registrationStateStream() {
                isRegistered = state == .registered
            }
        }
        Task {
            for await device in deviceSelector.activeDeviceStream() {
                hasDevice = device != nil
            }
        }
    }

    func register() async {
        do {
            try await Wearables.shared.startRegistration()
        } catch {
            status = "Registration failed: \(error)"
        }
    }

    /// Meta AI calls back here after registration and permission prompts.
    func handle(_ url: URL) async {
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else { return }
        do {
            _ = try await Wearables.shared.handleUrl(url)
        } catch {
            status = "Meta AI callback failed: \(error)"
        }
    }

    func start() async {
        let wearables = Wearables.shared
        do {
            if try await wearables.checkPermissionStatus(.camera) != .granted {
                guard try await wearables.requestPermission(.camera) == .granted else {
                    status = "Camera permission denied"
                    return
                }
            }
            // Audio is optional: without the mic permission we still stream video.
            var hasMic = (try? await wearables.checkPermissionStatus(.microphone)) == .granted
            if !hasMic { hasMic = (try? await wearables.requestPermission(.microphone)) == .granted }
            status = "Connecting…"
            streamError = ""
            let session = try wearables.createSession(deviceSelector: deviceSelector)
            self.session = session
            isStreaming = true
            frameCount = 0
            session.statePublisher.listen { state in
                Task { @MainActor in self.sessionState = "\(state)" }
            }.store(in: tokens)
            session.errorPublisher.listen { error in
                Task { @MainActor in self.streamError = "Session: \(error.localizedDescription) (\(error))" }
            }.store(in: tokens)
            try session.start()
            for await state in session.stateStream() where state == .started { break }

            // hvc1 keeps frames compressed (cheap to buffer, written to mp4 as-is) and
            // keeps streaming while the app is backgrounded, unlike raw. 16kHz mono is
            // plenty for speech and barely costs Bluetooth bandwidth.
            let config = StreamConfiguration(
                videoCodec: .hvc1,
                audioCodec: hasMic ? .pcm(sampleRate: .rate16000, numberOfChannels: 1) : nil,
                resolution: .medium,
                frameRate: 24
            )
            guard let camera = try session.addCamera(config: config) else {
                status = "Couldn't attach camera"
                return stop()
            }

            let buffer = buffer
            let decoder = decoder
            camera.stream.videoFramePublisher.listen { frame in
                let sample = frame.sampleBuffer
                buffer.append(sample)
                let image = decoder.decode(sample)
                Task { @MainActor in
                    self.frameCount += 1
                    if let image { self.previewImage = image }
                }
            }.store(in: tokens)
            camera.stream.audioFramePublisher.listen { frame in
                buffer.appendAudio(frame.pcmBuffer, pts: frame.presentationTimeStamp)
            }.store(in: tokens)
            var wasStreaming = false
            camera.stream.statePublisher.listen { state in
                Task { @MainActor in
                    self.status = "Stream: \(state)"
                    // Stream died on its own (critical error, hinges, thermal): reset so
                    // Start works again. It can report stopped before ever starting.
                    if state == .streaming { wasStreaming = true }
                    if state == .stopped, wasStreaming { self.stop() }
                }
            }.store(in: tokens)
            camera.stream.photoDataPublisher.listen { photo in
                Task { @MainActor in await self.upload(photo.data, to: "api/photo", contentType: "image/jpeg", label: "photo") }
            }.store(in: tokens)
            camera.stream.errorPublisher.listen { error in
                Task { @MainActor in self.streamError = "\(error.localizedDescription) (\(error))" }
            }.store(in: tokens)

            stream = camera.stream
            if UserDefaults.standard.object(forKey: "useGlassesButton") as? Bool ?? true {
                attachInputs(to: session)
            } else {
                buttonStatus = "Glasses button off"
            }
            camera.stream.start()
        } catch {
            status = error.localizedDescription
            stop()
        }
    }

    func stop() {
        inputTask?.cancel()
        inputTask = nil
        tokens.clear()
        inputs = nil
        stream = nil
        session?.stop()
        session = nil
        isStreaming = false
    }

    /// Full-quality still, taken while the video keeps streaming. The JPEG arrives
    /// on `photoDataPublisher`, which uploads it.
    func photo() {
        guard stream?.capturePhoto(format: .jpeg) == true else {
            lastResult = "Photo didn't start, try again"
            return
        }
        lastResult = "Taking photo…"
    }

    func clip() async {
        do {
            lastResult = "Writing clip…"
            let (file, hasAudio) = try await buffer.writeClip()
            defer { try? FileManager.default.removeItem(at: file) }
            await upload(try Data(contentsOf: file), to: "api/clip", contentType: "video/mp4", label: hasAudio ? "clip" : "clip (no audio)")
        } catch {
            lastResult = "Clip failed: \(error)"
        }
    }

    /// POSTs to `<server>/<path>`, where the server is the base URL typed into the app.
    private func upload(_ body: Data, to path: String, contentType: String, label: String) async {
        let server = UserDefaults.standard.string(forKey: "endpoint")?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let base = URL(string: server), base.scheme?.hasPrefix("http") == true, base.host() != nil else {
            lastResult = "Set the server URL first, e.g. https://example.com"
            return
        }
        isSending = true
        defer { isSending = false }
        var request = URLRequest(url: base.appending(path: path))
        // The backend transcribes and runs two model calls before answering.
        request.timeoutInterval = 120
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: body)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                lastResult = "\(label) upload failed (HTTP \(code))"
                return
            }
            lastResult = "Sent \(label) (HTTP \(code))"
        } catch {
            lastResult = "\(label) upload failed: \(error.localizedDescription)"
        }
    }

    /// Inputs is experimental and needs Developer Center approval, so a missing
    /// capability just means falling back to the in-app button.
    private func attachInputs(to session: DeviceSession) {
        guard let inputs = try? session.addInputs(configuration: InputsConfiguration(consumeBack: false)) else {
            buttonStatus = "Glasses button unavailable, use the phone button"
            return
        }
        self.inputs = inputs
        buttonStatus = "Glasses capture button armed"
        inputs.errorPublisher.listen { error in
            Task { @MainActor in self.buttonStatus = "Glasses button: \(error.localizedDescription)" }
        }.store(in: tokens)
        let events = inputs.events
        inputTask = Task { [weak self] in
            for await event in events {
                guard case .capture(let press, _, _) = event else { continue }
                switch press {
                case .shortPress: self?.photo()
                case .hold: await self?.clip()
                case .doublePress: break
                }
            }
        }
    }
}
