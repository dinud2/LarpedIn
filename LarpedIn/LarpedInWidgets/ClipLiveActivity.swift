import ActivityKit
import SwiftUI
import WidgetKit

struct ClipLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClipActivityAttributes.self) { context in
            HStack(spacing: 14) {
                PhaseIcon(phase: context.state.phase).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.phase.title).font(.headline)
                    if let detail = context.state.shownDetail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                ViewPostButton(state: context.state)
            }
            .padding(16)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase).font(.title2).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.phase.title).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ViewPostButton(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let detail = context.state.shownDetail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } compactLeading: {
                PhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                Text(context.state.phase.shortTitle).font(.caption.weight(.semibold))
            } minimal: {
                PhaseIcon(phase: context.state.phase)
            }
            .keylineTint(.white)
        }
    }
}

private struct ViewPostButton: View {
    let state: ClipActivityAttributes.ContentState

    var body: some View {
        if state.phase == .posted, let post = state.postURL, let link = URL.viewPost(post) {
            Link(destination: link) {
                Text("View post")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white, in: .capsule)
            }
        }
    }
}

private struct PhaseIcon: View {
    let phase: ClipActivityAttributes.ContentState.Phase

    var body: some View {
        switch phase {
        case .live: Image(systemName: "eyeglasses")
        case .clipping: Image(systemName: "scissors")
        case .writing: Image(systemName: "sparkles")
        case .posted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .drafted: Image(systemName: "tray.full.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

private extension ClipActivityAttributes.ContentState {
    var shownDetail: String? {
        if phase == .live { return "Hold the capture button to clip" }
        return detail.isEmpty ? nil : detail
    }
}

private extension ClipActivityAttributes.ContentState.Phase {
    var title: String {
        switch self {
        case .live: "Streaming"
        case .clipping: "Clipping the last 10s"
        case .writing: "Writing your post…"
        case .posted: "Posted to LinkedIn"
        case .drafted: "Saved as draft"
        case .failed: "Clip failed"
        }
    }

    var shortTitle: String {
        switch self {
        case .live: "Live"
        case .clipping: "Clip"
        case .writing: "Writing"
        case .posted: "Posted"
        case .drafted: "Draft"
        case .failed: "Failed"
        }
    }
}

#Preview("Lock screen", as: .content, using: ClipActivityAttributes()) {
    ClipLiveActivity()
} contentStates: {
    ClipActivityAttributes.ContentState(phase: .live)
    ClipActivityAttributes.ContentState(phase: .writing)
    ClipActivityAttributes.ContentState(
        phase: .posted,
        detail: "I asked a stranger one question.",
        postURL: URL(string: "https://www.linkedin.com/feed/update/urn:li:share:42/")
    )
    ClipActivityAttributes.ContentState(phase: .drafted, detail: "LinkedIn post creation failed (HTTP 403)")
}
