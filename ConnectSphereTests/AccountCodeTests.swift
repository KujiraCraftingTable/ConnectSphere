import Foundation
import Testing
@testable import ConnectSphere

/// The emailed-code screens: where the code went, what the field accepts,
/// when it can be resent.
struct AccountCodeTests {
    @Test func masksTheAddress() {
        #expect(AccountCode.mask("kujira.personal@gmail.com") == "k•••l@gmail.com")
        #expect(AccountCode.mask("ab@x.io") == "a•••@x.io")
        #expect(AccountCode.mask("not-an-email") == "not-an-email")
    }

    @Test func fieldKeepsSixDigits() {
        #expect(AccountCode.clean("12 34-56") == "123456")
        #expect(AccountCode.clean("1234567") == "123456")
        #expect(AccountCode.clean("abc") == "")
    }

    @Test func resendWaitsAMinute() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(AccountCode.secondsLeft(until: nil, now: now) == 0)
        #expect(AccountCode.secondsLeft(until: now.addingTimeInterval(41.2), now: now) == 42)
        #expect(AccountCode.secondsLeft(until: now.addingTimeInterval(-5), now: now) == 0)
    }

    @MainActor @Test func replacingAVerifiedEmailIsTwoSteps() {
        let vm = EmailVerificationViewModel(replacingVerifiedEmail: true)
        #expect(vm.stage == .overview)
        vm.startChange()
        #expect(vm.stage == .confirmCurrent)
        vm.currentCode = "12a3456789"
        #expect(vm.currentCode == "123456" && !vm.canConfirmCurrent)   // no code sent yet
        vm.code = "123456"
        #expect(!vm.canVerify)                                         // still on step 1
    }

    @MainActor @Test func addingAnEmailIsOneStep() {
        #expect(EmailVerificationViewModel(replacingVerifiedEmail: false).stage == .newEmail)
    }
}
