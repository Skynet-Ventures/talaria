import XCTest
@testable import TalariaKit

final class AssistantMediaProjectionTests: XCTestCase {
    private typealias Projection = AssistantMediaProjection.Projection
    private typealias Reference = AssistantMediaProjection.Reference

    private func reference(_ projection: Projection, _ index: Int = 0) throws -> Reference {
        try XCTUnwrap(projection.references[safe: index])
    }

    private func sourceSlice(_ range: Range<Int>, in source: String) -> String? {
        let bytes = source.utf8
        guard let lower = bytes.index(bytes.startIndex, offsetBy: range.lowerBound,
                                      limitedBy: bytes.endIndex),
              let upper = bytes.index(bytes.startIndex, offsetBy: range.upperBound,
                                      limitedBy: bytes.endIndex) else { return nil }
        return String(decoding: bytes[lower..<upper], as: UTF8.self)
    }

    func testLineAndInlineProjectionPreservesEveryNonDirectiveByte() throws {
        let source = "Before MEDIA:/tmp/a.png after\nMEDIA:https://cdn.example/b.mp3\nend"
        let unchanged = source
        let projection = AssistantMediaProjection.project(source)

        XCTAssertEqual(projection.runs, [
            .text("Before "), .media(try reference(projection, 0)),
            .text(" after\n"), .media(try reference(projection, 1)), .text("\nend"),
        ])
        XCTAssertEqual(projection.text, "Before  after\n\nend")
        XCTAssertEqual(projection.references.map(\.rawValue),
                       ["/tmp/a.png", "https://cdn.example/b.mp3"])
        XCTAssertEqual(projection.references.map(\.ordinal), [0, 1])
        XCTAssertEqual(source, unchanged, "projection must never mutate persisted input")
        for reference in projection.references {
            XCTAssertTrue(sourceSlice(reference.sourceUTF8Range, in: source)?
                .hasPrefix("MEDIA:") == true)
        }
    }

    func testAllQuoteFormsKeepSpacesAndOptionalWhitespaceOutOfRawValue() {
        let source = "MEDIA: \"one two.png\" | MEDIA:\t'three four.mov' | "
            + "MEDIA:`five six.mp3` | MEDIA:\u{a0}seven.webp"
        let projection = AssistantMediaProjection.project(source)
        XCTAssertEqual(projection.references.map(\.rawValue),
                       ["one two.png", "three four.mov", "five six.mp3", "seven.webp"])
        XCTAssertEqual(projection.references.map(\.kind),
                       [.image, .video, .audio, .image])
        XCTAssertEqual(projection.text, " |  |  | ")
        XCTAssertFalse(projection.isClipped)
    }

