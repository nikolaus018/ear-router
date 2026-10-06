import SwiftUI

/// A button label that fills the width it is given and centres its icon and
/// title inside it.
///
/// Two reasons this is not just `Button(_:systemImage:)`. That initializer's
/// icon is advisory — in a bordered button inside a `List` the system drops it,
/// so a pair of buttons ended up with one icon between them and looked broken.
/// And without the explicit `maxWidth`, two buttons stacked under each other
/// size to their own titles, so they came out different widths with their text
/// sitting at different places on the screen.
struct WideButtonLabel: View {
    private let title: String
    private let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .imageScale(.medium)
            Text(title)
        }
        .fontWeight(.medium)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Presents an `AppError` as an alert, with the one-tap district correction
    /// when the geocoder offered one.
    func errorAlert(_ error: Binding<AppError?>, onFix: ((String) -> Void)? = nil) -> some View {
        alert(
            "Fehler",
            isPresented: Binding(
                get: { error.wrappedValue != nil },
                set: { if !$0 { error.wrappedValue = nil } })
        ) {
            if case .wrongDistrict(let plz) = error.wrappedValue?.recovery, let onFix {
                Button("Auf \(plz) ändern") {
                    onFix(plz)
                    error.wrappedValue = nil
                }
            }
            Button("OK", role: .cancel) { error.wrappedValue = nil }
        } message: {
            Text(error.wrappedValue?.message ?? "")
        }
    }
}

/// A customer's number in a disc — one mark for one stop, the same in the stop
/// list and on Jetzt, so a number is read the same way on every screen it
/// appears on.
///
/// Three states and one of them loud: the stop the driver is on is a solid
/// accent disc, every other open stop the same disc at 12%, a delivered one
/// grey. That gradient is what makes the finished half of a tour recede
/// without hiding it.
struct StopNumberBadge: View {
    enum Kind {
        case current, open, done
        /// Settled, but the meal never left the van — nicht angetroffen, or
        /// abbestellt. Its own shade rather than `done`, because "the van has
        /// been here" and "this customer got their food" stopped being the
        /// same fact, and the badge is the one place the whole tour is read at
        /// a glance.
        case missed
    }

    let number: Int?
    let kind: Kind
    var size: CGFloat = 26
    var font: Font = .footnote.weight(.semibold).monospacedDigit()

    var body: some View {
        Text(number.map(String.init) ?? "•")
            .font(font)
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .accessibilityHidden(true)
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .current: AnyShapeStyle(Color.white)
        case .open: AnyShapeStyle(Color.accentColor)
        case .done: AnyShapeStyle(.secondary)
        case .missed: AnyShapeStyle(Color.attention)
        }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .current: AnyShapeStyle(Color.accentColor)
        case .open: AnyShapeStyle(Color.accentColor.opacity(0.12))
        case .done: AnyShapeStyle(.quaternary)
        case .missed: AnyShapeStyle(Color.attention.opacity(0.18))
        }
    }
}

extension StopNumberBadge.Kind {
    /// Which of the four a stop wears — the one rule, in the one place.
    ///
    /// It was written out three times: on the stop row, on the map's shared-pin
    /// list, and — differently — on the map's own pin card, which drew its own
    /// disc instead of this badge and so gave an open stop the solid accent
    /// that everywhere else means "the door you are at", and a delivered one a
    /// solid green where the list shows grey. One customer, one number, two
    /// designs, depending on which screen you read it from. Deriving it here is
    /// what makes the badge in `StopNumberBadge`'s own comment — "the same in
    /// the stop list and on Jetzt" — true of the map as well.
    ///
    /// `isNext` is the stop list's business: it is the only screen that shows a
    /// tour in order and can say which door is the current one. A card about
    /// one stop has no such context, so it does not pass it.
    static func of(_ stop: Stop, isNext: Bool = false) -> Self {
        guard let outcome = stop.outcome else { return isNext ? .current : .open }
        return outcome.handedOver ? .done : .missed
    }
}

/// "Einsetzen" — the clipboard into a text editor, and grey when there is
/// nothing on it to put there.
///
/// Still the system `PasteButton` underneath, and deliberately: reading
/// `UIPasteboard.general` ourselves raises iOS's own "… would like to paste
/// from …" alert, whose *default* button is **Don't Allow Paste**. A driver
/// tapping through that at speed denies the paste and lands back on an empty
/// editor — which is the very failure this control is being fixed for, only
/// now with a dialog in front of it. The system control pastes with no alert
/// at all, because the tap on it *is* the permission.
///
/// What it could not do on its own is say when it has nothing to give. A
/// `UIPasteControl` renders exactly as blue and exactly as tappable over an
/// empty pasteboard, and a tap then does nothing whatsoever: no text, no
/// message, no reason — while "Leeren" a few points to its right greys out
/// honestly. That pair is what read as broken. `hasStrings` is what fixes it
/// and costs nothing: it is an existence check, not a read, and raises no
/// alert of its own.
struct PasteTextButton: View {
    let onPaste: (String) -> Void

