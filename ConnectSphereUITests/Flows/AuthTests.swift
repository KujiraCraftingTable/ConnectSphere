import XCTest

/// P1: signing in (with and without two-factor), signing up (with and
/// without an email) and logging out.
final class AuthTests: UITestCase {
    private var login: LoginScreen { LoginScreen(app: app) }
    private var main: MainScreen { MainScreen(app: app) }

    func testSignInReachesHome() async throws {
        let account = try await server.createAccount(run: run)
        launch()
        try login.waitUntilShown().signIn(account.username, account.password)
        try main.waitUntilShown()
    }

    func testWrongPasswordShowsError() async throws {
        let account = try await server.createAccount(run: run)
        launch()
        try login.waitUntilShown().signIn(account.username, account.password + "x")
        try login.error.waitToAppear(timeout: 15)
        XCTAssertTrue(login.identifier.exists, "should stay on the sign-in screen")
    }

    func testTwoFactorSignIn() async throws {
        let account = try await server.createAccount(run: run, kind: .twoFactor)
        launch()
        try login.waitUntilShown().signIn(account.username, account.password)
        try login.codeField.waitToAppear(timeout: 15)
        let code = try await server.lastCode(for: try XCTUnwrap(account.email))
        try login.enterCode(code)
        try main.waitUntilShown()
    }

    func testWrongTwoFactorCodeShowsError() async throws {
        let account = try await server.createAccount(run: run, kind: .twoFactor)
        launch()
        try login.waitUntilShown().signIn(account.username, account.password)
        try login.codeField.waitToAppear(timeout: 15)
        let real = try await server.lastCode(for: try XCTUnwrap(account.email))
        try login.enterCode(real == "000000" ? "111111" : "000000")
        try login.codeError.waitToAppear(timeout: 15)
        XCTAssertTrue(login.codeField.exists, "should stay on the code step")
    }

    func testRegisterWithoutEmail() throws {
        launch()
        try login.waitUntilShown().signUp.tapWhenReady()
        try RegisterScreen(app: app).fill(username: username(1), password: "Qa-uitest-\(run)")
        try OnboardingScreen(app: app).completeWithDefaults(displayName: "QA \(run)")
        try main.waitUntilShown()
    }

    func testRegisterWithEmailCodeSubmitsItself() async throws {
        launch()
        try login.waitUntilShown().signUp.tapWhenReady()
        let register = RegisterScreen(app: app)
        try register.fill(username: username(1), password: "Qa-uitest-\(run)", email: email(1))
        try register.codeField.waitToAppear(timeout: 15)
        // No Confirm button: the sixth digit sends it.
        try register.codeField.enter(try await server.lastCode(for: email(1)))
        try OnboardingScreen(app: app).completeWithDefaults(displayName: "QA \(run)")
        try main.waitUntilShown()
    }

    func testLogOutReturnsToSignIn() async throws {
        let account = try await server.createAccount(run: run)
        launch(signedInAs: account)
        try main.waitUntilShown()
        try main.logOut()
        try login.waitUntilShown()
    }
}
