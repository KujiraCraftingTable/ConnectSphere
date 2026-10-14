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

    @Test func deletingNeedsTheEmailedCode() {
        let vm = DeleteScopeViewModel(scope: .work)
        vm.code = "123456"
        #expect(!vm.canDelete)   // no code was sent yet
        vm.code = "12x"
        #expect(vm.code == "12")
    }
}
