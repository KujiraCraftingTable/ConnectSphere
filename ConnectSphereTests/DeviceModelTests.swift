import Foundation
import Testing
@testable import ConnectSphere

struct DeviceModelTests {
    @Test func namesKnownIPhones() {
        #expect(DeviceModel.name(forIdentifier: "iPhone18,3", fallback: "iPhone") == "iPhone 17")
        #expect(DeviceModel.name(forIdentifier: "iPhone17,1", fallback: "iPhone") == "iPhone 16 Pro")
        #expect(DeviceModel.name(forIdentifier: "iPhone14,6", fallback: "iPhone") == "iPhone SE (3rd generation)")
    }

    @Test func unknownModelsFallBackInsteadOfGuessing() {
        #expect(DeviceModel.name(forIdentifier: "iPhone99,9", fallback: "iPhone") == "iPhone")
        #expect(DeviceModel.name(forIdentifier: "iPad14,1", fallback: "iPad") == "iPad")
    }

    @Test func deviceNameSurvivesAHeaderRoundTrip() {
        let text = "iPhone 17 · iOS 27.0"
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: " .-_()")))!
        let isASCII = encoded.allSatisfy { $0.isASCII }
        #expect(isASCII)
        #expect(encoded.removingPercentEncoding == text)
    }
}
