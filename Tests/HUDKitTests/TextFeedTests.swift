import XCTest
@testable import HUDKit

final class TextFeedTests: XCTestCase {
    func testAddArgsRequiredOnly() {
        XCTAssertEqual(HUDTextFeed.addArgs(text: "hello", source: "Dictation"),
                       ["action": "add", "text": "hello", "source": "Dictation"])
    }

    func testAddArgsWithTitleAndDate() {
        XCTAssertEqual(HUDTextFeed.addArgs(text: "hello", source: "Dictation", title: "Note", date: "2026-09-28T00:00:00Z"),
                       ["action": "add", "text": "hello", "source": "Dictation",
                        "title": "Note", "date": "2026-09-28T00:00:00Z"])
    }

    func testConstants() {
        XCTAssertEqual(HUDTextFeed.capability, "text-feed")
        XCTAssertEqual(HUDTextFeed.command, "feed")
        XCTAssertEqual(HUDTextFeed.addAction, "add")
    }
}
