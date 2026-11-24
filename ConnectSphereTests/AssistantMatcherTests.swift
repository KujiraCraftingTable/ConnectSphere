//
//  AssistantMatcherTests.swift
//  ConnectSphereTests
//
//  Covers `AssistantMatcher`, the assistant's entire decision layer. It is
//  pure, synchronous and dependency-free (no AppState, no network), so it
//  needs no mocking or host app.
//
//  The cases below are mostly regressions: the matcher previously used bare
//  substring containment, which silently fired app-wide actions on phrases
//  that merely appeared inside an unrelated sentence.
//

import Foundation
import Testing
@testable import ConnectSphere

// MARK: - False positives the old substring matcher produced

struct AssistantMatcherPrecisionTests {

    /// The phrase "work profile" really is a token run in this sentence, so
    /// word boundaries alone don't save us. The coverage check has to. The
    /// user is complaining about a picture, not asking to switch app modes.
    @Test func incidentalPhraseAsksBeforeSwitchingMode() {
        let match = AssistantMatcher.match("my work profile picture is wrong")

        #expect(match.intent == .switchMode(.work))
        #expect(match.isConfident == false, "a buried phrase must not execute silently")
    }

    /// "reset it" is a registry phrase for the change-password topic. Word
    /// boundaries stop it hijacking a longer, unrelated sentence into
    /// executing anything, but a guidance reply is text-only (no state
    /// change), so it's fine for that one to still surface as a hint, and it
    /// is deliberately always marked confident since a weak guidance match
    /// costs nothing worse than an unhelpful answer.
    @Test func unrelatedSentenceNeverExecutesAnActionEvenIfGuidanceSurfaces() {
        let match = AssistantMatcher.match("the poll ended so I want to reset it later")
        #expect(match.intent.isInstantlyExecuted == false)
    }

    /// Word-boundary matching: a phrase must not match across word interiors.
    @Test func phraseDoesNotMatchInsideALongerWord() {
        // "go dark" must not be found inside "goes darkroom"
        let match = AssistantMatcher.match("she goes darkroom shopping")
        #expect(match.intent != .setTheme(.dark))
    }

    /// An arbitrary single word that isn't itself a curated registry phrase
    /// must not match anything. Unlike "logout", which the registry commits
    /// to as a deliberate one-word command (covered in
    /// AssistantRegistryTests.everyPhraseResolvesToItsOwnIntent).
    @Test func arbitrarySingleWordDoesNotMatch() {
        #expect(AssistantMatcher.match("settings").intent == .unknown)
        #expect(AssistantMatcher.match("dark").intent == .unknown)
    }

    @Test func emptyAndWhitespaceInputAreUnknown() {
        #expect(AssistantMatcher.match("").intent == .unknown)
        #expect(AssistantMatcher.match("   \n ").intent == .unknown)
    }
}

// MARK: - Direct commands still work

struct AssistantMatcherCommandTests {

    @Test func directCommandsAreConfident() {
        let cases: [(String, AssistantIntent)] = [
            ("switch to dark mode",  .setTheme(.dark)),
            ("switch to light mode", .setTheme(.light)),
            ("switch to work mode",  .switchMode(.work)),
            ("go to settings",       .openSettings),
        ]

        for (input, expected) in cases {
            let match = AssistantMatcher.match(input)
            #expect(match.intent == expected, "\(input) resolved to \(match.intent)")
            #expect(match.isConfident, "\(input) should execute without confirmation")
        }
    }

    /// Punctuation and casing must not defeat matching.
    @Test func matchingIgnoresCaseAndPunctuation() {
        let match = AssistantMatcher.match("Switch to DARK mode, please!")
        #expect(match.intent == .setTheme(.dark))
    }

    /// The longest/most specific registry phrase wins.
    @Test func longestPhraseWins() {
        // "dark mode" (2 tokens) vs "switch to dark mode" (4 tokens)
        let match = AssistantMatcher.match("switch to dark mode")
        #expect(match.intent == .setTheme(.dark))
    }

    /// Guidance intents produce text only, so they never need confirmation.
    @Test func guidanceIsAlwaysConfident() {
        let match = AssistantMatcher.match("how do i change my password?")
        #expect(match.intent == .howTo(topic: .changePassword))
        #expect(match.isConfident)
    }
}

// MARK: - Negation

struct AssistantMatcherNegationTests {

    @Test func negationBeforeThePhraseRejectsIt() {
        #expect(AssistantMatcher.match("I don't want dark mode").intent == .unknown)
        #expect(AssistantMatcher.match("do not switch to work mode").intent == .unknown)
        #expect(AssistantMatcher.match("đừng chuyển sang chế độ tối").intent == .unknown)
    }

