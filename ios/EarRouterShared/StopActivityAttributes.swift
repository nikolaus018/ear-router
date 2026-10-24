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
        /// Which way and how far the door is — present only once the driver is
        /// close enough for an arrow to be worth drawing.
        var kompass: Kompass?
    }

    /// The arrow that leads the last stretch to the door.
    ///
    /// Already worked out and already coarse: the extension cannot see the
    /// phone's position, so the app hands it an angle and a distance, rounded
    /// so that a state does not change (and cost an update) for every step.
    struct Kompass: Codable, Hashable {
        /// Degrees clockwise from the way the driver is facing: 0 is straight
        /// ahead, 90 is to the right. Whole numbers, in steps of 15.
        var grad: Int
        /// Metres to the door, rounded for reading.
        var meter: Int
        /// Close enough that an arrow is only noise: draw a pin instead.
        var da: Bool
    }

    /// The tour's name — the activity's identity, and deliberately not drawn.
    ///
    /// It is what tells an update to this tour apart from the first stop of the
    /// next one, so the card is replaced rather than relabelled when the driver
    /// moves on. On the card itself it was a line saying which round this is to
    /// somebody who has been driving it since six in the morning.
    var tour: String
}
