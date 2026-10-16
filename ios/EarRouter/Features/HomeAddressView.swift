import SwiftUI

/// Mehr → Zuhause: the address a "Pause zu Hause" drives to.
///
/// Looked up when it is saved, not when the pause is switched on — see
/// `HomeAddress`. A lookup that fails leaves the saved address as it was.
struct HomeAddressView: View {
    @Binding var home: HomeAddress?

    @State private var strasse = ""
    @State private var plz = ""
    @State private var saving = false
    @State private var error: AppError?
    @State private var loaded = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Straße und Hausnummer", text: $strasse)
                    .autocorrectionDisabled()
                    .textContentType(.fullStreetAddress)
                    .limited(to: FieldLimits.strasse, text: $strasse)
                LabeledContent("PLZ") {
                    HStack(spacing: 10) {
                        if let name = Districts.name(for: plz) {
                            Text(name)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        TextField("1210", text: $plz)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .limited(to: 4, text: $plz)
                            .frame(width: 58)
                    }
                }
            } header: {
                Text("Adresse")
            } footer: {
                Text(
                    "Für „Pause zu Hause“ in einer Tour: die Pause kommt als letzter Stopp "
                        + "vor das Ziel. Bleibt nur auf diesem Gerät.")
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 8) {
                        Text("Speichern")
                        if saving { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(!canSave || saving)

                if home != nil {
                    Button("Adresse löschen", role: .destructive) {
                        HomeAddress.clear()
                        home = nil
                        dismiss()
                    }
                    .disabled(saving)
                }
            }
        }
        .navigationTitle("Zuhause")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($error) { correctedPlz in plz = correctedPlz }
        .task {
            guard !loaded else { return }
            loaded = true
            strasse = home?.strasse ?? ""
            plz = home?.plz ?? ""
        }
    }

    private var canSave: Bool {
        !strasse.trimmed.isEmpty && Postcodes.isValid(plz)
            && (home?.strasse != strasse.trimmed || home?.plz != plz)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let hit = try await Geocoder.shared.geocode(strasse: strasse.trimmed, plz: plz)
            let saved = HomeAddress(strasse: strasse.trimmed, plz: plz, lat: hit.lat, lon: hit.lon)
            saved.save()
            home = saved
            dismiss()
        } catch let known as AppError {
            error = known
        } catch {
            self.error = AppError.message("Die Adresse konnte nicht gefunden werden.")
        }
    }
}
