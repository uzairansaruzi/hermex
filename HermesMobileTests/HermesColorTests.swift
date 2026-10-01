import XCTest
import SwiftUI
@testable import HermesMobile

final class HermesColorTests: XCTestCase {
    func testHexColorRoundTripsExactCanonicalString() {
        let c = HermesHexColor("#5B7CFF")
        XCTAssertEqual(c.hex, "#5B7CFF")
    }

    func testHexColorNormalizesLowercaseInputToUppercaseCanonicalForm() {
        let c = HermesHexColor("#5b7cff")
        XCTAssertEqual(c.hex, "#5B7CFF")
    }

    func testEqualHexProducesEqualValueRegardlessOfConstructionPath() {
        XCTAssertEqual(HermesHexColor("#5B7CFF"), HermesHexColor("#5b7cff"))
    }

    // Exhaustive: all 99 ramp values, spot-checked at every step for 3 ramps plus min/max steps for the rest.
    func testNeutralRampAllElevenSteps() {
        XCTAssertEqual(HermesColorRamp.Neutral.s50.hex, "#F9F9FA")
        XCTAssertEqual(HermesColorRamp.Neutral.s100.hex, "#F1F1F2")
        XCTAssertEqual(HermesColorRamp.Neutral.s200.hex, "#DFDFE1")
        XCTAssertEqual(HermesColorRamp.Neutral.s300.hex, "#C9C9CB")
        XCTAssertEqual(HermesColorRamp.Neutral.s400.hex, "#AEAEB1")
        XCTAssertEqual(HermesColorRamp.Neutral.s500.hex, "#8E8E93")
        XCTAssertEqual(HermesColorRamp.Neutral.s600.hex, "#808084")
        XCTAssertEqual(HermesColorRamp.Neutral.s700.hex, "#6D6D71")
        XCTAssertEqual(HermesColorRamp.Neutral.s800.hex, "#58585B")
        XCTAssertEqual(HermesColorRamp.Neutral.s900.hex, "#434345")
        XCTAssertEqual(HermesColorRamp.Neutral.s950.hex, "#2D2D2F")
    }

    func testGoldRampAllElevenSteps() {
        XCTAssertEqual(HermesColorRamp.Gold.s50.hex, "#FFFDF2")
        XCTAssertEqual(HermesColorRamp.Gold.s100.hex, "#FFFAE0")
        XCTAssertEqual(HermesColorRamp.Gold.s200.hex, "#FFF4B8")
        XCTAssertEqual(HermesColorRamp.Gold.s300.hex, "#FFEC85")
        XCTAssertEqual(HermesColorRamp.Gold.s400.hex, "#FFE247")
        XCTAssertEqual(HermesColorRamp.Gold.s500.hex, "#FFD700")
        XCTAssertEqual(HermesColorRamp.Gold.s600.hex, "#E6C200")
        XCTAssertEqual(HermesColorRamp.Gold.s700.hex, "#C4A600")
        XCTAssertEqual(HermesColorRamp.Gold.s800.hex, "#9E8500")
        XCTAssertEqual(HermesColorRamp.Gold.s900.hex, "#786500")
        XCTAssertEqual(HermesColorRamp.Gold.s950.hex, "#524500")
    }

    func testBlueRampAllElevenSteps() {
        XCTAssertEqual(HermesColorRamp.Blue.s50.hex, "#F7F8FF")
        XCTAssertEqual(HermesColorRamp.Blue.s100.hex, "#EBEFFF")
        XCTAssertEqual(HermesColorRamp.Blue.s200.hex, "#D1DAFF")
        XCTAssertEqual(HermesColorRamp.Blue.s300.hex, "#B0C0FF")
        XCTAssertEqual(HermesColorRamp.Blue.s400.hex, "#89A1FF")
        XCTAssertEqual(HermesColorRamp.Blue.s500.hex, "#5B7CFF")
        XCTAssertEqual(HermesColorRamp.Blue.s600.hex, "#5270E6")
        XCTAssertEqual(HermesColorRamp.Blue.s700.hex, "#465FC4")
        XCTAssertEqual(HermesColorRamp.Blue.s800.hex, "#384D9E")
        XCTAssertEqual(HermesColorRamp.Blue.s900.hex, "#2B3A78")
        XCTAssertEqual(HermesColorRamp.Blue.s950.hex, "#1D2852")
    }

