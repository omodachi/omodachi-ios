import XCTest

/// LINKS-1: a link in an agent's answer is the app's to open. The fixture
/// (`--links-fixture`) is one reply with a markdown file link, a path in
/// inline code and a web address, plus a tool row's file; the UI run has no
/// computer behind it, so a file link must come back as the app's own
/// sentence ("not connected") — proof the tap reached the app rather than
/// iOS, which used to try to open `/home/…` as a file on the phone.
@MainActor
final class LINKS1PanelTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 180
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--links-fixture"]
            app.launch()
            XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 10))
            app.buttons["open-agent"].tap()
        }
    }

    override func tearDown() async throws {
        await MainActor.run { app?.terminate() }
        try await super.tearDown()
    }

    private var notice: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "link-notice").firstMatch
    }

    private func assertTheAppAnswered(_ name: String) {
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "\(name): the tap never reached the app")
        app.descendants(matching: .any).matching(identifier: "link-notice-dismiss").firstMatch.tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
    }

    func testAMarkdownFileLinkInAReplyOpensThroughTheApp() {
        let link = app.links["report.md"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()
        assertTheAppAnswered("markdown link")
        attach("links1-markdown-link")
    }

    func testAPathInInlineCodeOpensThroughTheApp() {
        let link = app.links["/home/user/l1test/report.md:12"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()
        assertTheAppAnswered("inline code path")
    }

    /// The way a finger (or `axe`) lands: on the middle of the link's own
    /// frame, a real touch rather than the element's accessibility action.
    /// (A link that wraps onto two lines has a frame around both, and its
    /// middle can be another word; these two are one line each.)
    func testATouchOnTheMiddleOfALinkReachesTheApp() {
        let link = app.links["report.md"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertTheAppAnswered("touch on report.md")
        let web = app.links["https://example.com/docs"]
        XCTAssertTrue(web.waitForExistence(timeout: 5))
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // A public page opens in the Safari view over the app, so the
        // transcript stops being the thing on screen.
        XCTAssertTrue(app.textFields["agent-chat-composer"].waitForNonExistence(timeout: 10) || !web.isHittable,
                      "the web address did not open")
        attach("links1-web-safari-view")
    }

    /// The host's own reply: links inside list items, `~/` paths in prose.
    func testLinksInListItemsReachTheApp() {
        // Real touches on the middle of one-line links: the case that did
        // nothing while the prose was selectable (iOS 27 let a nested
        // selectable Text keep the touch).
        for name in ["notes.md", "~/l1test/run.sh", "~/.ssh/config"] {
            let link = app.links[name]
            XCTAssertTrue(link.waitForExistence(timeout: 15), name)
            link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            assertTheAppAnswered(name)
        }
        // A link wrapped onto two lines has one frame around both; its
        // middle can be another word, so it is tapped as the element.
        let picture = app.links["/home/user/l1test/chart.png"]
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        picture.tap()
        assertTheAppAnswered("picture path")
        attach("links1-list")
    }

    func testAToolRowsFileOpensThroughTheApp() {
        let path = app.buttons["agent-tool-path-links-change-0"]
        XCTAssertTrue(path.waitForExistence(timeout: 15))
        path.tap()
        assertTheAppAnswered("tool row path")
    }

    func testTheReplyIsDrawnAsBlocks() {
        XCTAssertTrue(app.staticTexts["Done"].waitForExistence(timeout: 15), "the heading is its own text, not ## Done")
        XCTAssertFalse(app.staticTexts["## Done"].exists)
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
