// Accessibility identifiers the XCUITest suite finds controls by. One file,
// compiled into the app and (through a symlink in ConnectSphereUITests/Support)
// into the UI tests, so a renamed id breaks the build, not a test run.
//
// Scheme: <feature>.<screen>.<element>[.<qualifier>], lowerCamel segments.
// A list row ends in the server id of what it shows; its constant is the
// prefix up to and including the final dot.
// Only plain string constants here: the UI test target has no app code.

enum AXID {
    enum Common {
        static let loading = "common.loading"
        static let codeField = "common.code.field"
        static let codeConfirm = "common.code.confirmButton"
        static let codeResend = "common.code.resendButton"
        static let wardProvinceButton = "common.wardPicker.provinceButton"
        static let wardWardButton = "common.wardPicker.wardButton"
        static let wardProvinceRow = "common.wardPicker.provinceRow."
        static let wardRow = "common.wardPicker.wardRow."
        static let policyCheckbox = "common.policy.checkbox"
        /// Added to a secure field's id for its show/hide eye button.
        static let revealSuffix = ".reveal"
    }

    enum Auth {
        static let loginIdentifier = "auth.login.identifierField"
        static let loginPassword = "auth.login.passwordField"
        static let loginSubmit = "auth.login.submitButton"
        static let loginError = "auth.login.errorText"
        static let loginSignUp = "auth.login.signUpButton"
        static let codeError = "auth.code.errorText"
        static let codeBack = "auth.code.backButton"

        static let registerUsername = "auth.register.usernameField"
        static let registerUsernameAvailable = "auth.register.usernameAvailable"
        static let registerPassword = "auth.register.passwordField"
        static let registerConfirm = "auth.register.confirmField"
        static let registerEmail = "auth.register.emailField"
        static let registerContinue = "auth.register.continueButton"
        static let registerError = "auth.register.errorText"
    }

    enum Onboarding {
        static let modeHobby = "onboarding.mode.hobby"
        static let modeWork = "onboarding.mode.work"
        static let continueButton = "onboarding.continueButton"
        static let displayName = "onboarding.basics.displayNameField"
        /// + "male" / "female" / "other".
        static let gender = "onboarding.basics.gender."
        static let dobButton = "onboarding.basics.dobButton"
        static let dobDone = "onboarding.dob.doneButton"
        static let complete = "onboarding.finish.completeButton"
        static let skip = "onboarding.finish.skipButton"
        static let error = "onboarding.errorText"
    }

    /// The system tab bar takes no identifiers, so these are its English
    /// labels (test mode pins English).
    enum Tab {
        static let home = "Home"
        static let search = "Search"
        static let community = "Community"
        static let jobs = "Jobs"
        static let notifications = "Notifications"
        static let profile = "Profile"
    }

    enum Community {
        static let coverButton = "community.create.coverButton"
        /// + the community id; on the button that opens the community.
        static let row = "community.list.row."
    }

    enum Search {
        static let field = "search.header.field"
        static let aiToggle = "search.header.aiToggle"
        /// + the user id; people results, AI or keyword.
        static let row = "search.results.row."
        static let aiLoading = "search.ai.loading"
    }

    enum Feed {
        /// + "hobby" / "work"
        static let mode = "feed.header.mode."
        static let composerBar = "feed.header.composerBar"
        static let empty = "feed.list.empty"
        /// + "forYou" / "connections" / "following"
        static let scope = "feed.header.scope."
        /// + the post id; contains the post's own buttons below.
        static let postCell = "feed.post.cell."
        static let like = "feed.post.likeButton"
        static let comment = "feed.post.commentButton"
        static let more = "feed.post.moreButton"
        /// The full-screen photo viewer's comment button and its comments panel.
        static let viewerComment = "feed.viewer.commentButton"
        static let viewerPanel = "feed.viewer.panel"
        static let viewerCollapse = "feed.viewer.collapse"
        /// "See more" / "See less" under a long caption.
        static let captionToggle = "feed.post.captionToggle"
    }

    enum Chat {
        static let inboxButton = "feed.header.messagesButton"
        /// + the conversation id, in the inbox, Waiting and Archived lists
        static let row = "chat.inbox.row."
        static let waiting = "chat.inbox.waitingButton"
        static let archived = "chat.inbox.archivedButton"
        static let messageField = "chat.thread.messageField"
        static let send = "chat.thread.sendButton"
    }

    enum Report {
        static let details = "report.sheet.detailsField"
    }

    enum Composer {
        static let text = "composer.main.textView"
        static let post = "composer.main.postButton"
        static let cancel = "composer.main.cancelButton"
        static let drafts = "composer.main.draftsButton"
    }

    enum Comments {
        static let field = "comments.input.textView"
        static let send = "comments.input.sendButton"
        /// + the comment id
        static let row = "comments.list.row."
    }

    enum Profile {
        static let settingsButton = "profile.header.settingsButton"
    }

    enum Assistant {
        static let launcher = "assistant.main.launcher"
        static let settingsRow = "settings.main.assistantRow"
        static let input = "assistant.chat.input"
        static let sendButton = "assistant.chat.sendButton"
        static let takeMeThere = "assistant.chat.takeMeThere"
        static let undo = "assistant.chat.undoButton"
    }

    enum Settings {
        static let logout = "settings.main.logoutButton"
        static let twoFactorToggle = "settings.privacy.twoFactorToggle"
        static let activityToggle = "settings.privacy.activityToggle"
    }

    enum Marketplace {
        static let dealHistoryButton = "marketplace.myItems.dealHistoryButton"
    }
}
