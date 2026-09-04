import SwiftUI
import SafariServices

/// An in-app browser.
///
/// `SFSafariViewController` rather than handing the URL to Safari: the driver
/// is mid-tour with a stop list open, and bouncing them out to another app to
/// glance at the dispatch portal means an app switch back, a cold relaunch, and
/// losing their place. It is also the only way to show web content that Apple
/// endorses — it keeps Safari's cookies and logins, so the Gourmet session the
/// driver already has carries over, and it shows the real URL and a Done button
/// so nothing can pretend to be something it is not.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        // The dispatch portal is a list to work from, not an article — the
        // driver may well tap through several customers.
        config.barCollapsingEnabled = true

        let controller = SFSafariViewController(url: url, configuration: config)
        controller.preferredControlTintColor = UIColor(Color.brand)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
