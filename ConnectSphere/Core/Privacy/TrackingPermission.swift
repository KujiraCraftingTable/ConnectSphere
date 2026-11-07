import AppTrackingTransparency

/// Apple's "Allow ConnectSphere to track your activity across other companies'
/// apps and websites?" prompt (App Tracking Transparency).
///
/// Switched off on purpose: Apple only allows the prompt for an app that really
/// tracks, and today ConnectSphere has no ads and no analytics SDK, so asking
/// would contradict the Privacy Policy and can fail App Review. Turn it on in the
/// same change that adds an ads or analytics SDK, and then also update the
/// Privacy Policy, `LegalDocs.version` and the App Store privacy labels.
enum TrackingPermission {
    static let isEnabled = false

    /// Asks once; iOS never shows the prompt again after the person has answered.
    /// Call it when the app is already active, a prompt raised too early is dropped.
    @MainActor
    static func requestIfNeeded() async {
        guard isEnabled, ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }
}
