import SwiftUI

struct ContentView: View {
    @State private var glasses = Glasses()
    @AppStorage("endpoint") private var endpoint = ""
    @AppStorage("useGlassesButton") private var useGlassesButton = true

    var body: some View {
        VStack(spacing: 12) {
            Color.black
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay {
                    if let image = glasses.previewImage {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                }
                .clipShape(.rect(cornerRadius: 12))

            Text(glasses.status).font(.caption)
            if glasses.isStreaming {
                Text("Session: \(glasses.sessionState) · \(glasses.frameCount) frames")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !glasses.streamError.isEmpty {
                Text(glasses.streamError).font(.caption).foregroundStyle(.red)
            }
            if !glasses.buttonStatus.isEmpty {
                Text(glasses.buttonStatus).font(.caption).foregroundStyle(.secondary)
            }

            TextField("Upload URL", text: $endpoint)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Toggle("Glasses button (applies on next start)", isOn: $useGlassesButton)
                .font(.caption)

            if !glasses.isRegistered {
                Button("Connect to Meta AI") { Task { await glasses.register() } }
                    .buttonStyle(.borderedProminent)
            } else if glasses.isStreaming {
                HStack {
                    Button("Stop") { glasses.stop() }
                        .buttonStyle(.bordered)
                    Button("Photo") { glasses.photo() }
                        .buttonStyle(.borderedProminent)
                    Button("Clip last 10s") { Task { await glasses.clip() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Button(glasses.hasDevice ? "Start streaming" : "Looking for glasses…") { Task { await glasses.start() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!glasses.hasDevice)
            }

            Text(glasses.isSending ? "Sending…" : glasses.lastResult).font(.caption)
        }
        .padding()
        .onOpenURL { url in Task { await glasses.handle(url) } }
    }
}
