import Foundation

/// What switching "Pause zu Hause" on cost, said once it is on: the
/// kilometres still to drive after the re-plan against the kilometres before
/// it. In kilometres, not minutes — the driver weighs a detour by how far it
/// goes — and nothing about how long the pause takes, which nobody can say.
enum PauseDetour {
    /// `nil` on either side: the tour was not routed then — OSRM down, or a
    /// route already out of date — and a difference against it would be a
    /// number about something else.
    static func notice(kmBefore: Double?, kmAfter: Double?) -> String {
        guard let kmBefore, let kmAfter else { return "Pause eingeplant" }
        let extra = Format.km(max(0, kmAfter - kmBefore)) ?? "0,0 km"
        return "Pause eingeplant · Umweg +\(extra)"
    }
}
