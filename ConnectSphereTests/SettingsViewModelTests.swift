import Testing
@testable import ConnectSphere

@MainActor
struct SettingsViewModelTests {
    @Test func changePasswordNeedsCurrentPasswordWhenOneExists() {
        let vm = ChangePasswordViewModel(hasPassword: true)
        vm.newPassword = "newpass123"
        vm.confirmPassword = "newpass123"
        #expect(!vm.canSave)
        vm.currentPassword = "old"
        #expect(vm.canSave)
    }

    @Test func googleAccountSetsFirstPasswordWithoutCurrentOne() {
        let vm = ChangePasswordViewModel(hasPassword: false)
        vm.newPassword = "newpass123"
        vm.confirmPassword = "newpass123"
        #expect(vm.canSave)
    }

    @Test func changePasswordRejectsShortOrMismatched() {
        let vm = ChangePasswordViewModel(hasPassword: false)
        vm.newPassword = "short"
        vm.confirmPassword = "short"
        #expect(!vm.canSave)
        vm.newPassword = "longenough1"
        vm.confirmPassword = "longenough2"
        #expect(!vm.canSave)
        #expect(vm.passwordsMismatch)
    }

    @Test func deleteAccountConfirmation() {
        let withPassword = DeleteAccountViewModel(hasPassword: true)
        #expect(!withPassword.canDelete)
        withPassword.password = "x"
        #expect(withPassword.canDelete)

        let google = DeleteAccountViewModel(hasPassword: false)
        google.confirmationText = "delete"
        #expect(!google.canDelete)          // must be typed exactly
        google.confirmationText = "DELETE"
        #expect(google.canDelete)
    }
}
