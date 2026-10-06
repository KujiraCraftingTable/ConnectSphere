import Testing
@testable import ConnectSphere

@MainActor
struct AuthViewModelTests {
    @Test func registerLowercasesUsernameAsTyped() {
        let vm = RegisterViewModel()
        vm.username = "Kujira_01"
        #expect(vm.username == "kujira_01")
    }

    @Test func registerFlagsBadUsernameAndWeakPassword() {
        let vm = RegisterViewModel()
        vm.username = "ab"
        #expect(vm.usernameError != nil)
        vm.username = "bad name!"
        #expect(vm.usernameError != nil)
        vm.username = "good_name"
        #expect(vm.usernameError == nil)
        vm.password = "short"
        #expect(vm.passwordError != nil)
    }

    @Test func registerFormValidOnlyWhenEverythingMatches() {
        let vm = RegisterViewModel()
        vm.username = "good_name"
        vm.password = "password1"
        vm.confirmPassword = "password2"
        #expect(!vm.isFormValid)
        #expect(vm.confirmError != nil)
        vm.confirmPassword = "password1"
        #expect(vm.isFormValid)
    }

    @Test func forgotPasswordNeedsSixDigitCodeAndMatchingPasswords() {
        let vm = ForgotPasswordViewModel()
        #expect(!vm.canSendCode)
        vm.identifier = "  kujira "
        #expect(vm.canSendCode)
        vm.otp = "12345"
        vm.newPassword = "newpass12"
        vm.confirmPassword = "newpass12"
        #expect(!vm.canReset)
        vm.otp = "123456"
        #expect(vm.canReset)
    }

    @Test func onboardingBasicsAndSkillsParsing() {
        let vm = OnboardingViewModel()
        vm.prefill(username: "kujira")
        #expect(vm.form.username == "kujira")
        #expect(!vm.basicsComplete)
        vm.form.display_name = "Kujira"
        vm.form.location = "79"
        vm.form.gender = "male"
        vm.form.dob = "2000-01-01"
        #expect(vm.basicsComplete)
        vm.skillsText = "Swift, , Python ,UI/UX"
        #expect(vm.form.skills == ["Swift", "Python", "UI/UX"])
        for _ in 0..<10 { vm.next() }
        #expect(vm.step == OnboardingViewModel.totalSteps - 1)
    }

    @Test func personaSetupNeedsDisplayName() {
        let vm = PersonaSetupViewModel(mode: .work)
        #expect(!vm.isValid)
        vm.displayName = "  "
        #expect(!vm.isValid)
        vm.displayName = "Kujira"
        #expect(vm.isValid)
    }
}
