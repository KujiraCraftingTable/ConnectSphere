import XCTest

/// Sign-in, its two-factor code step, sign-up and onboarding.
struct LoginScreen {
    let app: XCUIApplication

    var identifier: XCUIElement { app.textFields[AXID.Auth.loginIdentifier] }
    var password: XCUIElement { app.secureTextFields[AXID.Auth.loginPassword] }
    var submit: XCUIElement { app.buttons[AXID.Auth.loginSubmit] }
    var error: XCUIElement { app.staticTexts[AXID.Auth.loginError] }
    var signUp: XCUIElement { app.buttons[AXID.Auth.loginSignUp] }
    /// The age and Terms/Privacy box: Sign up and Google wait for it, Log in doesn't.
    var policy: XCUIElement { app.buttons[AXID.Common.policyCheckbox] }

    var codeField: XCUIElement { app.textFields[AXID.Common.codeField] }
    var verify: XCUIElement { app.buttons[AXID.Common.codeConfirm] }
    var codeError: XCUIElement { app.staticTexts[AXID.Auth.codeError] }

    @discardableResult
    func waitUntilShown(timeout: TimeInterval = 15) throws -> Self {
        try identifier.waitToAppear(timeout: timeout)
        return self
    }

    /// Ticks the box unless it is already ticked (the tick is remembered).
    func agree() throws {
        try policy.waitToAppear(timeout: 15)
        if (policy.value as? String) != "✓" { try policy.tapWhenReady() }
    }

    func openSignUp() throws {
        try agree()
        try signUp.tapWhenReady()
    }

    func signIn(_ username: String, _ secret: String) throws {
        try identifier.enter(username)
        try password.enter(secret)
        try submit.tapWhenReady()
    }

    func enterCode(_ code: String) throws {
        try codeField.waitToAppear(timeout: 15)
        try codeField.enter(code)
        try verify.tapWhenReady()
    }
}

struct RegisterScreen {
    let app: XCUIApplication

    var username: XCUIElement { app.textFields[AXID.Auth.registerUsername] }
    var available: XCUIElement { app.descendants(matching: .any)[AXID.Auth.registerUsernameAvailable] }
    var password: XCUIElement { app.secureTextFields[AXID.Auth.registerPassword] }
    var confirm: XCUIElement { app.secureTextFields[AXID.Auth.registerConfirm] }
    var email: XCUIElement { app.textFields[AXID.Auth.registerEmail] }
    var proceed: XCUIElement { app.buttons[AXID.Auth.registerContinue] }
    var codeField: XCUIElement { app.textFields[AXID.Common.codeField] }

    /// Fills the form and taps Continue (to the code step with an email,
    /// straight to onboarding without).
    func fill(username name: String, password secret: String, email address: String? = nil) throws {
        try username.enter(name)
        try available.waitToAppear(timeout: 15)
        try password.enter(secret)
        try confirm.enter(secret)
        if let address { try email.enter(address) }
        try proceed.tapWhenReady()
    }
}

struct OnboardingScreen {
    let app: XCUIApplication

    private var continueButtons: XCUIElementQuery { app.buttons.matching(identifier: AXID.Onboarding.continueButton) }

    /// Hobby mode, the basics (first province and ward, "Other", the default
    /// birthday), no interests, no bio.
    func completeWithDefaults(displayName: String) throws {
        try app.buttons[AXID.Onboarding.modeHobby].tapWhenReady(timeout: 15)
        try continueButtons.hittable().tap()

        try app.textFields[AXID.Onboarding.displayName].enter(displayName)
        try pickFirst(button: AXID.Common.wardProvinceButton, rows: AXID.Common.wardProvinceRow)
        try pickFirst(button: AXID.Common.wardWardButton, rows: AXID.Common.wardRow)
        try app.buttons[AXID.Onboarding.gender + "other"].tapWhenReady()
        try app.buttons[AXID.Onboarding.dobButton].tapWhenReady()
        try app.buttons[AXID.Onboarding.dobDone].tapWhenReady()
        try continueButtons.hittable().tap()

        // Interests are optional.
        try continueButtons.hittable().tap()
        try app.buttons[AXID.Onboarding.skip].tapWhenReady()
    }

    private func pickFirst(button: String, rows prefix: String) throws {
        try app.buttons[button].tapWhenReady()
        try app.buttons.withIDPrefix(prefix).firstMatch.tapWhenReady(timeout: 15)
    }
}
