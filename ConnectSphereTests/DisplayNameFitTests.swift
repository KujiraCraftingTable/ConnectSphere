import Testing
import UIKit
@testable import ConnectSphere

/// Whether a display name fits its comment header on a 6.1" iPhone (390 pt
/// wide), the screen the 30-character limit was chosen for. The header
/// tries `CommentRow.nameScales` in order and keeps the first size at which
/// the line fits; this works out which one that is, from the real fonts and
/// the row's own layout constants, so a layout change that breaks the fit
/// fails here.
@MainActor
struct DisplayNameFitTests {
    private static let screenWidth: CGFloat = 390
    /// UIKit measures a little narrower than SwiftUI draws.
    private static let slack: CGFloat = 2

    private func width(_ text: String, _ size: CGFloat, _ weight: UIFont.Weight) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight)]).width)
    }

    /// The bubble's text width at `level` in the post screen: the screen, less
    /// the page's side gutters, the reply indent, the row insets, the avatar
    /// and its gap, and the bubble's padding.
    private func bubbleTextWidth(level: Int) -> CGFloat {
        Self.screenWidth - 2 * AppSpacing.sm - CGFloat(level) * ThreadLinesShape.indentStep
            - 2 * CommentRow.horizontalInset - CommentRow.avatarSize - CommentRow.avatarSpacing
            - 2 * CommentRow.bubblePadding
    }

    /// Room for the name beside the Author badge (6 pt padding each side, 4 pt gap).
    private func nameRoom(level: Int) -> CGFloat {
        bubbleTextWidth(level: level) - (width("Author", CommentRow.badgeFontSize(level: level), .bold) + 12) - 4 - Self.slack
    }

    private func repliedToRoom(level: Int) -> CGFloat {
        bubbleTextWidth(level: level) - width("replied to", CommentRow.nameFontSize(level: level), .regular) - 4 - Self.slack
    }

    /// The scale the header picks: the first in the ladder that fits.
    private func pickedScale(_ name: String, level: Int, room: CGFloat) -> CGFloat? {
        CommentRow.nameScales.first { width(name, CommentRow.nameFontSize(level: level) * $0, .semibold) <= room }
    }

    /// A full-length real name in capitals shrinks a few percent at most,
    /// not something anyone notices.
    @Test func realCapitalNamesBarelyShrinkOnATopLevelComment() {
        let name = "NGUYỄN THỊ MINH KHAI HOÀNG ANH"
        #expect(name.count == DisplayNameRules.maxLength)
        #expect((pickedScale(name, level: 0, room: nameRoom(level: 0)) ?? 0) >= 0.94)
    }

    @Test func shortNamesKeepTheirSize() {
        for level in 0...2 {
            #expect(pickedScale("Kujira", level: level, room: repliedToRoom(level: level)) == 1)
        }
    }

    @Test func theWidestNameStillFitsOnOneLineAtEveryLevel() {
        let widest = String(repeating: "W", count: DisplayNameRules.maxLength)
        for level in 0...2 {
            #expect(pickedScale(widest, level: level, room: nameRoom(level: level)) != nil, "name line, level \(level)")
            if level > 0 {
                #expect(pickedScale(widest, level: level, room: repliedToRoom(level: level)) != nil,
                        "replied-to line, level \(level)")
            }
        }
    }

    @Test func capKeepsTheFirst30Characters() {
        let long = String(repeating: "Ă", count: 40)
        #expect(DisplayNameRules.capped(long).count == 30)
        #expect(DisplayNameRules.capped("Kujira") == "Kujira")
    }
}