    /// Position matters. The old matcher rejected on a cue anywhere in the
    /// string, so a trailing "don't" wrongly cancelled a real command.
    @Test func negationAfterThePhraseDoesNotReject() {
        let match = AssistantMatcher.match("switch to dark mode and don't ask me again")
        #expect(match.intent == .setTheme(.dark))
    }

    /// Negation only guards instantly-executed intents; guidance is just text.
    @Test func negationDoesNotSuppressGuidance() {
        let match = AssistantMatcher.match("I don't know how do i change my password?")
        #expect(match.intent == .howTo(topic: .changePassword))
    }
}

// MARK: - Vietnamese

struct AssistantMatcherVietnameseTests {

    @Test func vietnamesePhrasesMatch() {
        #expect(AssistantMatcher.match("chuyển sang chế độ tối").intent == .setTheme(.dark))
        #expect(AssistantMatcher.match("đi đến cài đặt").intent == .openSettings)
    }

    /// Bilingual matching is intentional. Input in either language resolves
    /// regardless of the app's current language.
    @Test func englishInputStillMatchesWhileVietnameseIsSelected() {
        #expect(AssistantMatcher.match("switch to dark mode").intent == .setTheme(.dark))
    }
}

// MARK: - Suggestion chips

/// The empty-state chips display a localized label and now send that same
/// string. These tests are what stop a future chip or translation edit from
/// silently breaking the Vietnamese chips, which is exactly what used to be
/// papered over by sending hardcoded English.
struct AssistantChipTests {

    /// Keys must stay in sync with `AssistantChatView.emptyState`.
    private static let chipKeys = [
        "Switch to dark mode",
        "How do I change my password?",
        "Go to settings",
    ]

    private func bundle(_ language: String) throws -> Bundle {
        // Anchor on a type compiled into the ConnectSphere app module, not the
        // test bundle, Bundle(for:) with the test's own class would look
        // inside ConnectSphereTests.xctest, which has no .lproj folders at all.
        let path = try #require(
            Bundle(for: AppState.self).path(forResource: language, ofType: "lproj"),
            "missing \(language).lproj"
        )
        return try #require(Bundle(path: path))
    }

    @Test func everyChipResolvesInEnglish() throws {
        let bundle = try bundle("en")
        for key in Self.chipKeys {
            let label = bundle.localizedString(forKey: key, value: key, table: nil)
            #expect(
                AssistantMatcher.match(label).intent != .unknown,
                "EN chip \"\(label)\" does not resolve to an intent"
            )
        }
    }

    @Test func everyChipResolvesInVietnamese() throws {
        let bundle = try bundle("vi")
        for key in Self.chipKeys {
            let label = bundle.localizedString(forKey: key, value: key, table: nil)
            #expect(label != key, "VI translation missing for \"\(key)\"")
            #expect(
                AssistantMatcher.match(label).intent != .unknown,
                "VI chip \"\(label)\" does not resolve to an intent"
            )
        }
    }
}

// MARK: - Registry and guidance invariants

struct AssistantRegistryTests {

