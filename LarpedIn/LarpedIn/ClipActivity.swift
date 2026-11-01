import ActivityKit
import Foundation

/// Shared with the widget extension: one Live Activity per streaming session,
/// updated as each clip is written, posted to the backend, and published.
struct ClipActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable {
            case live, clipping, writing, posted, drafted, failed
        }

        var phase: Phase
        /// First line of the post, or the reason it wasn't published.
        var detail = ""
        /// The published post, for the "View post" button.
        var postURL: URL?
    }
}

extension URL {
    /// Deep link the Live Activity's "View post" button opens; the app forwards it
    /// to LinkedIn, since widget links reliably open only their own app.
    static func viewPost(_ post: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "larpedin"
        components.host = "post"
        components.queryItems = [URLQueryItem(name: "url", value: post.absoluteString)]
        return components.url
    }
}
