import Contacts
import SwiftUI

/// Puts a customer's number into the phone's contacts the moment it is dialled
/// from here, as "Maria Huber – EAR-Kunde".
///
/// A customer who does not pick up calls back — an hour later, or in the
/// evening, from a number the phone shows as eleven digits and nothing else.
/// With the name beside it the driver can tell a customer from a stranger
/// before answering, and decide for themselves whether this one matters.
enum CustomerContacts {
    static let suffix = "EAR-Kunde"
    /// Their own group, so a year of customers can be found — and cleared out —
    /// in one place rather than picked out of the address book one by one.
    static let groupName = "EAR-Kunden"

    /// What the call screen shows. The suffix is in the name itself, not in a
    /// company field, because the name is the one line an incoming call is
    /// guaranteed to show.
    static func contactName(for kunde: String?) -> String {
        let name = kunde?.trimmed ?? ""
        return name.isEmpty ? suffix : "\(name) – \(suffix)"
    }

    /// One number in every notation it might already be saved under. The
    /// address book matches a number as written, give or take punctuation, so
    /// "0664 1234567" does not find a contact stored as "+43 664 1234567" —
    /// and a customer the driver already knows would get a second entry.
    static func notations(of dial: String) -> [String] {
        var out = [dial]
        if dial.hasPrefix("+43") {
            out.append("0" + dial.dropFirst(3))
        } else if dial.hasPrefix("0043") {
            out.append("0" + dial.dropFirst(4))
            out.append("+43" + dial.dropFirst(4))
        } else if dial.hasPrefix("0"), !dial.hasPrefix("00") {
            out.append("+43" + dial.dropFirst())
        }
        return out
    }

    /// Dials, having remembered who is being dialled.
    ///
    /// The contact is written in the background and the call does not wait for
    /// it — except the very first time, when iOS asks whether the app may
    /// touch the contacts at all. That question and the "call this number?"
    /// sheet cannot share the screen, so the call follows the answer. Whatever
    /// the answer is, the call goes out.
    @MainActor
    static func call(_ dial: String, for stop: Stop, openURL: OpenURLAction) {
        guard let url = URL(string: "tel:\(dial)") else { return }
        let name = contactName(for: stop.kunde)
        let street = stop.strasse?.trimmed ?? ""
        let plz = stop.plz?.trimmed ?? ""
        Task {
            if await mayWrite() {
                Task.detached(priority: .utility) {
                    remember(dial: dial, name: name, street: street, plz: plz)
                }
            }
            openURL(url)
        }
    }

    private static func mayWrite() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            return (try? await CNContactStore().requestAccess(for: .contacts)) == true
        case .denied, .restricted:
            return false
        default:
            return true
        }
    }

    /// Adds the number, unless the address book already knows it — a contact
    /// the driver made themselves is theirs, and is left exactly as it is.
    private static func remember(dial: String, name: String, street: String, plz: String) {
        let store = CNContactStore()
        let keys = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey,
        ] as [CNKeyDescriptor]

        for number in notations(of: dial) {
            let known = CNContact.predicateForContacts(
                matching: CNPhoneNumber(stringValue: number))
            guard let hits = try? store.unifiedContacts(matching: known, keysToFetch: keys),
                  hits.isEmpty
            else { return }
        }

        let phone = CNLabeledValue(
            label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: dial))
        let request = CNSaveRequest()

        // A second number for a customer already saved from here — the daughter
        // in the note, after the customer's own — joins that contact rather
        // than becoming a second "Maria Huber – EAR-Kunde".
        let sameName = CNContact.predicateForContacts(matchingName: name)
        let existing = (try? store.unifiedContacts(matching: sameName, keysToFetch: keys))?
            .first { $0.givenName == name && $0.familyName.isEmpty }
        let saved: CNContact
        if let existing, let contact = existing.mutableCopy() as? CNMutableContact {
            contact.phoneNumbers.append(phone)
            request.update(contact)
            saved = contact
        } else {
            let contact = CNMutableContact()
            contact.givenName = name
            contact.phoneNumbers = [phone]
            if !street.isEmpty || !plz.isEmpty {
                let address = CNMutablePostalAddress()
                address.street = street
                address.postalCode = plz
                contact.postalAddresses = [CNLabeledValue(label: CNLabelWork, value: address)]
            }
            request.add(contact, toContainerWithIdentifier: nil)
            saved = contact
        }
        guard (try? store.execute(request)) != nil else { return }
        guard existing == nil else { return }

        // The group is a separate save, after the contact's own: not every
        // account can hold groups, and a contact without one is still the
        // whole point.
        addToGroup(saved, in: store)
    }

    private static func addToGroup(_ contact: CNContact, in store: CNContactStore) {
        var group = (try? store.groups(matching: nil))?.first { $0.name == groupName }
        if group == nil {
            let new = CNMutableGroup()
            new.name = groupName
            let create = CNSaveRequest()
            create.add(new, toContainerWithIdentifier: nil)
            guard (try? store.execute(create)) != nil else { return }
            group = new
        }
        guard let group else { return }
        let join = CNSaveRequest()
        join.addMember(contact, to: group)
        try? store.execute(join)
    }
}
