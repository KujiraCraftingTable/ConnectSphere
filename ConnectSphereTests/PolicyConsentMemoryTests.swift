import Foundation
import Testing
@testable import ConnectSphere

/// The login screen remembers the Terms/Privacy tick for one edition only.
struct PolicyConsentMemoryTests {
    private func memory() -> PolicyConsentMemory {
        PolicyConsentMemory(defaults: UserDefaults(suiteName: "PolicyConsentMemoryTests-\(UUID().uuidString)")!)
    }

    @Test func startsUnticked() {
        #expect(!memory().acceptsCurrent)
    }

    @Test func remembersTheCurrentEdition() {
        let m = memory()
        m.remember()
        #expect(m.acceptsCurrent)
        m.forget()
        #expect(!m.acceptsCurrent)
    }

    @Test func anOlderEditionDoesNotCount() {
        let defaults = UserDefaults(suiteName: "PolicyConsentMemoryTests-\(UUID().uuidString)")!
        defaults.set("2020-01-01", forKey: "acceptedPolicyVersion")
        #expect(!PolicyConsentMemory(defaults: defaults).acceptsCurrent)
    }
}
