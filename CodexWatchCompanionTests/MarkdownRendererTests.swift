import SwiftUI
import XCTest
@testable import CodexWatchCompanion

final class MarkdownRendererTests: XCTestCase {
    func testRendersPlainTextFromMarkdown() {
        let output = CodexMarkdownRenderer.attributedString(
            "Use **bold**, `inlineCode`, and [docs](https://example.com).",
            size: 15
        )

        XCTAssertEqual(String(output.characters), "Use bold, inlineCode, and docs.")
    }

    func testPreservesInlineCodeIntentAndLinkAttribute() {
        let output = CodexMarkdownRenderer.attributedString(
            "Run `npm test` then read [docs](https://example.com).",
            size: 15
        )

        XCTAssertTrue(output.hasRun(containing: "npm test") { run in
            run.inlinePresentationIntent?.contains(.code) == true
        })
        XCTAssertTrue(output.hasRun(containing: "docs") { run in
            run.link?.absoluteString == "https://example.com"
        })
    }

    func testEmphasisIntentSurvivesRendering() {
        let output = CodexMarkdownRenderer.attributedString(
            "This is **strong** and this is _emphasized_.",
            size: 15
        )

        XCTAssertTrue(output.hasRun(containing: "strong") { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertTrue(output.hasRun(containing: "emphasized") { run in
            run.inlinePresentationIntent?.contains(.emphasized) == true
        })
    }

    func testMalformedMarkdownFallsBackToReadableText() {
        let output = CodexMarkdownRenderer.attributedString(
            "Keep unmatched [`code visible.",
            size: 15
        )

        XCTAssertTrue(String(output.characters).contains("code visible"))
    }
}

private extension AttributedString {
    func hasRun(
        containing needle: String,
        predicate: (AttributedString.Runs.Run) -> Bool
    ) -> Bool {
        runs.contains { run in
            String(characters[run.range]).contains(needle) && predicate(run)
        }
    }
}