    /// Whether the pasteboard has text, as of the last time it was worth
    /// asking. Not computed in `body`: that would ask on every redraw of the
    /// screen, including every keystroke typed into the editor beside it.
    @State private var canPaste = UIPasteboard.general.hasStrings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        PasteButton(payloadType: String.self) { items in
            guard let first = items.first, !first.isEmpty else { return }
            onPaste(first)
        }
        .labelStyle(.titleAndIcon)
        .buttonBorderShape(.capsule)
        .disabled(!canPaste)
        .onAppear { canPaste = UIPasteboard.general.hasStrings }
        // Copying happens in the *other* app — the planner, a mail, Safari — so
        // the answer this button needs is usually the one that changed while
        // EAR Router was in the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { canPaste = UIPasteboard.general.hasStrings }
        }
        // …but not always. A document copied on the Mac arrives over Universal
        // Clipboard without this app ever leaving the foreground, and a screen
        // that was opened before the copy would otherwise sit there with the
        // button honestly, and wrongly, greyed out.
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            canPaste = UIPasteboard.general.hasStrings
        }
    }
}

extension View {
    /// A passing pill — "Route wird optimiert …" — floated just above the
    /// bottom of the safe area, over the content rather than beside it.
    ///
    /// These pills used to sit in a `safeAreaInset` of their own, which
    /// reserves room for them, and that was the trouble: the pill arriving and
    /// leaving changed the list's safe area, the change animated along with
    /// the pill, and for the length of that animation the list ended short of
    /// the bottom with a bar of bare black background under the pill. Here the
    /// inset is zero points tall and never changes; the pill hangs above it in
    /// an overlay, so nothing but the pill moves.
    ///
    /// Still an inset rather than an overlay on the content itself: a list
    /// runs underneath the floating tab bar, and an inset is what places the
    /// pill above the bar — and above any inset applied after this one, such
    /// as the tour's "Tour abschließen" button.
    func floatingBanner<Banner: View>(@ViewBuilder _ banner: () -> Banner) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .overlay(alignment: .bottom) {
                    banner()
                        // Its own height, not the zero-point one it hangs from.
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }
        }
    }
}

/// A touch area that tells a tap from a hold — the delivery tick, where a tap
/// means "geliefert" and a hold means "Ins Lager mitnehmen".
///
/// UIKit's recognizers rather than SwiftUI's `onTapGesture` and
/// `onLongPressGesture`, because of where the tick sits: in a list row that
/// has a long-press menu of its own. Tried with the SwiftUI pair, a hold on
/// the tick opened the row's menu and never reached the tick at all. These
/// recognizers ask everything else on the row to wait for them, so the menu
/// (and the row's own tap) only gets a touch the tick did not take.
struct TapOrHold: UIViewRepresentable {
    let onTap: () -> Void
    /// `nil` where there is nothing to hold for; the row's menu then opens
    /// from here as from anywhere else on it.
    var onHold: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        coordinator.tap.addTarget(coordinator, action: #selector(Coordinator.tapped))
        coordinator.hold.addTarget(coordinator, action: #selector(Coordinator.held(_:)))
        coordinator.hold.minimumPressDuration = 0.4
        // A tap recognizer has no upper limit of its own: without this a hold
        // was answered twice, once as it began and again as a tap on release.
        coordinator.tap.require(toFail: coordinator.hold)
        for recognizer in [coordinator.tap, coordinator.hold] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onHold = onHold
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let tap = UITapGestureRecognizer()
        let hold = UILongPressGestureRecognizer()
        var onTap: () -> Void = {}
        var onHold: (() -> Void)?

        @objc func tapped() { onTap() }

        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { onHold?() }
        }

        /// Whether there is anything to hold for is decided as the finger
        /// comes down, and not by switching the recognizer off: the hold
        /// itself settles the door, which takes its own `onHold` away while
        /// the finger is still there — and a recognizer disabled mid-touch
        /// counts as failed, which let the row's menu open after all.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            recognizer !== hold || onHold != nil
        }

        /// Everything else waits for these two — except a pan, so a scroll
        /// that happens to start on the tick is still a scroll.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other !== tap && other !== hold && !(other is UIPanGestureRecognizer)
        }
    }
}
