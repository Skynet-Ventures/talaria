#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class ReadAloudPolicyTests: XCTestCase {
    func testSanitizerKeepsVisibleProseAndDropsSpeechHostileSyntax() throws {
        let source = """
        **Answer:** keep this sentence. 😀 https://secret.example/a?token=hush

        [Safe label](https://hidden.example/path)

        | Secret | Value |
        | --- | ---: |
        | API key | never-speak-this |

        ```swift
        let password = "do-not-speak"
        ```
        End.\u{202E}
        """
        let spoken = try XCTUnwrap(ReadAloudPolicy.sanitize(source))
        XCTAssertTrue(spoken.contains("Answer: keep this sentence."))
        XCTAssertTrue(spoken.contains("Safe label"))
        XCTAssertTrue(spoken.contains("Code block omitted."))
        XCTAssertTrue(spoken.contains("End."))
        for leak in ["secret.example", "hidden.example", "API key",
                     "never-speak-this", "password", "do-not-speak", "😀", "\u{202E}"] {
            XCTAssertFalse(spoken.contains(leak), "speech leaked \(leak)")
        }
    }

    func testProjectionBoundaryNeverIncludesReasoningMediaOrGeneratedEchoes() throws {
        let message = ChatMessage(
            author: .bot,
            text: "Visible answer.\nMEDIA: /private/audio.wav",
            reasoning: "private chain of thought")
        let spoken = try XCTUnwrap(ReadAloudPolicy.preparedText(for: message))
        XCTAssertEqual(spoken, "Visible answer.")
        XCTAssertFalse(spoken.contains("private chain"))
        XCTAssertFalse(spoken.contains("audio.wav"))
    }

    func testEligibilityRejectsStreamingFailuresAndNonAssistantRows() {
        XCTAssertNil(ReadAloudPolicy.preparedText(for: ChatMessage(
            author: .bot, text: "partial", isStreaming: true)))
        XCTAssertNil(ReadAloudPolicy.preparedText(for: ChatMessage(
            author: .bot, text: "failed", failure: TurnFailure(
                message: "provider secret", recoverable: true))))
        XCTAssertNil(ReadAloudPolicy.preparedText(for: ChatMessage(
            author: .user, text: "user prompt")))
        XCTAssertNil(ReadAloudPolicy.preparedText(for: ChatMessage(
            author: .system, text: "hidden system row")))
        XCTAssertNil(ReadAloudPolicy.preparedText(for: ChatMessage(
            author: .bot, text: "MEDIA: /only/file.png")))
    }

    func testBoundsFailClosedBeforeAndAfterSanitization() {
        XCTAssertNil(ReadAloudPolicy.sanitize(String(
            repeating: "a", count: ReadAloudPolicy.maximumInputUTF8Bytes + 1)))
        let emoji = String(repeating: "😀", count: ReadAloudPolicy.maximumInputScalars + 1)
        XCTAssertNil(ReadAloudPolicy.sanitize(emoji))
    }

    func testFingerprintIsStableAndTextSensitive() {
        XCTAssertEqual(ReadAloudPolicy.fingerprint("same"),
                       ReadAloudPolicy.fingerprint("same"))
        XCTAssertNotEqual(ReadAloudPolicy.fingerprint("same"),
                          ReadAloudPolicy.fingerprint("changed"))
    }
}
#endif
