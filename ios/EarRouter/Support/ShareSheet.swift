import SwiftUI
import UIKit

/// The system share sheet.
///
/// SwiftUI's own `ShareLink` needs the thing being shared to exist *before* the
/// button is drawn, and a backup does not: building it means encoding every
/// tour in the store, which is not something to do on the chance that somebody
/// might tap. This wraps `UIActivityViewController` instead, so the file is
/// written when the driver asks for it and the sheet opens on the result.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A file waiting to be shared. `sheet(item:)` wants something `Identifiable`,
/// and a URL on its own is not.
struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Text waiting to be shared — the day's report on its way into WhatsApp or a
/// mail. Same reason as `SharedFile`: `sheet(item:)` wants an identity, and a
/// `String` has none of its own.
struct SharedText: Identifiable {
    let id = UUID()
    let text: String
}
