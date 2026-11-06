import Foundation
import Testing
@testable import ConnectSphere

@MainActor
struct AuthViewModelTests {
    @Test func registerLowercasesUsernameAsTyped() {
        let vm = RegisterViewModel()
        vm.username = "Kujira_01"
        #expect(vm.username == "kujira_01")
    }

    @Test func registerEmailIsOptionalButMustLookRight() {
        let vm = RegisterViewModel()
        vm.username = "good_name"
        vm.password = "password1"
        vm.confirmPassword = "password1"
        vm.acceptsPolicy = true
        #expect(!vm.isFormValid)                       // the username isn't confirmed free yet
        vm.usernameStatus = .available
        #expect(vm.isFormValid && !vm.hasEmail)       // no email is fine
        vm.email = "kujira@gmail"
        #expect(vm.emailError != nil && !vm.isFormValid)
        vm.email = " Kujira@Gmail.com "
        #expect(vm.emailError == nil && vm.isFormValid && vm.hasEmail)
        #expect(vm.maskedEmail == "k•••a@gmail.com")
        #expect(vm.stage == .details)
    }

    @Test func registerFormValidOnlyWhenEverythingMatches() {
        let vm = RegisterViewModel()
        vm.username = "ab"
        #expect(vm.usernameError != nil)
        vm.username = "good_name"
        vm.usernameStatus = .available
        vm.password = "password1"
        vm.confirmPassword = "password2"
        #expect(!vm.isFormValid)
        #expect(vm.confirmError != nil)
        vm.confirmPassword = "password1"
        vm.acceptsPolicy = true
        #expect(vm.isFormValid)
        vm.usernameStatus = .taken
        #expect(!vm.isFormValid)
    }

