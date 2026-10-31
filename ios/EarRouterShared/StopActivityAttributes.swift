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
        /// The street and house number, without the postcode: the card is read
        /// at the door by somebody who drove there, not by somebody addressing
        /// an envelope.
        var adresse: String
        /// What to carry up, if anything.
        var paket: String?
        /// The door's note. The one field here that can be a paragraph, and the
        /// one most worth reading before ringing.
        var notiz: String?
        /// The floor, already written out ("3. Stock"): `Format.floor` lives in
        /// the app target and the extension cannot see it.
        ///
        /// From the Globale Infos rather than from the stop — it is the fact
        /// that outlives every tour, and the reason the app asks for it once.
        var stockwerk: String?
        /// The standing note about this customer, also from Globale Infos:
        /// "klingelt nicht, klopfen", "Lift seit Mai kaputt". Distinct from
        /// `notiz`, which is what today's list said about today's delivery.
        var kundeninfo: String?
        /// The stop's number on the tour, for the badge.
        var number: Int?
    }

    /// The tour's name — the activity's identity, and deliberately not drawn.
    ///
    /// It is what tells an update to this tour apart from the first stop of the
    /// next one, so the card is replaced rather than relabelled when the driver
    /// moves on. On the card itself it was a line saying which round this is to
    /// somebody who has been driving it since six in the morning.
    var tour: String
}
