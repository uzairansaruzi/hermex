import XCTest
@testable import HermesMobile

final class AppIconChoiceTests: XCTestCase {
    func testResolvedMapsAlternateIconNames() {
        XCTAssertEqual(AppIconChoice.resolved(from: nil), .system)
        XCTAssertEqual(AppIconChoice.resolved(from: AppIconChoice.lightAlternateIconName), .light)
        XCTAssertEqual(AppIconChoice.resolved(from: AppIconChoice.darkAlternateIconName), .dark)
        XCTAssertEqual(AppIconChoice.resolved(from: AppIconChoice.discoAlternateIconName), .disco)
        XCTAssertEqual(AppIconChoice.resolved(from: AppIconChoice.monochromeLightAlternateIconName), .monochromeLight)
        XCTAssertEqual(AppIconChoice.resolved(from: AppIconChoice.monochromeDarkAlternateIconName), .monochromeDark)
        XCTAssertEqual(AppIconChoice.resolved(from: AppIconChoice.gradientLightAlternateIconName), .gradientLight)
        XCTAssertEqual(AppIconChoice.resolved(from: AppIconChoice.gradientDarkAlternateIconName), .gradientDark)
        XCTAssertEqual(AppIconChoice.resolved(from: "UnknownIcon"), .system)
    }

    func testAlternateIconNameMapping() {
        XCTAssertNil(AppIconChoice.system.alternateIconName)
        XCTAssertEqual(AppIconChoice.light.alternateIconName, AppIconChoice.lightAlternateIconName)
        XCTAssertEqual(AppIconChoice.dark.alternateIconName, AppIconChoice.darkAlternateIconName)
        XCTAssertEqual(AppIconChoice.disco.alternateIconName, AppIconChoice.discoAlternateIconName)
        XCTAssertEqual(AppIconChoice.monochromeLight.alternateIconName, AppIconChoice.monochromeLightAlternateIconName)
        XCTAssertEqual(AppIconChoice.monochromeDark.alternateIconName, AppIconChoice.monochromeDarkAlternateIconName)
        XCTAssertEqual(AppIconChoice.gradientLight.alternateIconName, AppIconChoice.gradientLightAlternateIconName)
        XCTAssertEqual(AppIconChoice.gradientDark.alternateIconName, AppIconChoice.gradientDarkAlternateIconName)
    }

    func testPreviewImageNameMapping() {
        XCTAssertNil(AppIconChoice.system.previewImageName)
        XCTAssertEqual(AppIconChoice.light.previewImageName, "AppIconLightPreview")
        XCTAssertEqual(AppIconChoice.dark.previewImageName, "AppIconDarkPreview")
        XCTAssertEqual(AppIconChoice.disco.previewImageName, "AppIconDiscoPreview")
        XCTAssertEqual(AppIconChoice.monochromeLight.previewImageName, "AppIconMonochromeLightPreview")
        XCTAssertEqual(AppIconChoice.monochromeDark.previewImageName, "AppIconMonochromeDarkPreview")
        XCTAssertEqual(AppIconChoice.gradientLight.previewImageName, "AppIconGradientLightPreview")
        XCTAssertEqual(AppIconChoice.gradientDark.previewImageName, "AppIconGradientDarkPreview")
    }

    func testAllCasesUseApprovedDisplayOrder() {
        XCTAssertEqual(
            AppIconChoice.allCases,
            [.system, .light, .dark, .disco, .monochromeLight, .monochromeDark, .gradientLight, .gradientDark]
        )
    }

    func testExistingChoiceDisplayMetadata() {
        XCTAssertEqual(AppIconChoice.system.title, "System")
        XCTAssertEqual(AppIconChoice.system.subtitle, "Adapts between the Zora light and ember icons")
        XCTAssertEqual(AppIconChoice.light.title, "Zora Light")
        XCTAssertEqual(AppIconChoice.light.subtitle, "Warm coral Samantha-style icon")
        XCTAssertEqual(AppIconChoice.dark.title, "Zora Ember")
        XCTAssertEqual(AppIconChoice.dark.subtitle, "Deep ember Samantha-style icon")
        XCTAssertEqual(AppIconChoice.disco.title, "Zora Pulse")
        XCTAssertEqual(AppIconChoice.disco.subtitle, "Higher-energy Zora pulse icon")
    }

    func testNewChoiceDisplayMetadata() {
        XCTAssertEqual(AppIconChoice.monochromeLight.title, "Zora Monochrome Light")
        XCTAssertEqual(AppIconChoice.monochromeLight.subtitle, "Quiet monochrome Zora light icon")
        XCTAssertEqual(AppIconChoice.monochromeDark.title, "Zora Monochrome Dark")
        XCTAssertEqual(AppIconChoice.monochromeDark.subtitle, "Quiet monochrome Zora ember icon")
        XCTAssertEqual(AppIconChoice.gradientLight.title, "Zora Gradient Light")
        XCTAssertEqual(AppIconChoice.gradientLight.subtitle, "Saturated Zora light gradient")
        XCTAssertEqual(AppIconChoice.gradientDark.title, "Zora Gradient Dark")
        XCTAssertEqual(AppIconChoice.gradientDark.subtitle, "Saturated Zora ember gradient")
    }

    func testExplicitIconNamesAndPreviewNamesAreUnique() {
        let alternateIconNames = AppIconChoice.allCases.compactMap(\.alternateIconName)
        let previewImageNames = AppIconChoice.allCases.compactMap(\.previewImageName)

        XCTAssertEqual(Set(alternateIconNames).count, alternateIconNames.count)
        XCTAssertEqual(Set(previewImageNames).count, previewImageNames.count)
    }
}