    @Test func registerCodeKeepsOnlyDigits() {
        let vm = RegisterViewModel()
        vm.code = "12 3-4567"
        #expect(vm.code == "123456")
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

    /// A phone that has never ticked the Terms/Privacy box (isolated, so the test doesn't depend on this device).
    private func freshMemory() -> PolicyConsentMemory {
        PolicyConsentMemory(defaults: UserDefaults(suiteName: "AuthViewModelTests-\(UUID().uuidString)")!)
    }

    @Test func onboardingListsWhatIsMissingAndGatesTheCarousel() {
        let vm = OnboardingViewModel(policyMemory: freshMemory())
        vm.prefill(username: "kujira", hasPassword: true)
        #expect(vm.form.username == "kujira" && !vm.needsUsername && !vm.offersPassword)
        #expect(vm.asksForPolicy)                       // a Google-style sign-up that never ticked the box
        #expect(vm.reachableSteps == 2)                 // can't swipe past the basics yet
        #expect(vm.missingBasics.count == 4)            // name, province, birthday, agreement (gender defaults to "other")
        vm.form.display_name = "Kujira"
        vm.form.location = "79"
        vm.form.gender = "male"
        #expect(vm.missingBasics == [Bundle.app.loc("date of birth"),
                                     Bundle.app.loc("your agreement to the Terms and Privacy Policy")])
        vm.acceptsPolicy = true
        #expect(vm.missingBasics == [Bundle.app.loc("date of birth")])
        vm.form.dob = "2000-01-01"
        #expect(vm.basicsComplete && vm.reachableSteps == OnboardingViewModel.totalSteps)
        for _ in 0..<10 { vm.next() }
        #expect(vm.step == OnboardingViewModel.totalSteps - 1)
    }

    @Test func onboardingShowsMissingOnlyAfterARefusal() {
        let vm = OnboardingViewModel(policyMemory: freshMemory())
        vm.prefill(username: "kujira", hasPassword: true)
        vm.next()
        #expect(vm.stillNeeded == nil)
        vm.refusedMove()
        #expect(vm.stillNeeded?.contains(Bundle.app.loc("province")) == true)
    }

    @Test func googleSignUpGetsAnOptionalPassword() {
        let vm = OnboardingViewModel(policyMemory: freshMemory())
        vm.prefill(username: "user_1a2b3c4d", hasPassword: false)
        #expect(vm.offersPassword)
        #expect(vm.newPasswordProblem == nil)           // empty = skipped
        vm.newPassword = "short"
        #expect(vm.newPasswordProblem != nil)
        vm.newPassword = "longenough1"
        vm.confirmNewPassword = "longenough2"
        #expect(vm.newPasswordProblem != nil)
        vm.confirmNewPassword = "longenough1"
        #expect(vm.newPasswordProblem == nil)
    }

    @Test func pendingSignupKeepsItsUsernameAndOffersNoPassword() {
        let vm = OnboardingViewModel(pending: PendingSignup(username: "kujira_manual", password: "pw123456", email: nil, acceptedPolicyVersion: LegalDocs.version))
        vm.prefill(username: nil, hasPassword: false)   // no account yet: ignored
        #expect(vm.form.username == "kujira_manual")
        #expect(!vm.needsUsername && !vm.offersPassword && !vm.usernameLost)
    }

    @Test func carouselNeverLandsPastWhatIsReachable() {
        let vm = OnboardingViewModel(policyMemory: freshMemory())
        vm.prefill(username: "kujira", hasPassword: true)
        vm.show(step: 3)
        #expect(vm.step == 1)
    }

    @Test func onboardingBlocksIncompleteStepAndGoesBack() {
        let vm = OnboardingViewModel(policyMemory: freshMemory())
        vm.prefill(username: "kujira", hasPassword: true)
        #expect(!vm.canGoBack)
        #expect(vm.next())                 // mode → basics
        #expect(!vm.canAdvance)
        #expect(!vm.next())                // basics incomplete: stays
        #expect(vm.step == 1)
        vm.back()
        #expect(vm.step == 0)
    }

    @Test func googleAccountMustChooseAvailableUsername() {
        let vm = OnboardingViewModel(policyMemory: freshMemory())
        vm.prefill(username: "user_1a2b3c4d", hasPassword: false)
        #expect(vm.needsUsername)
        #expect(vm.form.username.isEmpty)   // the placeholder isn't kept
        vm.form.display_name = "K"; vm.form.location = "79"; vm.form.gender = "male"; vm.form.dob = "2000-01-01"
        vm.username = "Kujira_Dev"
        #expect(vm.form.username == "kujira_dev")
        #expect(!vm.basicsComplete)        // not confirmed available yet
    }

    @Test func usernameRulesMatchServerFormat() {
        #expect(UsernameRules.problem("") == nil)
        #expect(UsernameRules.isValid("kujira_99"))
        #expect(!UsernameRules.isValid("ab"))
        #expect(!UsernameRules.isValid("café"))
        #expect(!UsernameRules.isValid("has space"))
        #expect(!UsernameRules.isValid(String(repeating: "a", count: 31)))
        #expect(UsernameRules.isValid(String(repeating: "a", count: 30)))
    }

    @Test func personaSetupNeedsDisplayName() {
        let vm = PersonaSetupViewModel(mode: .work)
        #expect(!vm.isValid)
        vm.displayName = "  "
        #expect(!vm.isValid)
        vm.displayName = "Kujira"
        #expect(vm.isValid)
    }

    @Test func registerNeedsTheTermsAndPrivacyTick() {
        let vm = RegisterViewModel()
        vm.username = "good_name"
        vm.usernameStatus = .available
        vm.password = "password1"
        vm.confirmPassword = "password1"
        #expect(!vm.acceptsPolicy)              // never pre-ticked
        #expect(!vm.isFormValid)
        vm.acceptsPolicy = true
        #expect(vm.isFormValid)
        vm.acceptsPolicy = false
        #expect(!vm.isFormValid)
    }

    @Test func passwordSignUpAsksNothingMoreAboutThePolicy() {
        let pending = PendingSignup(username: "kujira_manual", password: "pw123456", email: nil,
                                    acceptedPolicyVersion: LegalDocs.version)
        let vm = OnboardingViewModel(pending: pending)
        #expect(!vm.asksForPolicy)              // already ticked on the sign-up form
        #expect(vm.missingBasics.allSatisfy { !$0.contains("agreement") })
    }
}
