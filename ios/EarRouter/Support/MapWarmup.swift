import MapKit
import UIKit

/// Boots MapKit early, so the Karte tab does not have to.
///
/// The first `Map` in a process costs several hundred milliseconds of main
/// thread before it draws anything: MapKit loads its resources, opens its
/// connections to the Maps daemons and builds its Metal layer, none of it
/// asynchronous and none of it ours to speed up. Measured on a cold device that
/// is around 370 ms, and it lands entirely on the tap that switches to Karte —
/// so the tab bar highlights and then the app stops, which reads as a hang.
///
/// A throwaway `MKMapView` pays most of that once, at launch, where the work
/// hides inside the launch the driver is already waiting through. It cost about
/// 50 ms there and took roughly 110 ms off the tab switch in the same
/// measurement. The rest of the stall belongs to the real map view's own
/// display setup and cannot be moved.
///
/// Deliberately a plain `MKMapView` rather than a hidden SwiftUI `Map`: the
/// SwiftUI one warms the same things but does its full first-render at launch
/// instead, which cost ~690 ms there and saved no more at the tab switch.
@MainActor
enum MapWarmup {
    private static var view: MKMapView?
    /// Separate from `view`, which goes back to `nil` three seconds later — so
    /// on its own it cannot tell "not warmed yet" from "warmed and cleaned up",
    /// and a second call would build a second throwaway map for nothing.
    private static var hasRun = false

    /// Call once, after the first frame is up. Anything earlier just moves the
    /// cost into the launch the system is still timing.
    static func run() {
        guard !hasRun else { return }
        hasRun = true

        // In the window rather than free-floating: a map view that never
        // reaches a hierarchy never lays out, and it is the layout that does
        // the expensive half of this.
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        map.isHidden = true
        map.isUserInteractionEnabled = false
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?
            .addSubview(map)
        map.layoutIfNeeded()
        view = map

        // Torn down once it has served its purpose. What it warmed is
        // process-wide and outlives it; what it holds on to — tile memory, a
        // Metal layer — is not worth keeping for the rest of the session.
        Task {
            try? await Task.sleep(for: .seconds(3))
            view?.removeFromSuperview()
            view = nil
        }
    }
}
