import XCTest
@testable import Selector

final class LinkContextFetcherTests: XCTestCase {
    func testExactURLIsDominant() {
        XCTAssertEqual(
            LinkContextFetcher.dominantURL(in: "https://example.com/article")?.absoluteString,
            "https://example.com/article"
        )
    }

    func testWhitespacePaddedURLIsDominant() {
        XCTAssertNotNil(LinkContextFetcher.dominantURL(in: "  https://example.com  \n"))
    }

    func testURLBuriedInProseIsNotDominant() {
        let text = "Check out this really interesting article I found yesterday at https://example.com when you have some spare time to read it"
        XCTAssertNil(LinkContextFetcher.dominantURL(in: text))
    }

    func testTwoURLsAreNotDominant() {
        XCTAssertNil(LinkContextFetcher.dominantURL(in: "https://example.com https://example.org"))
    }

    func testNonHTTPSchemeIsRejected() {
        XCTAssertNil(LinkContextFetcher.dominantURL(in: "ftp://example.com/file"))
    }

    func testPlainTextHasNoDominantURL() {
        XCTAssertNil(LinkContextFetcher.dominantURL(in: "just some ordinary selected text"))
    }

    func testEmptyTextHasNoDominantURL() {
        XCTAssertNil(LinkContextFetcher.dominantURL(in: "   "))
    }
}
