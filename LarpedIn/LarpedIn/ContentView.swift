import MWDATCamera
import SwiftUI

struct ContentView: View {
    @State private var glasses = Glasses()
    @State private var showSettings = false
    @State private var clipTaps = 0
    @State private var photoTaps = 0

    var body: some View {
        VStack(spacing: 16) {
            header
            preview
            resultBanner
            controls
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView(glasses: glasses) }
        .sensoryFeedback(.impact(weight: .heavy), trigger: clipTaps)
        .sensoryFeedback(.impact(weight: .light), trigger: photoTaps)
        .onOpenURL { url in Task { await glasses.handle(url) } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("LarpedIn").font(.system(.title2, design: .rounded, weight: .bold))
                Image(systemName: "sparkles").font(.headline)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(connection.color).frame(width: 8, height: 8)
                Text(connection.label).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.headline).frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.top, 8)
    }

    private var connection: (label: String, color: Color) {
        if !glasses.isRegistered { return ("Not connected", .gray) }
        switch glasses.streamState {
        case .streaming: return ("Live", .red)
        case .paused: return ("Paused", .orange)
        case .starting, .waitingForDevice: return ("Starting", .yellow)
        default:
            if glasses.isStreaming { return ("Starting", .yellow) }
            return glasses.hasDevice ? ("Ready", .green) : ("No glasses", .gray)
        }
    }

    // MARK: Preview

    private var preview: some View {
        // The frame goes in an overlay: a scaledToFill image reports its full pixel size,
        // which in a ZStack would grow the card past the screen and under the Dynamic Island.
        Color(white: 0.07)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if let image = glasses.previewImage {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "eyeglasses").font(.system(size: 44, weight: .light))
                        Text(placeholder).font(.subheadline).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding(32)
                }
            }
        .clipShape(.rect(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.08)))
        .overlay(alignment: .topLeading) {
            if glasses.streamState == .streaming {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("LIVE").font(.caption.weight(.bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .padding(14)
            }
        }
        .overlay(alignment: .topTrailing) {
            if glasses.isStreaming {
                Text("\(glasses.frameCount) frames")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .padding(14)
            }
        }
        .overlay(alignment: .bottom) { previewNotice.padding(14) }
    }

    private var placeholder: String {
        if !glasses.isRegistered { return "Connect to Meta AI to get started" }
        if glasses.isStreaming { return "Waiting for video…" }
        if !glasses.hasDevice { return "Put on your glasses and make sure they're connected in Meta AI" }
        return "Ready when you are"
    }

    @ViewBuilder private var previewNotice: some View {
        if !glasses.streamError.isEmpty {
            Label(glasses.streamError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(.red.opacity(0.4)), in: .capsule)
        } else if glasses.streamState == .paused {
            Label("Tap the side of your glasses to resume", systemImage: "hand.tap")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
        }
    }

    // MARK: Result

    private var resultBanner: some View {
        HStack(spacing: 8) {
            if glasses.isSending {
                ProgressView().controlSize(.small)
                Text("Writing your post…")
            } else if !glasses.lastResult.isEmpty {
                Image(systemName: resultFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(resultFailed ? .red : .green)
                Text(glasses.lastResult).lineLimit(1)
            }
        }
        .font(.footnote.weight(.medium))
        .frame(height: 20)
        .animation(.default, value: glasses.isSending)
    }

    private var resultFailed: Bool {
        glasses.lastResult.localizedCaseInsensitiveContains("fail")
            || glasses.lastResult.hasPrefix("Set the server")
            || glasses.lastResult.hasPrefix("Photo didn't")
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        if !glasses.isRegistered {
            wideButton("Connect to Meta AI", systemImage: "link") { Task { await glasses.register() } }
        } else if glasses.isStreaming {
            // Grid keeps the three buttons centred on one row and the labels on the next.
            Grid(horizontalSpacing: 40, verticalSpacing: 8) {
                GridRow {
                    circleButton(systemImage: "stop.fill") { glasses.stop() }
                    Button {
                        clipTaps += 1
                        Task { await glasses.clip() }
                    } label: {
                        Circle()
                            .fill(.white)
                            .frame(width: 66, height: 66)
                            .overlay(Image(systemName: "sparkles").font(.title2.weight(.semibold)).foregroundStyle(.black))
                            .padding(5)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    }
                    .buttonStyle(.plain)
                    circleButton(systemImage: "camera.fill") {
                        photoTaps += 1
                        glasses.photo()
                    }
                }
                GridRow {
                    Text("Stop").foregroundStyle(.secondary)
                    Text("Clip 10s")
                    Text("Photo").foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))
            }
            .padding(.vertical, 4)
        } else {
            wideButton(glasses.hasDevice ? "Start streaming" : "Looking for glasses…", systemImage: "play.fill") {
                Task { await glasses.start() }
            }
            .disabled(!glasses.hasDevice)
        }
    }

    private func wideButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .foregroundStyle(.black)
                .background(.white, in: .capsule)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 12)
    }

    private func circleButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.title3).frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }
}

private struct SettingsView: View {
    let glasses: Glasses
    @AppStorage("endpoint") private var endpoint = ""
    @AppStorage("useGlassesButton") private var useGlassesButton = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com", text: $endpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("Clips are posted to \(endpoint.isEmpty ? "<server>" : endpoint)/api/clip")
                }

                Section {
                    Toggle("Capture button", isOn: $useGlassesButton)
                } header: {
                    Text("Glasses")
                } footer: {
                    Text("Short press takes a photo, hold clips the last 10 seconds. Applies the next time streaming starts.")
                }

                Section("Diagnostics") {
                    LabeledContent("Stream", value: glasses.status)
                    LabeledContent("Session", value: glasses.sessionState.isEmpty ? "–" : glasses.sessionState)
                    LabeledContent("Frames", value: "\(glasses.frameCount)")
                    if !glasses.buttonStatus.isEmpty {
                        LabeledContent("Capture button", value: glasses.buttonStatus)
                    }
                    if !glasses.streamError.isEmpty {
                        Text(glasses.streamError).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