    func testRemainingSixRampsMinAndMaxSteps() {
        XCTAssertEqual(HermesColorRamp.Purple.s50.hex, "#FBF6FD")
        XCTAssertEqual(HermesColorRamp.Purple.s500.hex, "#AF52DE")
        XCTAssertEqual(HermesColorRamp.Purple.s950.hex, "#381A47")
        XCTAssertEqual(HermesColorRamp.Red.s50.hex, "#FFF5F5")
        XCTAssertEqual(HermesColorRamp.Red.s500.hex, "#FF3B30")
        XCTAssertEqual(HermesColorRamp.Red.s950.hex, "#52130F")
        XCTAssertEqual(HermesColorRamp.Green.s50.hex, "#F5FCF7")
        XCTAssertEqual(HermesColorRamp.Green.s500.hex, "#34C759")
        XCTAssertEqual(HermesColorRamp.Green.s950.hex, "#11401C")
        XCTAssertEqual(HermesColorRamp.Orange.s50.hex, "#FFFAF5")
        XCTAssertEqual(HermesColorRamp.Orange.s500.hex, "#FB923C")
        XCTAssertEqual(HermesColorRamp.Orange.s950.hex, "#502F13")
        XCTAssertEqual(HermesColorRamp.Cyan.s50.hex, "#F7FEFF")
        XCTAssertEqual(HermesColorRamp.Cyan.s500.hex, "#67E8F9")
        XCTAssertEqual(HermesColorRamp.Cyan.s950.hex, "#214A50")
        XCTAssertEqual(HermesColorRamp.Pink.s50.hex, "#FEF8FB")
        XCTAssertEqual(HermesColorRamp.Pink.s500.hex, "#F472B6")
        XCTAssertEqual(HermesColorRamp.Pink.s950.hex, "#4E243A")
    }

    func testAllNinetyNineValuesAreUniqueAcrossAllRamps() {
        let all: [HermesHexColor] = [
            HermesColorRamp.Neutral.s50, HermesColorRamp.Neutral.s100, HermesColorRamp.Neutral.s200, HermesColorRamp.Neutral.s300, HermesColorRamp.Neutral.s400, HermesColorRamp.Neutral.s500, HermesColorRamp.Neutral.s600, HermesColorRamp.Neutral.s700, HermesColorRamp.Neutral.s800, HermesColorRamp.Neutral.s900, HermesColorRamp.Neutral.s950,
            HermesColorRamp.Gold.s50, HermesColorRamp.Gold.s100, HermesColorRamp.Gold.s200, HermesColorRamp.Gold.s300, HermesColorRamp.Gold.s400, HermesColorRamp.Gold.s500, HermesColorRamp.Gold.s600, HermesColorRamp.Gold.s700, HermesColorRamp.Gold.s800, HermesColorRamp.Gold.s900, HermesColorRamp.Gold.s950,
            HermesColorRamp.Blue.s50, HermesColorRamp.Blue.s100, HermesColorRamp.Blue.s200, HermesColorRamp.Blue.s300, HermesColorRamp.Blue.s400, HermesColorRamp.Blue.s500, HermesColorRamp.Blue.s600, HermesColorRamp.Blue.s700, HermesColorRamp.Blue.s800, HermesColorRamp.Blue.s900, HermesColorRamp.Blue.s950,
            HermesColorRamp.Purple.s50, HermesColorRamp.Purple.s100, HermesColorRamp.Purple.s200, HermesColorRamp.Purple.s300, HermesColorRamp.Purple.s400, HermesColorRamp.Purple.s500, HermesColorRamp.Purple.s600, HermesColorRamp.Purple.s700, HermesColorRamp.Purple.s800, HermesColorRamp.Purple.s900, HermesColorRamp.Purple.s950,
            HermesColorRamp.Red.s50, HermesColorRamp.Red.s100, HermesColorRamp.Red.s200, HermesColorRamp.Red.s300, HermesColorRamp.Red.s400, HermesColorRamp.Red.s500, HermesColorRamp.Red.s600, HermesColorRamp.Red.s700, HermesColorRamp.Red.s800, HermesColorRamp.Red.s900, HermesColorRamp.Red.s950,
            HermesColorRamp.Green.s50, HermesColorRamp.Green.s100, HermesColorRamp.Green.s200, HermesColorRamp.Green.s300, HermesColorRamp.Green.s400, HermesColorRamp.Green.s500, HermesColorRamp.Green.s600, HermesColorRamp.Green.s700, HermesColorRamp.Green.s800, HermesColorRamp.Green.s900, HermesColorRamp.Green.s950,
            HermesColorRamp.Orange.s50, HermesColorRamp.Orange.s100, HermesColorRamp.Orange.s200, HermesColorRamp.Orange.s300, HermesColorRamp.Orange.s400, HermesColorRamp.Orange.s500, HermesColorRamp.Orange.s600, HermesColorRamp.Orange.s700, HermesColorRamp.Orange.s800, HermesColorRamp.Orange.s900, HermesColorRamp.Orange.s950,
            HermesColorRamp.Cyan.s50, HermesColorRamp.Cyan.s100, HermesColorRamp.Cyan.s200, HermesColorRamp.Cyan.s300, HermesColorRamp.Cyan.s400, HermesColorRamp.Cyan.s500, HermesColorRamp.Cyan.s600, HermesColorRamp.Cyan.s700, HermesColorRamp.Cyan.s800, HermesColorRamp.Cyan.s900, HermesColorRamp.Cyan.s950,
            HermesColorRamp.Pink.s50, HermesColorRamp.Pink.s100, HermesColorRamp.Pink.s200, HermesColorRamp.Pink.s300, HermesColorRamp.Pink.s400, HermesColorRamp.Pink.s500, HermesColorRamp.Pink.s600, HermesColorRamp.Pink.s700, HermesColorRamp.Pink.s800, HermesColorRamp.Pink.s900, HermesColorRamp.Pink.s950,
        ]
        XCTAssertEqual(all.count, 99)
        XCTAssertEqual(Set(all.map(\.hex)).count, 99, "every ramp value must be distinct")
    }
}
