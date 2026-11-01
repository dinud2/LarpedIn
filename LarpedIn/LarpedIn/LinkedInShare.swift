
import SwiftUI
import UIKit

struct LinkedInShare: UIViewControllerRepresentable {
    let caption: String
    let image: UIImage?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = [caption]

        if let image = image {
            items.append(image)
        }

        return UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ controller: UIActivityViewController,
        context: Context
    ) {}
}
