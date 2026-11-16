import XCTest
@testable import WispCore

final class HexColorTests: XCTestCase {
    func testParsesUppercaseWithHash() {
        XCTAssertEqual(HexColor("#A3D65C"), HexColor(red: 0xA3, green: 0xD6, blue: 0x5C))
    }

    func testParsesLowercaseWithoutHashAndTrims() {
        XCTAssertEqual(HexColor("  a3d65c\n"), HexColor(0xA3D65C))
    }

    func testRejectsThreeDigitShorthand() {
        XCTAssertNil(HexColor("#ABC"))
        XCTAssertNil(HexColor("abc"))
    }

    func testRejectsGarbage() {
        for text in ["", "#", "#GG0000", "#12345", "#1234567", "12 345", "##A3D65C", "0xA3D65C", "#Ａ3D65C"] {
            XCTAssertNil(HexColor(text), text)
        }
    }

    func testFormatsUppercase() {
        XCTAssertEqual(HexColor("0a0b0c")?.hex, "#0A0B0C")
    }

    func testMixesAndClamps() {
        let black = HexColor(0x000000)
        XCTAssertEqual(black.mixed(with: .white, amount: 0.5), HexColor(0x808080))
        XCTAssertEqual(black.mixed(with: .white, amount: 2), .white)
        XCTAssertEqual(black.mixed(with: .white, amount: -1), black)
    }

    func testCodableAsString() throws {
        let data = try JSONEncoder().encode([HexColor(0xA3D65C)])
        XCTAssertEqual(String(data: data, encoding: .utf8), ##"["#A3D65C"]"##)
        XCTAssertEqual(try JSONDecoder().decode([HexColor].self, from: data), [HexColor(0xA3D65C)])
        XCTAssertThrowsError(try JSONDecoder().decode([HexColor].self, from: Data(##"["#ABC"]"##.utf8)))
    }

    func testLuminanceAndContrast() {
        XCTAssertEqual(HexColor(0x000000).luminance, 0, accuracy: 1e-9)
        XCTAssertEqual(HexColor(0xFFFFFF).luminance, 1, accuracy: 1e-9)
        XCTAssertEqual(HexColor(0x000000).contrastRatio(with: .white), 21, accuracy: 1e-6)
        XCTAssertEqual(HexColor(0xFFFFFF).contrastRatio(with: HexColor(0x000000)), 21, accuracy: 1e-6)
        XCTAssertEqual(HexColor(0x777777).contrastRatio(with: HexColor(0x777777)), 1, accuracy: 1e-9)
    }

    func testTextTokensFollowBackgroundContrast() {
        let defaults = ThemeColors(preset: .lime)
        XCTAssertEqual(defaults.textPrimary, HexColor(0xF2F2F3))
        func custom(_ background: HexColor) -> ThemeColors {
            ThemeColors(custom: CustomTheme(accent: HexColor(0xA3D65C), background: background, surface: background))
        }
        let light = custom(HexColor(0xFFFFFF))
        XCTAssertEqual(light.textPrimary, HexColor(0x141416))
        XCTAssertGreaterThanOrEqual(light.textPrimary.contrastRatio(with: light.background), ThemeColors.minimumTextContrast)
        XCTAssertEqual(custom(HexColor(0x000000)).textPrimary, HexColor(0xF2F2F3))
        XCTAssertEqual(custom(HexColor(0x333333)).textPrimary, HexColor(0xF2F2F3))
        let mid = custom(HexColor(0xB0B0B0))
        XCTAssertGreaterThanOrEqual(mid.textPrimary.contrastRatio(with: mid.background), ThemeColors.minimumTextContrast)
    }
}
