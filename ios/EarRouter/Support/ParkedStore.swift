import SwiftUI

/// A store `Store` could not open, and moved aside so the app could start.
///
/// That recovery is the right last resort — a van full of meals is no place for
/// an app that crashes on launch — but it used to be a silent one. The app came
/// up empty, the only trace was a log line nobody reads, and the year of tours
/// and floors sat in a renamed file in Application Support that no screen ever
/// mentioned again. The likeliest cause is the ordinary one for this app: an
/// older build installed from Xcode over a store a newer build had already
/// migrated, which that older build cannot read.
///
/// So the moved-aside files are remembered, and the driver is told — with the
/// one thing that saves the data, which is getting those files off the phone
/// before anybody deletes the app to "fix" it.
enum ParkedStore {
    private static let filesKey = "store.parked.files"
    private static let reasonKey = "store.parked.reason"

    /// Called by `Store` right after it moved the files. Appends, so a second
    /// failed launch does not make the first set of files unmentionable.
    static func remember(_ files: [URL], reason: String) {
        guard !files.isEmpty else { return }
        let defaults = UserDefaults.standard
        let known = defaults.stringArray(forKey: filesKey) ?? []
        defaults.set(known + files.map(\.lastPathComponent), forKey: filesKey)
        defaults.set(reason, forKey: reasonKey)
    }

    /// The moved-aside files that are still there to be rescued.
    static var files: [URL] {
        let dir = URL.applicationSupportDirectory
        return (UserDefaults.standard.stringArray(forKey: filesKey) ?? [])
            .map { dir.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var reason: String? { UserDefaults.standard.string(forKey: reasonKey) }

    /// Stops the reminder. The files themselves stay where they are.
    static func acknowledge() {
        UserDefaults.standard.removeObject(forKey: filesKey)
        UserDefaults.standard.removeObject(forKey: reasonKey)
    }
}

/// Files waiting to be shared together — the store and its two journal files
/// are one database and only any use as a set.
private struct SharedFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Tells the driver, on every launch until they say otherwise, that the old
/// data was moved aside — and offers to send it somewhere safe.
private struct ParkedStoreNotice: ViewModifier {
    @State private var files: [URL] = []
    @State private var showing = false
    @State private var sharing: SharedFiles?

    private var message: String {
        var text =
            "Beim Start ließen sich die gespeicherten Touren nicht öffnen. Sie wurden "
            + "nicht gelöscht, sondern beiseitegelegt, und die App hat leer neu "
            + "begonnen. Das passiert meist, wenn eine ältere Version der App über "
            + "eine neuere installiert wurde.\n\nBitte die Dateien teilen (AirDrop "
            + "oder Mail an den Entwickler) und die App nicht löschen — sonst sind "
            + "die alten Daten verloren."
        if let reason = ParkedStore.reason, !reason.isEmpty { text += "\n\n\(reason)" }
        return text
    }

    func body(content: Content) -> some View {
        content
            .task {
                files = ParkedStore.files
                showing = !files.isEmpty
            }
            .alert("Alte Tourdaten beiseitegelegt", isPresented: $showing) {
                Button("Dateien teilen") { sharing = SharedFiles(urls: files) }
                Button("Später erinnern", role: .cancel) {}
                Button("Nicht mehr anzeigen", role: .destructive) { ParkedStore.acknowledge() }
            } message: {
                Text(message)
            }
            .sheet(item: $sharing) { shared in
                ShareSheet(items: shared.urls)
            }
    }
}

extension View {
    /// Applied once, at the root, next to the Live Activity sync.
    func noticingParkedStore() -> some View {
        modifier(ParkedStoreNotice())
    }
}
