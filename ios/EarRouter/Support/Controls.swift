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
    enum Kind { case current, open, done }

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
        }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .current: AnyShapeStyle(Color.accentColor)
        case .open: AnyShapeStyle(Color.accentColor.opacity(0.12))
        case .done: AnyShapeStyle(.quaternary)
        }
    }
}