    func testExactCaseDuplicatesOrderFingerprintAndDisplayNameAreStable() throws {
        let source = "media:/ignored.png MEDIA:/a/repeat.png MEDIA:/a/repeat.png"
        let first = AssistantMediaProjection.project(source)
        let second = AssistantMediaProjection.project(source)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.references.count, 2)
        XCTAssertEqual(first.references.map(\.rawValue), ["/a/repeat.png", "/a/repeat.png"])
        XCTAssertEqual(first.references.map(\.displayName), ["repeat.png", "repeat.png"])
        XCTAssertNotEqual(try reference(first, 0).fingerprint,
                          try reference(first, 1).fingerprint)
        XCTAssertEqual(first.text, "media:/ignored.png  ")
    }

    func testCJKAndSurroundingPunctuationRemainExact() {
        let source = "说明：MEDIA:/tmp/图像.webp 完成！\n（MEDIA:'影片 甲.mp4'）"
        let projection = AssistantMediaProjection.project(source)
        XCTAssertEqual(projection.references.map(\.rawValue),
                       ["/tmp/图像.webp", "影片 甲.mp4"])
        XCTAssertEqual(projection.text, "说明： 完成！\n（）")
    }

    func testFencesInlineCodeBlockquotesAndJSONExamplesAreProtected() {
        let source = """
        ```text
        MEDIA:/inside/fence.png
        ```
        `MEDIA:/inside/inline.png`
        ``MEDIA:/inside/double-inline.png``
        ~~~json
        {"asset":"MEDIA:/inside/tilde-fence.png"}
        ~~~
        > MEDIA:/inside/quote.png
        {"example":"MEDIA:/inside/object.png"}
        ["MEDIA:/inside/array.png"]
        "example": "MEDIA:/inside/property.png"
        Result: {"value":"MEDIA:/inside/inline-object.png copied","nested":["MEDIA:/inside/escaped-\\\"value.png"]}
        [label] MEDIA:/outside/link-context.png done
        MEDIA:/outside/real.png
        """
        let projection = AssistantMediaProjection.project(source)
        XCTAssertEqual(projection.references.map(\.rawValue),
                       ["/outside/link-context.png", "/outside/real.png"])
        XCTAssertTrue(projection.text.contains("MEDIA:/inside/fence.png"))
        XCTAssertTrue(projection.text.contains("`MEDIA:/inside/inline.png`"))
        XCTAssertTrue(projection.text.contains("MEDIA:/inside/double-inline.png"))
        XCTAssertTrue(projection.text.contains("MEDIA:/inside/tilde-fence.png"))
        XCTAssertTrue(projection.text.contains("> MEDIA:/inside/quote.png"))
        XCTAssertTrue(projection.text.contains("MEDIA:/inside/object.png"))
        XCTAssertTrue(projection.text.contains("MEDIA:/inside/inline-object.png"))
        XCTAssertTrue(projection.text.contains("MEDIA:/inside/escaped-\\\"value.png"))
        XCTAssertFalse(projection.text.contains("MEDIA:/outside/real.png"))
    }

    func testStreamingQuotedAndUnquotedTailsRemainProseUntilSafeBoundary() {
        let quoted = "prefix MEDIA:\"partial name.png"
        let quotedPending = AssistantMediaProjection.project(quoted, isStreaming: true)
        XCTAssertTrue(quotedPending.hasPendingDirective)
        XCTAssertEqual(quotedPending.text, quoted)
        XCTAssertTrue(quotedPending.references.isEmpty)

        let completedQuoted = AssistantMediaProjection.project(
            quoted + "\"", isStreaming: true)
        XCTAssertFalse(completedQuoted.hasPendingDirective)
        XCTAssertEqual(completedQuoted.references.map(\.rawValue), ["partial name.png"])

        let unquoted = "prefix MEDIA:/tmp/fragment.png"
        let unquotedPending = AssistantMediaProjection.project(unquoted, isStreaming: true)
        XCTAssertTrue(unquotedPending.hasPendingDirective)
        XCTAssertEqual(unquotedPending.text, unquoted)
        let delimited = AssistantMediaProjection.project(unquoted + " ", isStreaming: true)
        XCTAssertEqual(delimited.references.map(\.rawValue), ["/tmp/fragment.png"])
        XCTAssertEqual(delimited.text, "prefix  ")
        let newlineDelimited = AssistantMediaProjection.project(unquoted + "\n", isStreaming: true)
        XCTAssertEqual(newlineDelimited.references.map(\.rawValue), ["/tmp/fragment.png"])
    }

    func testStreamingEveryASCIIBoundaryNeverConsumesAnIncompleteDirective() {
        let completed = "MEDIA:\"folder/my image.png\" "
        for offset in 0..<completed.utf8.count {
            let bytes = completed.utf8.prefix(offset)
            let prefix = String(decoding: bytes, as: UTF8.self)
            let projection = AssistantMediaProjection.project(prefix, isStreaming: true)
            if prefix.hasSuffix("\"") && prefix.filter({ $0 == "\"" }).count == 2 {
                XCTAssertEqual(projection.references.count, 1, "offset \(offset)")
            } else {
                XCTAssertTrue(projection.references.isEmpty, "offset \(offset)")
            }
        }
    }

    func testDesktopExtensionClassificationIgnoresQueryAndFragment() {
        let image = ["bmp", "gif", "jpeg", "jpg", "png", "svg", "webp"]
        let audio = ["flac", "m4a", "mp3", "ogg", "opus", "wav"]
        let video = ["avi", "mkv", "mov", "mp4", "webm"]
        for ext in image {
            XCTAssertEqual(AssistantMediaProjection.classify("x.\(ext)?download=1#v"), .image)
        }
        for ext in audio {
            XCTAssertEqual(AssistantMediaProjection.classify("x.\(ext.uppercased())#v"), .audio)
        }
        for ext in video {
            XCTAssertEqual(AssistantMediaProjection.classify("x.\(ext)?token=a.b"), .video)
        }
        for value in ["README", "archive.zip", "x.png.exe", "x.png/child"] {
            XCTAssertEqual(AssistantMediaProjection.classify(value), .file, value)
        }
        XCTAssertEqual(AssistantMediaProjection.classify(
            String(repeating: "x", count: AssistantMediaProjection.maximumValueScalars + 1)
                + ".png"), .file)
    }

    func testHostileControlsBidiAndNULFailClosed() {
        for hostile in ["\u{0}", "\u{7f}", "\u{85}", "\u{202e}", "\u{2066}"] {
            let projection = AssistantMediaProjection.project(
                "safe MEDIA:/tmp/a.png\(hostile)tail")
            XCTAssertTrue(projection.isClipped, hostile.debugDescription)
            XCTAssertTrue(projection.runs.isEmpty)
            XCTAssertTrue(projection.references.isEmpty)
        }
    }

    func testInputValueDirectiveCountAndScanWorkBombsFailClosed() {
        let inputBomb = String(repeating: "😀",
            count: AssistantMediaProjection.maximumInputScalars + 1)
        XCTAssertTrue(AssistantMediaProjection.project(inputBomb).isClipped)
        let inputByteBomb = String(repeating: "😀",
            count: AssistantMediaProjection.maximumInputUTF8Bytes / 4 + 1)
        XCTAssertLessThanOrEqual(inputByteBomb.unicodeScalars.count,
                                 AssistantMediaProjection.maximumInputScalars)
        XCTAssertTrue(AssistantMediaProjection.project(inputByteBomb).isClipped)

        let valueBomb = "MEDIA:/" + String(repeating: "x",
            count: AssistantMediaProjection.maximumValueScalars) + ".png"
        XCTAssertTrue(AssistantMediaProjection.project(valueBomb).isClipped)
        let oversizedBytesValue = String(repeating: "😀",
            count: AssistantMediaProjection.maximumValueUTF8Bytes / 4 + 1)
        let valueByteBomb = "MEDIA:" + oversizedBytesValue + " "
        XCTAssertLessThanOrEqual(oversizedBytesValue.unicodeScalars.count,
                                 AssistantMediaProjection.maximumValueScalars)
        XCTAssertTrue(AssistantMediaProjection.project(valueByteBomb).isClipped)

        let countBomb = Array(repeating: "MEDIA:/tmp/x.png",
                              count: AssistantMediaProjection.maximumDirectives + 1)
            .joined(separator: " ")
        let counted = AssistantMediaProjection.project(countBomb)
        XCTAssertTrue(counted.isClipped)
        XCTAssertTrue(counted.runs.isEmpty, "partial directive projection must not escape")

        let workBomb = String(repeating: " MEDIAx", count: 18_000)
        XCTAssertLessThanOrEqual(workBomb.unicodeScalars.count,
                                 AssistantMediaProjection.maximumInputScalars)
        let worked = AssistantMediaProjection.project(workBomb)
        XCTAssertTrue(worked.isClipped)
        XCTAssertTrue(worked.runs.isEmpty)
    }

    func testExactUTF8RangesCoverDirectiveAndFingerprintSurvivesReprojection() throws {
        let source = "前 MEDIA: \"folder/a%20b.png?x=1#frag\" 後"
        let first = AssistantMediaProjection.project(source)
        let item = try reference(first)
        XCTAssertEqual(item.rawValue, "folder/a%20b.png?x=1#frag")
        XCTAssertEqual(item.displayName, "a b.png")
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(sourceSlice(item.sourceUTF8Range, in: source),
                       "MEDIA: \"folder/a%20b.png?x=1#frag\"")
        XCTAssertEqual(item.fingerprint,
                       try reference(AssistantMediaProjection.project(source)).fingerprint)
    }

    func testDisplayNameNeverDecodesControlsBidiOrUnboundedCombiningText() throws {
        let bidi = try reference(AssistantMediaProjection.project(
            "MEDIA:https://cdn.example/x%0A%E2%80%AEname.mp3 "))
        XCTAssertFalse(bidi.displayName.contains("\n"))
        XCTAssertFalse(bidi.displayName.unicodeScalars.contains { scalar in
            scalar.value == 0x202e
        })
        XCTAssertTrue(bidi.displayName.contains("%E2%80%AE"))

        let combining = String(repeating: "e\u{301}", count: 1_000) + ".png"
        let bounded = try reference(AssistantMediaProjection.project(
            "MEDIA:\"/tmp/\(combining)\" "))
        XCTAssertLessThanOrEqual(bounded.displayName.unicodeScalars.count, 101)
    }

    func testCopyProjectionIsAssistantOnly() {
        let literal = "Please type MEDIA:/tmp/literal.png exactly"
        XCTAssertEqual(AssistantMediaProjection.copyText(in: ChatMessage(
            author: .user, text: literal)), literal)
        XCTAssertEqual(AssistantMediaProjection.copyText(in: ChatMessage(
            author: .bot, text: "Before MEDIA:/tmp/card.png after")),
            "Before  after")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