    /// The matcher lowercases input before comparing, so an uppercase or
    /// untrimmed registry phrase could never match. Nothing else enforces this.
    @Test func everyRegistryPhraseIsLowercasedAndTrimmed() {
        for command in AssistantCommandRegistry.all {
            for phrase in command.phrases {
                #expect(phrase == phrase.lowercased(), "\"\(phrase)\" is not lowercased")
                #expect(
                    phrase == phrase.trimmingCharacters(in: .whitespacesAndNewlines),
                    "\"\(phrase)\" has surrounding whitespace"
                )
                #expect(!phrase.isEmpty)
            }
        }
    }

    /// Every registry phrase must resolve back to its own command. Catches a
    /// phrase shadowed by a longer phrase on a *different* intent.
    @Test func everyPhraseResolvesToItsOwnIntent() {
        for command in AssistantCommandRegistry.all {
            for phrase in command.phrases {
                let match = AssistantMatcher.match(phrase)
                #expect(
                    match.intent == command.intent,
                    "\"\(phrase)\" resolved to \(match.intent), expected \(command.intent)"
                )
            }
        }
    }

    /// Guidance copy is duplicated between `AssistantIntent.swift` and both
    /// .strings files. `Bundle.loc` falls back to the key, so a drift would be
    /// invisible at runtime. This makes it fail loudly instead.
    @Test func everyGuidanceTopicHasATranslationInBothBundles() throws {
        for language in ["en", "vi"] {
            let path = try #require(
                Bundle(for: AppState.self).path(forResource: language, ofType: "lproj"),
                "missing \(language).lproj"
            )
            let bundle = try #require(Bundle(path: path))

            let keys = AssistantGuidanceTopic.allCases.flatMap { [$0.messageKey, $0.titleKey] }
                + [AssistantGuidanceTopic.setPasswordMessageKey, "I'm not sure what you mean. Is it one of these?"]
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
                #expect(value != "__MISSING__", "\(language): no entry for \"\(key)\"")
            }
        }
    }

    /// Every topic can be asked for in both languages.
    @Test func everyGuidanceTopicHasEnglishAndVietnamesePhrases() {
        for topic in AssistantGuidanceTopic.allCases {
            #expect(topic.phrases.contains { $0.unicodeScalars.allSatisfy(\.isASCII) }, "\(topic): no English phrase")
            #expect(topic.phrases.contains { !$0.unicodeScalars.allSatisfy(\.isASCII) }, "\(topic): no Vietnamese phrase")
        }
    }

    /// A highlight can only point at the topic's own row, and a Profile-tab
    /// target always lands somewhere: a pushed screen or a sheet.
    @Test func everyProfileTargetLandsOnARealScreen() {
        for topic in AssistantGuidanceTopic.allCases {
            guard case .profile(let routes, let sheet, let highlight) = topic.navigationTarget else { continue }
            #expect(!routes.isEmpty || sheet != nil, "\(topic) lands nowhere")
            if let highlight {
                #expect(AssistantGuidanceTopic.highlightableRows.contains(highlight), "\(topic) highlights untagged \(highlight)")
            }
        }
    }

    /// Privacy & Security and deleting live under Manage account, so the
    /// back stack walks Settings → Manage account like a tap-through does.
    @Test func privacyAndDeletingGoThroughManageAccount() {
        let privacy: [ProfileRoute] = [.settings, .manageAccount, .privacySecurity]
        #expect(AssistantGuidanceTopic.changePassword.navigationTarget == .profile(privacy, sheet: .changePassword))
        #expect(AssistantGuidanceTopic.privacySecurity.navigationTarget == .profile(privacy))
        #expect(AssistantGuidanceTopic.blockUser.navigationTarget == .profile(privacy + [.blockedUsers]))
        #expect(AssistantGuidanceTopic.deleteAccount.navigationTarget
                == .profile([.settings, .manageAccount], highlight: .deleteAccount))
    }

    /// A phrase made only of filler words could never be matched.
    @Test func everyPhraseKeepsAMeaningfulWord() {
        for command in AssistantCommandRegistry.all {
            for phrase in command.phrases {
                #expect(!AssistantMatcher.reduce(phrase).isEmpty, "\"\(phrase)\" is all filler")
            }
        }
    }

    /// New questions reach their topic, including the "where is" kind.
    @Test(arguments: [
        ("how do i turn on 2fa", AssistantGuidanceTopic.twoFactor),
        ("where can i download my data", .downloadData),
        ("change my username please", .changeUsername),
        ("make my profile private", .lockProfile),
        ("where is the search radius", .searchRadius),
        ("tôi muốn đổi email", .changeEmail),
        ("khôi phục bài viết đã xoá", .recentlyDeleted),
        ("where are my drafts", .drafts),
        ("delete m account", .deleteAccount),
        ("how do i chnage my pasword", .changePassword),
        ("doi mat khau", .changePassword),
        ("cach xoa tai khoan", .deleteAccount),
        ("who can see my posts", .postPrivacy),
        ("how do deposits work", .deposits),
        ("how do i post a job", .becomeHR),
        ("what can the assistant do", .assistantHelp),
        ("bạn làm được gì", .assistantHelp),
    ])
    func newQuestionsReachTheirTopic(_ input: String, _ topic: AssistantGuidanceTopic) {
        #expect(AssistantMatcher.match(input).intent == .howTo(topic: topic))
    }
}


// MARK: - Forgiving matching

struct AssistantForgivingMatchTests {

    /// A typo never turns one setting into its opposite: the first letter
    /// must agree, so "light" can't read as "night" (a dark-mode phrase).
    @Test func lightModeStaysLight() {
        #expect(AssistantMatcher.match("light mode").intent == .setTheme(.light))
        #expect(AssistantMatcher.match("ligth mode").intent == .setTheme(.light))
    }

    /// Filler words no longer dilute a command, so a polite one is confident.
    @Test func politeCommandIsStillConfident() {
        let match = AssistantMatcher.match("could you please switch to dark mode for me")
        #expect(match.intent == .setTheme(.dark))
        #expect(match.isConfident)
    }

