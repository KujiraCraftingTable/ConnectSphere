import Testing
import SwiftUI
@testable import ConnectSphere

struct AppMetricsTests {

    @Test func everyFontStyleHasASaneSpec() {
        let styles: [AppFont] = [
            .largeTitle, .title, .title2, .title3,
            .headline, .body, .callout, .subheadline,
            .footnote, .caption, .caption2,
        ]
        var lastSize = CGFloat.greatestFiniteMagnitude
        for style in styles {
            let s = style.spec
            #expect(s.size >= 10 && s.size <= 30)
            // The scale is monotonically non-increasing from largeTitle down.
            #expect(s.size <= lastSize)
            lastSize = s.size
        }
    }

    @Test func spacingScaleIsAscendingAndOn4ptRhythm() {
        let steps = [AppSpacing.xxs, AppSpacing.xs, AppSpacing.sm,
                     AppSpacing.md, AppSpacing.lg, AppSpacing.xl, AppSpacing.xxl]
        #expect(steps == steps.sorted())
        #expect(AppSpacing.sm == 8 && AppSpacing.lg == 16 && AppSpacing.xxl == 32)
    }

    @Test func radiusScaleIsAscending() {
        #expect(AppRadius.sm < AppRadius.md)
        #expect(AppRadius.md < AppRadius.lg)
        #expect(AppRadius.pill > AppRadius.lg)
    }

    @Test func cardElevationIsLighterThanOverlayInBothSchemes() {
        for scheme in [ColorScheme.light, .dark] {
            #expect(AppElevation.card.radius < AppElevation.overlay.radius)
            #expect(AppElevation.card.y < AppElevation.overlay.y)
            _ = AppElevation.card.color(scheme)   // must not crash
        }
    }

    @Test func avatarFallbackIsAHexString() {
        #expect(AppColors.avatarFallback.hasPrefix("#"))
        #expect(AppColors.avatarFallback.count == 7)
    }
}
