import XCTest
import SwiftUI
@testable import HermesMobile

final class AttachmentFileTypeTests: XCTestCase {
    func testSpreadsheetExtensionsMapToTableIconAndGreenRampTint() {
        for name in ["report.csv", "data.TSV", "sheet.xls", "sheet.xlsx"] {
            let type = AttachmentFileType(fileName: name)
            XCTAssertEqual(type.iconName, "tablecells", name)
            XCTAssertEqual(type.tintColor, HermesColorRamp.Green.s500.color, name)
        }
    }

    func testTextLikeExtensionsMapToDocTextIconAndBlueRampTint() {
        for name in ["notes.md", "log.txt", "trace.log", "config.xml", "data.yaml", "data.yml", "payload.json"] {
            let type = AttachmentFileType(fileName: name)
            XCTAssertEqual(type.iconName, "doc.text", name)
            XCTAssertEqual(type.tintColor, HermesColorRamp.Blue.s500.color, name)
        }
    }

    func testPDFMapsToDocRichtextIconAndRedRampTint() {
        let type = AttachmentFileType(fileName: "invoice.pdf")

        XCTAssertEqual(type.iconName, "doc.richtext")
        XCTAssertEqual(type.tintColor, HermesColorRamp.Red.s500.color)
    }

    func testArchiveExtensionsMapToArchiveboxIconAndOrangeRampTint() {
        for name in ["bundle.zip", "backup.tar", "archive.gz", "archive.tgz"] {
            let type = AttachmentFileType(fileName: name)
            XCTAssertEqual(type.iconName, "archivebox", name)
            XCTAssertEqual(type.tintColor, HermesColorRamp.Orange.s500.color, name)
        }
    }

    func testUnknownExtensionFallsBackToDocIconAndNeutralRampTint() {
        let type = AttachmentFileType(fileName: "notes.rtf")

        XCTAssertEqual(type.iconName, "doc")
        XCTAssertEqual(type.tintColor, HermesColorRamp.Neutral.s500.color)
    }

    func testBadgeFillIsASubtleDerivationOfTheTintToken() {
        let type = AttachmentFileType(fileName: "invoice.pdf")

        XCTAssertEqual(type.badgeFill, HermesColorRamp.Red.s500.color.opacity(0.15))
    }

    func testExtensionLabelIsUppercasedAndTruncatedToFiveCharacters() {
        XCTAssertEqual(AttachmentFileType(fileName: "report.csv").extensionLabel, "CSV")
        XCTAssertEqual(AttachmentFileType(fileName: "archive.tgz").extensionLabel, "TGZ")
        XCTAssertEqual(AttachmentFileType(fileName: "data.jsonlines").extensionLabel, "JSONL")
    }

    func testMissingExtensionFallsBackToFileLabel() {
        XCTAssertEqual(AttachmentFileType(fileName: "README").extensionLabel, "FILE")
    }
}