    /// Folding "đừng" would read it as "dùng" (use); negation is checked on
    /// the words as typed, so "use dark mode" isn't treated as a refusal.
    @Test func useIsNotDont() {
        #expect(AssistantMatcher.match("dùng chế độ tối").intent == .setTheme(.dark))
        #expect(AssistantMatcher.match("đừng chuyển sang chế độ tối").intent == .unknown)
    }

    /// Unmatched text with a shared word suggests the closest topics.
    @Test func closestTopicsShareAWord() {
        let near = AssistantMatcher.closestTopics("something about my username please")
        #expect(near.first == .changeUsername)
        #expect(near.count <= 3)
        #expect(!near.contains(.marketplace), "\"something\" alone must not suggest selling")
        #expect(AssistantMatcher.closestTopics("change settings").isEmpty)
    }
}

// MARK: - Safe setting commands

struct AssistantSettingParserTests {

    @Test(arguments: [
        ("turn off message sounds", AssistantIntent.changeSetting(.messageSounds(false))),
        ("enable sounds", .changeSetting(.messageSounds(true))),
        ("tắt âm thanh tin nhắn", .changeSetting(.messageSounds(false))),
        ("bat am thanh", .changeSetting(.messageSounds(true))),
        ("disable ai suggestions", .changeSetting(.aiSuggestions(false))),
        ("set search radius to 12 km", .changeSetting(.searchRadius(10))),
        ("bán kính 25km", .changeSetting(.searchRadius(25))),
        ("search radius unlimited", .changeSetting(.searchRadius(0))),
        ("show posts in the original language, no translation", .changeSetting(.translations(.original))),
        ("turn on translations", .changeSetting(.translations(.translated))),
        ("make my theme amber", .changeSetting(.themeColor("amber"))),
        ("change theme color to deep purple", .changeSetting(.themeColor("deep-purple"))),
        ("change the app icon to sunset", .changeSetting(.appIcon("sunset"))),
        ("turn off dark mode", .setTheme(.light)),
        ("tắt chế độ tối", .setTheme(.light)),
    ])
    func readsTheValue(_ input: String, _ expected: AssistantIntent) {
        #expect(AssistantSettingParser.parse(input) == expected)
    }

    /// Refusals, privacy switches and plain questions are left to the
    /// matcher: it never turns anything on or off for those.
    @Test(arguments: [
        "don't turn off message sounds",
        "đừng tắt âm thanh",
        "turn on 2fa",
        "turn off activity tracking",
        "where is the search radius",
        "what is my theme color",
    ])
    func leavesOthersToTheMatcher(_ input: String) {
        #expect(AssistantSettingParser.parse(input) == nil)
    }

    @Test func everyReplyIsTranslated() throws {
        let keys = [
            "change that setting", "That colour isn't available in this mode. Try one of: %@.",
            "That's already set.", "Changed back. %@", "Theme is %@.", "Message sounds are on.", "Message sounds are off.",
            "AI post suggestions are on.", "AI post suggestions are off.",
            "Posts in the other language now show their translation first.",
            "Posts now show in their original language.", "Search now has no distance limit.",
            "Search now looks within %d km of your ward.", "Theme colour changed to %@.",
            "App icon changed to %@.", "Undo", "Ask the assistant", "Pick a chat to open its settings.",
            "You don't have any group chats yet.", "You don't have any chats yet.",
        ]
        for language in ["en", "vi"] {
            let path = try #require(Bundle(for: AppState.self).path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in keys {
                #expect(bundle.localizedString(forKey: key, value: "__MISSING__", table: nil) != "__MISSING__",
                        "\(language): no entry for \"\(key)\"")
            }
        }
    }
}


// MARK: - Chat pickers

struct AssistantChatPickerTests {

    /// Renaming only makes sense for a group, so only groups are offered.
    @Test func renameOffersGroupsOnly() {
        #expect(AssistantGuidanceTopic.renameGroup.chatPicker == .groups)
        #expect(AssistantGuidanceTopic.muteConversation.chatPicker == .all)
        #expect(AssistantGuidanceTopic.chatTheme.chatPicker == .all)
        #expect(AssistantGuidanceTopic.changePassword.chatPicker == nil)
    }

    /// "change chat theme to rose" is about one chat, never the app's colour.
    @Test func chatThemeIsNotTheAppTheme() {
        #expect(AssistantSettingParser.parse("change chat theme to rose") == nil)
        #expect(AssistantMatcher.match("change chat theme to rose").intent == .howTo(topic: .chatTheme))
        #expect(AssistantMatcher.match("đặt biệt danh").intent == .howTo(topic: .chatNickname))
    }
}
