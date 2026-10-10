import XCTest
@testable import Omodachi

/// LINKS-1: links in agent output open the right way — web addresses on the
/// phone (the computer's own pages at the road this phone uses), files on the
/// computer through Remote. Core's own fixtures (`links-detect.json`,
/// `host-open*.json`, `agent-chat-snapshot-links.json`) and a fake host.
private final class FakeHostOpener: HostOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [HostOpenRequest] = []
    var refusal: HostOpenError?
    var requests: [HostOpenRequest] { lock.withLock { log } }
    func hostOpen(_ request: HostOpenRequest) async throws -> HostOpenResult {
        lock.withLock { log.append(request) }
        if let refusal { throw refusal }
        return HostOpenResult(opened: request.check != true, kind: "file", name: "report.md", line: nil,
                              where: request.check == true ? nil : "remote", at_line: false)
    }
}

@MainActor final class LINKS1Tests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json",
                                                             subdirectory: "CoreFixtures"))
        return try Data(contentsOf: url)
    }

    private struct DetectFixture: Decodable {
        struct Link: Decodable { let kind: String; let text: String }
        struct Case: Decodable { let text: String; let links: [Link] }
        struct Local: Decodable { let url: String; let host_local: Bool }
        struct Road: Decodable { let host: String; let kind: String }
        struct Rewrite: Decodable { let url: String; let road: Road; let expected: String }
        let known_extensions: [String]
        let mirror: [Case]
        let prose: [Case]
        let host_local: [Local]
        let rewrite: [Rewrite]
    }

    private func detectFixture() throws -> DetectFixture {
        try JSONDecoder().decode(DetectFixture.self, from: fixture("links-detect"))
    }

    private func roads() throws -> [HostRoad] {
        try JSONDecoder().decode(HostRoadsDTO.self, from: fixture("host-roads")).roads
    }

    // MARK: - Detection: the same links Odomo finds

    func testMirrorAndProseVectorsMatchCore() throws {
        let vectors = try detectFixture()
        for (cases, bare) in [(vectors.mirror, true), (vectors.prose, false)] {
            for item in cases {
                let found = LinkDetector.detect(in: item.text, bareNames: bare)
                XCTAssertEqual(found.map(\.text), item.links.map(\.text), "\(bare ? "mirror" : "prose"): \(item.text)")
                XCTAssertEqual(found.map(\.kind.rawValue), item.links.map(\.kind), item.text)
            }
        }
    }

    func testKnownExtensionsAreCoresList() throws {
        XCTAssertEqual(LinkDetector.extensions, Set(try detectFixture().known_extensions))
    }

    func testTheLinkUnderAColumnIsFound() {
        let text = "Wrote /home/user/a.md:12 and README.md"
        XCTAssertEqual(LinkDetector.link(in: text, at: 8)?.text, "/home/user/a.md:12")
        XCTAssertEqual(LinkDetector.link(in: text, at: 33)?.text, "README.md")
        XCTAssertNil(LinkDetector.link(in: text, at: 2))
        XCTAssertNil(LinkDetector.link(in: text, at: 999))
    }

    // MARK: - The computer's own pages

    func testHostLocalVectorsMatchCore() throws {
        let local = HostLocalLinks(current: HostRoad(host: "192.168.1.10", port: 8099, kind: .lan), known: try roads())
        for item in try detectFixture().host_local {
            let url = try XCTUnwrap(URL(string: item.url))
            XCTAssertEqual(local.isHostLocal(url), item.host_local, item.url)
        }
    }

    func testRewriteVectorsMatchCoreIncludingPlainHTTPToAnAddressNotTsNet() throws {
        let known = try roads()
        for item in try detectFixture().rewrite {
            let kind = RoadKind(rawValue: item.road.kind) ?? .lan
            let local = HostLocalLinks(current: HostRoad(host: item.road.host, port: 8099, kind: kind), known: known)
            let url = try XCTUnwrap(URL(string: item.url))
            XCTAssertEqual((local.rewrite(url) ?? url).absoluteString, item.expected, item.url)
        }
    }

    func testThePairedNameCountsAsTheComputer() throws {
        let local = HostLocalLinks(current: HostRoad(host: "192.168.1.10", port: 8099, kind: .lan),
                                   known: [], hostName: "studio")
        XCTAssertTrue(local.isHostLocal(try XCTUnwrap(URL(string: "http://studio:3000/"))))
        XCTAssertNil(HostLocalLinks().rewrite(try XCTUnwrap(URL(string: "http://localhost:3000/"))),
                     "no road, nothing to rewrite to")
    }

    // MARK: - Targets and how they ride through openURL

    func testTargetsAreClassified() throws {
        XCTAssertEqual(LinkTarget.classify("https://example.com/x"), .web(try XCTUnwrap(URL(string: "https://example.com/x"))))
        XCTAssertEqual(LinkTarget.classify("/home/u/x.md:12"), .path("/home/u/x.md:12"))
        XCTAssertEqual(LinkTarget.classify("~/x.png"), .path("~/x.png"))
        XCTAssertEqual(LinkTarget.classify("out.csv"), .path("out.csv"))
        XCTAssertEqual(LinkTarget.classify("README.md:3"), .path("README.md:3"))
        XCTAssertEqual(LinkTarget.classify("file:///home/u/x.md"), .path("file:///home/u/x.md"))
        if case .app? = LinkTarget.classify("https://omodachi.app/open/remote?host=abc") {} else { XCTFail("app link") }
        if case .other? = LinkTarget.classify("mailto:alex@example.com") {} else { XCTFail("mailto") }
        XCTAssertNil(LinkTarget.classify("#section"))
        XCTAssertNil(LinkTarget.classify("two words"))
    }

    func testAPathRidesAsTheAppsOwnSchemeNeverAsAFileURL() throws {
        let url = try XCTUnwrap(LinkCarrier.url(for: .path("/home/u/a b.md:12")))
        XCTAssertEqual(url.scheme, LinkCarrier.scheme)
        XCTAssertEqual(LinkCarrier.target(from: url), .path("/home/u/a b.md:12"))
        let web = try XCTUnwrap(URL(string: "http://localhost:8000/"))
        XCTAssertEqual(LinkCarrier.target(from: web), .web(web))
    }

    // MARK: - Markdown

    func testBlocksAreBlocks() {
        let blocks = AgentMarkdown.parse("""
        ## Status

        Line one
        line two

        - first
        - second with `code`

        3. three
        4. four

        > quoted

        ```sh
        echo one
          echo two
        ```

        | a | b |
        |---|---|

        ---
        """)
        XCTAssertEqual(blocks.count, 8)
        XCTAssertEqual(blocks[0], .heading(level: 2, [.text("Status")]))
        XCTAssertEqual(blocks[1], .paragraph([.text("Line one"), .lineBreak, .text("line two")]))
        guard case .list(nil, let bullets) = blocks[2] else { return XCTFail("bullets") }
        XCTAssertEqual(bullets.count, 2)
        XCTAssertEqual(bullets[1], [.paragraph([.text("second with "), .code("code", target: nil)])])
        guard case .list(3, let numbered) = blocks[3] else { return XCTFail("numbered") }
        XCTAssertEqual(numbered.count, 2)
        XCTAssertEqual(blocks[4], .quote([.paragraph([.text("quoted")])]))
        XCTAssertEqual(blocks[5], .code(language: "sh", text: "echo one\n  echo two"))
        XCTAssertEqual(blocks[6], .table("| a | b |\n|---|---|"))
        XCTAssertEqual(blocks[7], .rule)
    }

    func testAnUnfinishedFenceWhileStreamingIsStillCode() {
        XCTAssertEqual(AgentMarkdown.parse("Run:\n```\nmake test"),
                       [.paragraph([.text("Run:")]), .code(language: nil, text: "make test")])
    }

    func testInlineMarks() {
        XCTAssertEqual(AgentMarkdown.inlines("a **bold** and *it* and _it_ in snake_case_name"),
                       [.text("a "), .strong([.text("bold")]), .text(" and "), .emphasis([.text("it")]),
                        .text(" and "), .emphasis([.text("it")]), .text(" in snake_case_name")])
        XCTAssertEqual(AgentMarkdown.inlines("2 * 3 * 4"), [.text("2 * 3 * 4")])
        XCTAssertEqual(AgentMarkdown.inlines("\\*not\\*"), [.text("*not*")])
    }

    func testPicturesAreWordsAndAFileLinkNeverAFetch() {
        XCTAssertEqual(AgentMarkdown.inlines("![Bar chart](/home/u/chart.png)"),
                       [.image(alt: "Bar chart", target: "/home/u/chart.png")])
        XCTAssertEqual(AgentMarkdown.inlines("[chart.py](/home/u/chart.py \"title\")"),
                       [.link([.text("chart.py")], target: "/home/u/chart.py")])
        XCTAssertEqual(AgentMarkdown.inlines("[x](<a b.md>)"), [.link([.text("x")], target: "a b.md")])
    }

    func testBareAddressesAndPathsInProseAndWholeCodeSpansBecomeLinks() {
        XCTAssertEqual(AgentMarkdown.inlines("Preview at http://localhost:8000/ (served from `~/l1test`)."),
                       [.text("Preview at "), .link([.text("http://localhost:8000/")], target: "http://localhost:8000/"),
                        .text(" (served from "), .code("~/l1test", target: "~/l1test"), .text(").")])
        XCTAssertEqual(AgentMarkdown.inlines("see `/a/b.py:3` and `make test`"),
                       [.text("see "), .code("/a/b.py:3", target: "/a/b.py:3"), .text(" and "),
                        .code("make test", target: nil)])
        // A bare name in prose is just a word.
        XCTAssertEqual(AgentMarkdown.inlines("Download out.csv"), [.text("Download out.csv")])
    }

    // MARK: - Wire

    func testToolRowsCarryTheirPathsAndAPictureIsAToolRow() throws {
        let snapshot = try JSONDecoder().decode(AgentChatSnapshotWire.self, from: fixture("agent-chat-snapshot-links")).value()
        let tools = snapshot.rows.compactMap { row -> AgentChatTool? in if case .tool(let tool) = row { tool } else { nil } }
        XCTAssertEqual(tools.map(\.paths), [["/home/user/l1test/chart.py"], ["/home/user/l1test/chart.png"]])
        XCTAssertEqual(tools.last?.name, "Viewed image")
        guard case .message(let reply)? = snapshot.rows.last else { return XCTFail("reply") }
        let blocks = AgentMarkdown.parse(reply.text)
        XCTAssertEqual(blocks.first, .heading(level: 1 + 1, [.text("Done")]))
        XCTAssertEqual(blocks.last, .code(language: "sh", text: "python3 chart.py"))
        // A tool row from before LINKS-1 (no `paths`) still decodes, with none.
        let old = Data(#"{"kind":"tool","id":"t","turnID":"u","name":"ls","status":"completed","detail":""}"#.utf8)
        guard case .tool(let plain) = try JSONDecoder().decode(AgentChatSnapshotWire.Row.self, from: old).value()
        else { return XCTFail("tool") }
        XCTAssertNil(plain.paths)
    }

    func testHostOpenAnswersDecode() throws {
        let opened = try JSONDecoder().decode(HostOpenResult.self, from: fixture("host-open"))
        XCTAssertEqual(opened, HostOpenResult(opened: true, kind: "file", name: "report.md", line: 12, where: "remote", at_line: true))
        let check = try JSONDecoder().decode(HostOpenResult.self, from: fixture("host-open-check"))
        XCTAssertFalse(check.opened)
        XCTAssertNil(check.where)
        XCTAssertEqual(try JSONDecoder().decode(HostOpenResult.self, from: fixture("host-open-url")).kind, "url")
    }

    func testEveryRefusalIsASentenceInBothLanguages() throws {
        struct Body: Decodable { struct E: Decodable { let code: String }; let error: E }
        for name in ["http-error-open-not-mentioned", "http-error-open-denied", "http-error-open-executable"] {
            let code = try JSONDecoder().decode(Body.self, from: fixture(name)).error.code
            XCTAssertNotNil(ReasonText.shared(code), code)
            XCTAssertEqual(ReasonText.knownCodes[code], .host, code)
        }
        for code in ["open_not_mentioned", "open_outside_roots", "open_denied", "open_executable", "open_missing",
                     "open_source_gone", "open_type_refused", "open_url_refused", "open_rate_limited", "open_unavailable"] {
            let text = LinkOpener.message(HostOpenError(code: code, status: 403))
            XCTAssertFalse(text.contains(code), "\(code) is a sentence, not the code")
        }
    }

    // MARK: - Routing

    private func opener(_ fake: FakeHostOpener, session: Bool = false, extend: Bool = true,
                        reachable: Bool = true, events: Recorder) -> LinkOpener {
        let opener = LinkOpener()
        opener.hooks.client = { fake }
        opener.hooks.roads = {
            HostLocalLinks(current: HostRoad(host: "omarchy-fixture.tail0000.ts.net", port: 8099, kind: .tailnet),
                           known: [HostRoad(host: "100.64.0.35", port: 8099, kind: .tailnet)])
        }
        opener.hooks.presentWeb = { events.add("web \($0.absoluteString)") }
        opener.hooks.routeApp = { _ in events.add("app") }
        opener.hooks.hasRemoteSession = { session }
        opener.hooks.extendIsDefault = { extend }
        opener.hooks.startRemote = { events.add("start"); return true }
        opener.hooks.waitForRemote = { _ in events.add("wait"); return true }
        opener.hooks.showRemotePanel = { events.add("panel") }
        opener.hooks.showPicture = { events.add("picture") }
        opener.probe = { host, port in await events.addAsync("probe \(host):\(port)"); return reachable }
        return opener
    }

    @MainActor final class Recorder {
        private(set) var lines: [String] = []
        func add(_ line: String) { lines.append(line) }
        func addAsync(_ line: String) async { lines.append(line) }
    }

    private func settle(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testARefusedPathSaysWhyAndNeverStartsRemote() async {
        let fake = FakeHostOpener()
        fake.refusal = HostOpenError(code: "open_denied", status: 403)
        let events = Recorder()
        let links = opener(fake, events: events)
        links.open(.path("~/.ssh/config"), from: .agent(item: "item-1"))
        await settle { links.notice?.kind == .problem }
        XCTAssertEqual(links.notice?.text, Strings.reasonOpenDenied)
        XCTAssertEqual(fake.requests.map(\.check), [true], "only the check")
        XCTAssertEqual(fake.requests.first?.source, HostOpenSourceWire(kind: "agent", item: "item-1", pane: nil, session: nil))
        XCTAssertEqual(events.lines, [])
    }

    func testWithRemoteRunningTheFileOpensAndThePictureComesBack() async {
        let fake = FakeHostOpener()
        let events = Recorder()
        let links = opener(fake, session: true, events: events)
        links.open(.path("/home/user/report.md:12"), from: .herdr(pane: "w1:p2", session: "l1test"))
        await settle { events.lines == ["picture"] }
        XCTAssertEqual(fake.requests.map(\.check), [true, nil])
        XCTAssertEqual(fake.requests.last?.path, "/home/user/report.md:12")
        XCTAssertEqual(fake.requests.last?.source, HostOpenSourceWire(kind: "herdr", item: nil, pane: "w1:p2", session: "l1test"))
        XCTAssertNil(links.notice)
    }

    func testWithoutRemoteExtendStartsFirstAndTheFileWaitsForItsScreen() async {
        let fake = FakeHostOpener()
        let events = Recorder()
        let links = opener(fake, events: events)
        links.open(.path("/home/user/a.md"), from: .agent(item: "i"))
        await settle { fake.requests.count == 2 }
        XCTAssertEqual(events.lines, ["start", "wait"])
        XCTAssertEqual(fake.requests.map(\.check), [true, nil])
    }

    func testTakeoverIsNeverStartedFromALinkAndNothingOpensUnseen() async {
        let fake = FakeHostOpener()
        let events = Recorder()
        let links = opener(fake, extend: false, events: events)
        links.open(.path("/home/user/a.md"), from: .agent(item: "i"))
        await settle { events.lines == ["panel"] }
        XCTAssertEqual(events.lines, ["panel"])
        XCTAssertEqual(fake.requests.map(\.check), [true], "checked, never opened on a screen nobody sees")
        XCTAssertEqual(links.notice?.text, Strings.linkStartRemoteFirst)
    }

    func testARemoteThatDoesNotComeUpOpensNothing() async {
        let fake = FakeHostOpener()
        let events = Recorder()
        let links = opener(fake, events: events)
        links.hooks.waitForRemote = { _ in events.add("wait"); return false }
        links.open(.path("/home/user/a.md"), from: .agent(item: "i"))
        await settle { events.lines.count == 3 }
        XCTAssertEqual(events.lines, ["start", "wait", "panel"])
        XCTAssertEqual(fake.requests.map(\.check), [true])
        XCTAssertEqual(links.notice?.text, Strings.linkStartRemoteFirst)
    }

    func testACoreWithoutTheRouteSaysUpdateTheComputer() {
        XCTAssertEqual(HostOpenError.answer(status: 404, code: nil).code, HostOpenError.unsupported)
        XCTAssertEqual(HostOpenError.answer(status: 405, code: "request_rejected").code, HostOpenError.unsupported)
        XCTAssertEqual(HostOpenError.answer(status: 404, code: "open_missing").code, "open_missing")
        XCTAssertEqual(HostOpenError.answer(status: 403, code: "open_denied").code, "open_denied")
        XCTAssertEqual(HostOpenError.answer(status: 503, code: nil).code, "open_unavailable")
        XCTAssertEqual(LinkOpener.message(HostOpenError(code: HostOpenError.unsupported, status: 404)),
                       Strings.reasonOpenUnsupported)
    }

    func testALinksLineGoesWithItsPanelButNotWhileWorking() async {
        let fake = FakeHostOpener()
        fake.refusal = HostOpenError(code: "open_missing", status: 404)
        let events = Recorder()
        let links = opener(fake, events: events)
        links.open(.path("/nope"), from: .agent(item: "i"))
        await settle { links.notice?.kind == .problem }
        links.panelChanged()
        XCTAssertNotNil(links.notice, "the opener's own move to a panel keeps its line")
        links.panelChanged(now: Date().addingTimeInterval(2))
        XCTAssertNil(links.notice)
    }

    func testAPublicPageOpensInTheAppAsIs() async {
        let events = Recorder()
        let links = opener(FakeHostOpener(), events: events)
        links.open(.web(URL(string: "https://example.com/a")!), from: .agent(item: "i"))
        await settle { !events.lines.isEmpty }
        XCTAssertEqual(events.lines, ["web https://example.com/a"])
    }

    func testTheComputersOwnPageIsTriedAtTheRoadThenOpened() async {
        let events = Recorder()
        let links = opener(FakeHostOpener(), events: events)
        links.open(.web(URL(string: "http://localhost:8000/x")!), from: .agent(item: "i"))
        await settle { events.lines.count == 2 }
        XCTAssertEqual(events.lines, ["probe 100.64.0.35:8000", "web http://100.64.0.35:8000/x"])
    }

    func testALoopbackOnlyServerIsSaidWarmlyAndOffersTheComputer() async {
        let fake = FakeHostOpener()
        let events = Recorder()
        let links = opener(fake, session: true, reachable: false, events: events)
        links.open(.web(URL(string: "http://127.0.0.1:5173/")!), from: .herdr(pane: "w1:p1", session: nil))
        await settle { links.notice?.kind == .problem }
        XCTAssertEqual(links.notice?.text, Strings.linkComputerOnly)
        let offer = try? XCTUnwrap(links.notice?.offer)
        XCTAssertEqual(offer?.url, "http://127.0.0.1:5173/", "the original, not the rewrite")
        if let offer { links.openOffer(offer) }
        await settle { fake.requests.count == 2 }
        XCTAssertEqual(fake.requests.map(\.url), ["http://127.0.0.1:5173/", "http://127.0.0.1:5173/"])
        XCTAssertEqual(fake.requests.map(\.path), [nil, nil])
    }

    func testSSHOpensWebAddressesOnlyAndAppLinksRouteInTheApp() async {
        let fake = FakeHostOpener()
        let events = Recorder()
        let links = opener(fake, events: events)
        links.open(.path("/etc/hosts"), from: .ssh)
        links.open(.app(URL(string: "omodachi://open/agent")!), from: .agent(item: "i"))
        await settle { !events.lines.isEmpty }
        XCTAssertEqual(events.lines, ["app"])
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testOneTapReachingTwiceOpensOnce() async {
        let events = Recorder()
        let links = opener(FakeHostOpener(), events: events)
        let url = URL(string: "https://example.com/")!
        links.open(.web(url), from: .ssh)
        links.open(.web(url), from: .ssh)
        await settle { !events.lines.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(events.lines.count, 1)
    }
}
