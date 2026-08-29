#if canImport(XCTest)
import XCTest
@testable import TalariaUI
import TalariaTheme

final class AttachmentSourcePresentationTests: XCTestCase {
    func testSourceSheetPresentsEverySupportedAttachmentChoice() {
        let options = AttachmentSourcePresentation.options(
            supportsPhotoLibrary: true,
            allowsPaste: true
        )

        XCTAssertEqual(AttachmentSourcePresentation.title, "Add to message")
        XCTAssertEqual(options.map(\.action), [.photos, .files, .pasteImage])
        XCTAssertEqual(options.map(\.title), ["Photo Library", "Files", "Paste Image"])
        XCTAssertEqual(options.first?.detail, "Choose up to 6 photos")
        XCTAssertGreaterThanOrEqual(AttachmentSourcePresentation.minimumRowHeight, 44)
    }

    func testSourceSheetHidesPhotoLibraryWhenThePresenterCannotOpenIt() {
        let options = AttachmentSourcePresentation.options(allowsPaste: true)

        XCTAssertEqual(options.map(\.action), [.files, .pasteImage])
        XCTAssertFalse(options.contains { $0.action == .photos })
        XCTAssertEqual(options.map(\.title), ["Files", "Paste Image"])
    }

    func testSourceSheetLeavesFilesWhenNoOptionalSourceIsAvailable() {
        let options = AttachmentSourcePresentation.options(
            supportsPhotoLibrary: false,
            allowsPaste: false
        )

        XCTAssertEqual(options.map(\.action), [.files])
        XCTAssertFalse(options.contains { $0.action == .photos })
        XCTAssertFalse(options.contains { $0.action == .pasteImage })
        XCTAssertTrue(options.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
    }

    func testSourceSheetUsesTilesForNormalTypeAndRowsForAccessibilityType() {
        XCTAssertEqual(
            AttachmentSourcePresentation.layout(isAccessibilitySize: false),
            .tiles
        )
        XCTAssertEqual(
            AttachmentSourcePresentation.layout(isAccessibilitySize: true),
            .rows
        )
    }

    func testSourceSheetMovesLargestNonAccessibilityTypeToRowsBeforeTileClipping() {
        XCTAssertEqual(
            AttachmentSourcePresentation.layout(dynamicTypeSize: .xLarge),
            .tiles
        )
        XCTAssertEqual(
            AttachmentSourcePresentation.layout(dynamicTypeSize: .xxLarge),
            .rows
        )
        XCTAssertEqual(
            AttachmentSourcePresentation.layout(dynamicTypeSize: .xxxLarge),
            .rows
        )
        XCTAssertEqual(
            AttachmentSourcePresentation.layout(dynamicTypeSize: .accessibility1),
            .rows
        )
    }

    func testNormalPaletteUsesTwoOrThreeColumnsWithoutEmptyColumns() {
        XCTAssertEqual(AttachmentSourcePresentation.tileColumnCount(optionCount: 1), 1)
        XCTAssertEqual(AttachmentSourcePresentation.tileColumnCount(optionCount: 2), 2)
        XCTAssertEqual(AttachmentSourcePresentation.tileColumnCount(optionCount: 3), 3)
        XCTAssertEqual(AttachmentSourcePresentation.tileColumnCount(optionCount: 7), 3)
    }

    func testCompactDetentFitsOnePaletteRowAndAllTouchTargets() {
        XCTAssertGreaterThanOrEqual(AttachmentSourcePresentation.minimumTouchTarget, 44)
        XCTAssertGreaterThanOrEqual(AttachmentSourcePresentation.minimumRowHeight, 44)
        XCTAssertGreaterThanOrEqual(AttachmentSourcePresentation.minimumTileHeight, 44)
        XCTAssertEqual(
            AttachmentSourcePresentation.tileRowCount(optionCount: 3, columns: 3),
            1
        )
        XCTAssertLessThan(
            AttachmentSourcePresentation.compactDetentHeight(optionCount: 3, columns: 3),
            300
        )
        XCTAssertGreaterThan(
            AttachmentSourcePresentation.compactDetentHeight(optionCount: 3, columns: 2),
            AttachmentSourcePresentation.compactDetentHeight(optionCount: 3, columns: 3)
        )
    }

    func testAttachmentPickerMotionUsesQuickerDismissalAndSuppressesReducedMotion() {
        XCTAssertEqual(
            TalariaMotionTokens.duration(.fast),
            0.15
        )
        XCTAssertEqual(
            TalariaMotionTokens.duration(.standard),
            0.30
        )
        XCTAssertGreaterThan(
            TalariaMotionTokens.duration(AttachmentSourcePresentation.enterPace),
            TalariaMotionTokens.duration(AttachmentSourcePresentation.dismissPace)
        )
        XCTAssertNotNil(AttachmentSourcePresentation.enterAnimation(reducedMotion: false))
        XCTAssertNotNil(AttachmentSourcePresentation.dismissAnimation(reducedMotion: false))
        XCTAssertNil(AttachmentSourcePresentation.enterAnimation(reducedMotion: true))
        XCTAssertNil(AttachmentSourcePresentation.dismissAnimation(reducedMotion: true))
    }
}
#endif
