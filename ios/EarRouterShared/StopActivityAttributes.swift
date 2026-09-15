import ActivityKit
import Foundation

/// The door the driver is on, as the lock screen and the Dynamic Island show it.
///
/// Compiled into both the app and the widget extension — the app writes these
/// values, the extension draws them, and they are two separate binaries, so the
/// shape has to be one shared declaration rather than two that agree today.
///
/// Everything here is already-formatted text. A Live Activity is rendered by a
/// process that has no SwiftData store, no geocoder and no access to the app's
/// own model: whatever the extension needs to draw has to have been handed to
/// it in the payload. Hence `adresse` rather than a `Stop`, and hence no ids.
struct StopActivityAttributes: ActivityAttributes {
    /// The part that changes as the tour is worked.
    struct ContentState: Codable, Hashable {
        var kunde: String
        /// "Straße, PLZ" — the same line the stop list shows.
        var adresse: String
        /// What to carry up, if anything.
        var paket: String?
        /// The door's note. The one field here that can be a paragraph, and the
        /// one most worth reading before ringing.
        var notiz: String?
        /// The stop's number on the tour, for the badge.
        var number: Int?
        /// Doors answered for, out of how many — the tour's own progress line.
        var done: Int
        var total: Int

        /// "Stopp 7 von 18" when the stop is numbered, the progress alone when
        /// it is not. Computed rather than stored: it is derived from two
        /// numbers already in the payload, and a third field is a third thing
        /// that can disagree with the other two.
        var progress: String {
            guard total > 0 else { return "" }
            return "\(done) von \(total) erledigt"
        }
    }

    /// The tour's name. Fixed for the life of the activity — a new tour is a
    /// new activity, not an update to this one.
    var tour: String
}
