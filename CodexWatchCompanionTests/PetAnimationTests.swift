import XCTest
@testable import CodexWatchCompanion

final class PetAnimationTests: XCTestCase {
    func testReviewAnimationLoopsUntilMessageIsRead() {
        let animation = PetAnimation.animation(for: .review)

        XCTAssertEqual(animation.loopStartIndex, 0)
        XCTAssertEqual(animation.frames.map(\.row), Array(repeating: 8, count: 6))
    }

    func testThinkingUsesRunningAnimation() {
        let thinking = PetAnimation.animation(for: .thinking)
        let running = PetAnimation.animation(for: .running)

        XCTAssertEqual(thinking.loopStartIndex, running.loopStartIndex)
        XCTAssertEqual(thinking.frames.map(\.row), running.frames.map(\.row))
        XCTAssertEqual(thinking.frames.map(\.column), running.frames.map(\.column))
    }
}
