import SwiftUI
import XCTest
@testable import ClarcCore

final class AppearanceModeTests: XCTestCase {
    func testOnlySystemLightAndDarkModesAreExposed() {
        XCTAssertEqual(AppearanceMode.allCases, [.system, .light, .dark])
    }

    func testPreferredColorSchemeResolvesWithoutRecoloringThePalette() {
        XCTAssertNil(AppearanceMode.system.preferredColorScheme)
        XCTAssertEqual(AppearanceMode.light.preferredColorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.preferredColorScheme, .dark)
    }

    @MainActor
    func testThemeStoreDefaultsToClaudePaletteAndFollowsMacOS() {
        XCTAssertEqual(ThemeStore.shared.appearanceMode, .system)
        XCTAssertEqual(ThemeStore.shared.colors.accent.hexString, ThemeColors.claude.accent.hexString)
    }
}
