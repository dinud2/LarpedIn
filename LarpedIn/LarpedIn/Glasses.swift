import ActivityKit
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
    var liveActivityStatus = "Not started"
    var sessionState = ""
    var frameCount = 0
    var streamState: StreamState?
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
    @ObservationIgnored private var autoStartTask: Task<Void, Never>?
    @ObservationIgnored private var activity: Activity<ClipActivityAttributes>?
    @ObservationIgnored private var clipCount = 0

    init() {
        // iOS only lets an app start a Live Activity while it's on screen, so retry
        // whenever it comes back if streaming started in the background.
        Task {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                if isStreaming { startActivity() }
            }
        }
        Task {
            for await state in Wearables.shared.registrationStateStream() {
                let wasRegistered = isRegistered
                isRegistered = state == .registered
                if isRegistered, !wasRegistered { autoStart() }
            }
        }
        Task {
            for await device in deviceSelector.activeDeviceStream() {
                let hadDevice = hasDevice
                hasDevice = device != nil
                if hasDevice, !hadDevice { autoStart() }
            }
        }
    }

    /// Starts streaming when the glasses connect (or registration finishes with them
    /// connected). Only fires on those transitions, so Stop sticks until the glasses
    /// reconnect and a failed start doesn't retry in a loop.
    private func autoStart() {
        guard isRegistered, hasDevice, !isStreaming, autoStartTask == nil else { return }
        autoStartTask = Task {
            await start()
            autoStartTask = nil
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
                resolution: .high,
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
                    self.streamState = state
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
            startActivity()
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
        streamState = nil
        previewImage = nil
        let ending = activity
        activity = nil
        Task { await ending?.end(nil, dismissalPolicy: .immediate) }
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
        startActivity()
        clipCount += 1
        let thisClip = clipCount
        await showInActivity(.init(phase: .clipping))
        do {
            lastResult = "Writing clip…"
            let (file, hasAudio) = try await buffer.writeClip()
            defer { try? FileManager.default.removeItem(at: file) }
            await showInActivity(.init(phase: .writing))
            let label = hasAudio ? "clip" : "clip (no audio)"
            guard let reply = await upload(try Data(contentsOf: file), to: "api/clip", contentType: "video/mp4", label: label) else {
                return await showResult(.init(phase: .failed, detail: lastResult), of: thisClip)
            }
            await showResult(outcome(of: reply), of: thisClip)
        } catch {
            lastResult = "Clip failed: \(error)"
            await showResult(.init(phase: .failed, detail: error.localizedDescription), of: thisClip)
        }
    }

    /// One Live Activity per streaming session; clips update it. Starting one only works
    /// while the app is on screen, but updates work from the background, which is what
    /// lets glasses-button clips show up with the phone locked.
    private func startActivity() {
        if activity?.activityState == .active { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            liveActivityStatus = "Off in iOS Settings"
            return
        }
        do {
            activity = try Activity.request(
                attributes: ClipActivityAttributes(),
                content: ActivityContent(state: .init(phase: .live), staleDate: nil)
            )
            liveActivityStatus = "Running"
        } catch {
            // Not fatal: clips still work without the Live Activity.
            liveActivityStatus = "Couldn't start: \(error.localizedDescription)"
        }
    }

    private func showInActivity(_ state: ClipActivityAttributes.ContentState) async {
        await activity?.update(ActivityContent(state: state, staleDate: nil))
    }

    /// Shows a clip's result for a minute, then goes back to the streaming state
    /// unless a newer clip has taken over.
    private func showResult(_ state: ClipActivityAttributes.ContentState, of clip: Int) async {
        await showInActivity(state)
        Task {
            try? await Task.sleep(for: .seconds(60))
            guard clip == clipCount, isStreaming else { return }
            await showInActivity(.init(phase: .live))
        }
    }

    /// Reads the backend's reply to tell a published post from a saved draft.
    private func outcome(of reply: Data) -> ClipActivityAttributes.ContentState {
        struct Reply: Decodable {
            struct Draft: Decodable {
                let status: String
                let postUrl: URL?
            }
            let post: String?
            let draft: Draft?
            let publishError: String?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let parsed = try? decoder.decode(Reply.self, from: reply) else {
            return .init(phase: .drafted, detail: "Sent, but the server's reply couldn't be read")
        }
        let firstLine = parsed.post?.split(separator: "\n").first.map(String.init) ?? ""
        if parsed.draft?.status == "published" {
            lastResult = "Posted to LinkedIn"
            return .init(phase: .posted, detail: firstLine, postURL: parsed.draft?.postUrl)
        }
        lastResult = parsed.publishError.map { "Saved as draft: \($0)" } ?? "Saved as draft"
        return .init(phase: .drafted, detail: parsed.publishError ?? firstLine)
    }

    /// POSTs to `<server>/<path>`, where the server is the base URL typed into the app.
    /// Returns the reply body on success, nil on failure (with `lastResult` explaining why).
    @discardableResult
    private func upload(_ body: Data, to path: String, contentType: String, label: String) async -> Data? {
        let server = UserDefaults.standard.string(forKey: "endpoint")?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let base = URL(string: server), base.scheme?.hasPrefix("http") == true, base.host() != nil else {
            lastResult = "Set the server URL first, e.g. https://example.com"
            return nil
        }
        isSending = true
        defer { isSending = false }
        var request = URLRequest(url: base.appending(path: path))
        // The backend transcribes and runs two model calls before answering.
        request.timeoutInterval = 120
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        do {
            let (reply, response) = try await URLSession.shared.upload(for: request, from: body)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                lastResult = "\(label) upload failed (HTTP \(code))"
                return nil
            }
            lastResult = "Sent \(label) (HTTP \(code))"
            return reply
        } catch {
            lastResult = "\(label) upload failed: \(error.localizedDescription)"
            return nil
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
