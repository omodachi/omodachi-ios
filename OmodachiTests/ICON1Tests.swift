import CoreText
import SwiftUI
import XCTest
@testable import Omodachi

/// ICON-1. Real application icons, and the two bar glyphs Leo said were wrong.
///
/// Every host constant here was read off `omarchy` (Omarchy `4.0.0.alpha`),
/// verbatim:
///
/// * Herdr's bar icon —
///   `~/.config/omarchy/plugins/jankeesvw.herdr/Panel.qml:54`
///   `readonly property string iconServer: ""`, drawn by the
///   `BarIconButton` at `:793-812` (`text: root.iconServer`);
/// * the agents widget's bar icon —
///   `/usr/share/omarchy/shell/plugins/agents/Panel.qml:342  text: "󱚣"`,
///   which is `U+F16A3`;
/// * both code points resolve on the host itself:
///   `fc-match "monospace:charset=f233"` and `…f16a3` → `JetBrainsMono Nerd
///   Font` (`/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf`);
/// * the icon names are the 47 `apps.*` rows' `icon` values from
///   `omodachi-host catalog`.
@MainActor
final class ICON1Tests: XCTestCase {

    private var hostFonts: HostFontSet {
        var set = HostFontSet()
        set.mono = "Helvetica"          // Nimbus Mono PS's stand-in: not a Nerd Font.
        set.monoHasNerdGlyphs = false
        return set
    }

    private func glyphID(_ text: String, family: String) -> CGGlyph {
        let font = CTFontCreateWithName(family as CFString, 16, nil)
        var units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
        return glyphs.first ?? 0
    }

    private func entry(_ json: String) throws -> CatalogEntryDTO {
        try JSONDecoder().decode(CatalogEntryDTO.self, from: Data(json.utf8))
    }

    // MARK: - §2 · the two bar glyphs

    /// The bar draws the host's own code point for ③ and ④, not a logo and not
    /// a glyph this app chose. These two literals are the whole of Leo's
    /// "herdr icon 和 Omarchy 里的不一致".
    func testTheBarUsesTheHostsOwnCodePointsForHerdrAndTheAgent() {
        XCTAssertEqual(Icon.herdr.nerd, "\u{f233}", "jankeesvw.herdr Panel.qml:54 iconServer")
        XCTAssertEqual(Icon.agent.nerd, "\u{f16a3}", "omarchy.agents Panel.qml:342")
    }

    /// And both are really drawable here, in the same Nerd Fonts 3.5.1 release
    /// the host falls back to. A pinned code point that renders as tofu would
    /// be a worse answer than the glyph it replaced.
    func testBothHostCodePointsDrawInTheFaceThisAppHas() {
        for icon in [Icon.herdr, Icon.agent] {
            guard case .text(let family) = HostGlyph.resolve(icon.nerd, iconFont: "", fonts: hostFonts),
                  let family else {
                return XCTFail("\(icon.symbol): the host's code point must resolve to a font")
            }
            XCTAssertNotEqual(glyphID(icon.nerd, family: family), 0, "\(icon.symbol) draws tofu")
        }
    }

    /// The vendor mark is now the *fallback*, which means it is only reached
    /// when no installed face carries the entry's code point. With the bundled
    /// face present that never happens — which is the point: the App and the
    /// host bar draw the same shape.
    func testTheVendorMarkIsOnlyReachedWhenNoFaceHasTheCodePoint() {
        for icon in [Icon.herdr, Icon.agent] {
            XCTAssertNotEqual(HostGlyph.resolve(icon.nerd, iconFont: "", fonts: hostFonts), .symbol,
                              "\(icon.symbol): the host glyph must win over the mark")
        }
        // A code point no face has — Omarchy's own `U+F835` hole (MENU-1 §0) —
        // is what the mark exists for.
        XCTAssertEqual(HostGlyph.resolve("\u{f835}", iconFont: "", fonts: hostFonts), .symbol)
    }

    /// Both marks are still in the bundle, because a fallback that is not there
    /// is not a fallback. AGENT-2's provenance file stays authoritative.
    func testTheDemotedMarksAreStillShipped() {
        for mark in BrandMark.allCases {
            XCTAssertNotNil(UIImage(named: mark.rawValue, in: .main, compatibleWith: nil))
        }
        XCTAssertEqual(BrandMark.provider("codex"), .codex)
        XCTAssertEqual(BrandMark.herdr.rawValue, "brand-herdr")
    }

    // MARK: - §1 · what kind of thing the host put in `icon`

    /// The same four answers core gives (`omodachi_core/icons.py`
    /// `classify_icon`), asserted on the values the host really publishes.
    func testTheFourShapesAHostPublishes() {
        XCTAssertEqual(HostIconKind.classify(nil), HostIconKind.none)
        XCTAssertEqual(HostIconKind.classify(""), HostIconKind.none)
        XCTAssertEqual(HostIconKind.classify("\u{f003b}"), .glyph)       // Apps
        XCTAssertEqual(HostIconKind.classify("\u{f0249}"), .glyph)       // Install
        XCTAssertEqual(HostIconKind.classify("\u{2713}"), .glyph)        // style.font's tick
        XCTAssertEqual(HostIconKind.classify("\u{1f7e2}"), .glyph)       // update.channel
        XCTAssertEqual(HostIconKind.classify("\u{e800}", iconFont: "omarchy"), .glyph)
        XCTAssertEqual(HostIconKind.classify("org.gnome.Nautilus"), .xdg)
        XCTAssertEqual(HostIconKind.classify("google-chrome"), .xdg)
        XCTAssertEqual(HostIconKind.classify("x"), .xdg, "apps.X publishes a one-letter name")
        XCTAssertEqual(HostIconKind.classify("/opt/vendor/logo.png"), .path)
    }

    /// A value this classifier calls a name is a value `HostGlyph` refuses to
    /// draw, and the other way round. If the two ever disagreed a row would be
    /// neither drawn nor fetched — an empty box, which is the bug UX-1 item 8
    /// and MENU-1 both existed to remove.
    func testTheClassifierAndTheGlyphResolverAgreeRowForRow() {
        for name in ["org.gnome.Nautilus", "google-chrome", "docker", "x", "audio-input-microphone"] {
            XCTAssertEqual(HostIconKind.classify(name), .xdg)
            XCTAssertEqual(HostGlyph.resolve(name, iconFont: "", fonts: hostFonts), .symbol, name)
        }
        for glyph in ["\u{f003b}", "\u{f0249}", "\u{f233}"] {
            XCTAssertEqual(HostIconKind.classify(glyph), .glyph)
            XCTAssertNotEqual(HostGlyph.resolve(glyph, iconFont: "", fonts: hostFonts), .symbol, glyph)
        }
    }

    /// The host's own `icon_kind` is taken when it is there…
    func testTheCatalogRowTakesTheHostsOwnClassification() throws {
        let row = try entry(#"{"id":"apps.x","parent_id":"apps","icon":"x","kind":"app","icon_kind":"xdg"}"#)
        XCTAssertEqual(row.iconKind, .xdg)
        XCTAssertEqual(row.icon, "x", "`icon` is published untouched")
    }

    /// …and a host that predates ICON-1 is classified here instead, so the
    /// Apps submenu is not blank until the host is updated.
    func testAHostThatPublishesNoKindIsClassifiedByTheClient() throws {
        let named = try entry(#"{"id":"apps.files","parent_id":"apps","icon":"org.gnome.Nautilus","kind":"app"}"#)
        XCTAssertEqual(named.iconKind, .xdg)
        let drawn = try entry(#"{"id":"apps","parent_id":"root","icon":"󰀻","kind":"menu"}"#)
        XCTAssertEqual(drawn.iconKind, .glyph)
        let empty = try entry(#"{"id":"omodachi","parent_id":"root","icon":"","kind":"menu"}"#)
        XCTAssertEqual(empty.iconKind, HostIconKind.none)
    }

    // MARK: - §1 · what a row asks for

    /// A row whose icon is a name asks the host for the picture behind it.
    func testARowWithANameCarriesThatNameToTheIconRoute() throws {
        for name in ["org.gnome.Nautilus", "google-chrome", "docker", "x", "com.omodachi.host"] {
            let built = HostMenu.build(from: [try entry(
                #"{"id":"apps.\#(name)","parent_id":"apps","icon":"\#(name)","kind":"app","icon_kind":"xdg"}"#)])
            XCTAssertEqual(built.first?.icon, .icon(name))
        }
    }

    /// An absolute `Icon=` path is a name too, as far as this client is
    /// concerned: core decides whether it will serve it.
    func testAnAbsolutePathIsAskedForLikeAnyOtherName() throws {
        let row = try entry(
            #"{"id":"apps.vendor","parent_id":"apps","icon":"/opt/vendor/logo.png","kind":"app","icon_kind":"path"}"#)
        XCTAssertEqual(HostMenu.fallback(for: row), .icon("/opt/vendor/logo.png"))
    }

    /// A row the host gave a real code point never becomes a network request.
    func testARowWithACodePointIsNeverFetched() throws {
        let row = try entry(#"{"id":"apps","parent_id":"root","icon":"󰀻","kind":"menu","icon_kind":"glyph"}"#)
        XCTAssertEqual(HostMenu.fallback(for: row), .symbol("circle"))
    }

    /// And our own row is still ours (MENU-1 §3).
    func testTheOmodachiRowIsUnaffected() throws {
        let row = try entry(#"{"id":"omodachi","parent_id":"root","icon":"","kind":"menu"}"#)
        XCTAssertEqual(HostMenu.fallback(for: row), .mark)
    }

    // MARK: - §1 · the size that is asked for

    /// Study 01's 36pt glyph slot, at the two scales a real device has — the
    /// spec's own 72 and 108.
    func testTheRequestedSizeIsPhysicalPixelsForTheThirtySixPointSlot() {
        XCTAssertEqual(HostIconStore.pixels(36, 2), 72)
        XCTAssertEqual(HostIconStore.pixels(36, 3), 108)
    }

    /// The whole menu shares one representation per scale. A row draws its
    /// icon at the glyph step (14–16pt) inside the 36 box — the host's own
    /// proportion, `Menu.qml:1244-1256` — and the bar draws one at 22, and
    /// neither asks the host for a second picture of the same icon.
    func testEverySlotSmallerThanTheStudysReusesTheSameRepresentation() {
        XCTAssertEqual(HostIconStore.pixels(16, 2), 72, "a row's glyph step")
        XCTAssertEqual(HostIconStore.pixels(22, 2), 72, "the bar's 22pt glyph")
        XCTAssertEqual(HostIconStore.pixels(22, 3), 108)
    }

    /// Core answers `400` outside 8…512, so the client never sends one.
    func testTheRequestedSizeIsClampedToWhatTheHostWillAnswer() {
        XCTAssertEqual(HostIconStore.pixels(4096, 3), 512)
        XCTAssertEqual(HostIconStore.pixels(36, 0), 36, "a scale below 1 is not a smaller icon")
    }

    // MARK: - §1 · the disk cache

    private func cacheDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("icon1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAStoredIconComesBackWithItsValidator() async throws {
        let cache = HostIconCache(directory: try cacheDirectory())
        let request = HostIconRequest(hostID: "host-a", name: "org.gnome.Nautilus", pixels: 72)
        let png = try XCTUnwrap(UIImage(systemName: "star.fill")?.pngData())
        await cache.store(png, etag: "abc123", for: request)
        let digest = await cache.digest(for: request)
        XCTAssertEqual(digest, "abc123")
        let image = await cache.image(for: request)
        XCTAssertNotNil(image)
    }

    /// A host that changed its icon theme publishes a different ETag, and the
    /// old file must not survive to be served in its place.
    func testANewValidatorReplacesTheFileRatherThanJoiningIt() async throws {
        let directory = try cacheDirectory()
        let cache = HostIconCache(directory: directory)
        let request = HostIconRequest(hostID: "host-a", name: "kitty", pixels: 72)
        let png = try XCTUnwrap(UIImage(systemName: "star.fill")?.pngData())
        await cache.store(png, etag: "one", for: request)
        await cache.store(png, etag: "two", for: request)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1, "one representation per request: \(files)")
        let digest = await cache.digest(for: request)
        XCTAssertEqual(digest, "two")
    }

    /// Two hosts, one name: the icon theme is a property of the machine, so
    /// the same name is a different picture and must be a different file.
    func testTwoHostsDoNotShareOneIconFile() async throws {
        let directory = try cacheDirectory()
        let cache = HostIconCache(directory: directory)
        let png = try XCTUnwrap(UIImage(systemName: "star.fill")?.pngData())
        await cache.store(png, etag: "one", for: .init(hostID: "host-a", name: "kitty", pixels: 72))
        await cache.store(png, etag: "one", for: .init(hostID: "host-b", name: "kitty", pixels: 72))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    /// @2x and @3x are two representations of one icon and must not overwrite
    /// each other (core gives them different ETags for the same reason).
    func testTwoSizesDoNotShareOneIconFile() async throws {
        let directory = try cacheDirectory()
        let cache = HostIconCache(directory: directory)
        let png = try XCTUnwrap(UIImage(systemName: "star.fill")?.pngData())
        await cache.store(png, etag: "d-png72", for: .init(hostID: "a", name: "kitty", pixels: 72))
        await cache.store(png, etag: "d-png108", for: .init(hostID: "a", name: "kitty", pixels: 108))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    /// A validator with a path separator or a quote in it never becomes a file
    /// name — the ETag comes off the wire.
    func testAHostileValidatorIsNotWrittenToDisk() async throws {
        let directory = try cacheDirectory()
        let cache = HostIconCache(directory: directory)
        let png = try XCTUnwrap(UIImage(systemName: "star.fill")?.pngData())
        for etag in ["../../escape", "a/b", "", String(repeating: "x", count: 200)] {
            await cache.store(png, etag: etag, for: .init(hostID: "a", name: "kitty", pixels: 72))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 0)
    }

    // MARK: - §1 · the bar's focused item

    /// The host publishes the focused window's own `Icon=`, and the slot draws
    /// the picture behind it.
    func testTheFocusedWindowCarriesTheIconTheHostResolved() throws {
        let focus = try JSONDecoder().decode(HostFocusDTO.self, from: Data(#"""
        {"app_id":"org.gnome.Nautilus","app_name":"Files","target_token":"t",
         "icon":"org.gnome.Nautilus","icon_kind":"xdg"}
        """#.utf8))
        let bar = try XCTUnwrap(focus.barFocus)
        XCTAssertEqual(bar.name, "Files")
        XCTAssertEqual(bar.fallback, .icon("org.gnome.Nautilus"))
    }

    /// A window whose `app_id` matched no desktop entry draws the generic
    /// application glyph rather than nothing.
    func testAFocusedWindowWithNoIconDrawsTheGenericGlyph() throws {
        let focus = try JSONDecoder().decode(HostFocusDTO.self, from: Data(
            #"{"app_id":"ghost","app_name":"Ghost","icon":"","icon_kind":"none"}"#.utf8))
        XCTAssertEqual(try XCTUnwrap(focus.barFocus).fallback, .app)
    }

    /// Nothing focused is not an empty icon, it is no slot at all.
    func testNothingFocusedIsNoFocusItem() throws {
        let focus = try JSONDecoder().decode(HostFocusDTO.self, from: Data(#"{"app_id":null}"#.utf8))
        XCTAssertNil(focus.barFocus)
    }

    /// A host that predates ICON-1 still gets a focus item, classified here.
    func testAFocusedWindowFromAnOlderHostIsClassifiedByTheClient() throws {
        let focus = try JSONDecoder().decode(HostFocusDTO.self, from: Data(
            #"{"app_id":"Alacritty","app_name":"Alacritty"}"#.utf8))
        XCTAssertEqual(try XCTUnwrap(focus.barFocus).fallback, .app)
    }
}

/// `GET /v1/icons/{name}` on the wire: the URL that is built, the validator
/// that is sent, and what a miss becomes.
@MainActor
final class ICON1IconRouteTests: XCTestCase {

    private func client() throws -> CompanionHostClient {
        IconURLProtocol.reset()
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [IconURLProtocol.self]
        return CompanionHostClient(
            configuration: try CompanionHostConfiguration(endpoint: URL(string: "https://icons.invalid:8443")!),
            credentials: FixtureCredential(), pinnedFingerprint: nil,
            session: URLSession(configuration: options))
    }

    func testTheNameAndTheSizeAreTheWholeRequest() async throws {
        let client = try client()
        try await client.connect()
        let png = try XCTUnwrap(UIImage(systemName: "star.fill")?.pngData())
        IconURLProtocol.answer = (200, png, ["ETag": "\"deadbeef\""])
        let answer = try await client.fetchIcon(name: "org.gnome.Nautilus", pixels: 72, knownDigest: nil)
        XCTAssertEqual(answer?.etag, "deadbeef", "the quotes are not part of the validator")
        let request = try XCTUnwrap(IconURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/v1/icons/org.gnome.Nautilus")
        XCTAssertEqual(request.url?.query, "size=72")
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
    }

    /// An absolute path is percent-encoded rather than rejected: core owns
    /// which names it will answer for.
    func testAnAbsolutePathIsEncodedIntoOnePathComponent() async throws {
        let client = try client()
        try await client.connect()
        IconURLProtocol.answer = (404, Data(#"{"error":{"code":"icon_not_found"}}"#.utf8), [:])
        _ = try? await client.fetchIcon(name: "/opt/vendor/logo.png", pixels: 72, knownDigest: nil)
        let request = try XCTUnwrap(IconURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString.contains("%2Fopt%2Fvendor%2Flogo.png"), true,
                       "a path must not become extra path components: \(request.url?.absoluteString ?? "")")
    }

    func testAKnownValidatorIsSentAndAThreeOhFourIsNoBytes() async throws {
        let client = try client()
        try await client.connect()
        IconURLProtocol.answer = (304, Data(), ["ETag": "\"deadbeef\""])
        let answer = try await client.fetchIcon(name: "kitty", pixels: 108, knownDigest: "deadbeef")
        XCTAssertNil(answer, "304 means what the caller holds is current")
        let request = try XCTUnwrap(IconURLProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"deadbeef\"")
        XCTAssertEqual(request.url?.query, "size=108")
    }

    /// The miss is the one error the client acts on rather than reports: the
    /// row keeps the generic glyph and the name is never asked for again.
    func testAMissIsReportedAsTheCodeTheStoreRemembers() async throws {
        let client = try client()
        try await client.connect()
        IconURLProtocol.answer = (404, Data(#"{"error":{"code":"icon_not_found","message":"no"}}"#.utf8), [:])
        do {
            _ = try await client.fetchIcon(name: "nothing-here", pixels: 72, knownDigest: nil)
            XCTFail("a miss must not look like bytes")
        } catch let error as CompanionHostError {
            guard case .unavailable(let code, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, HostIconStore.missCode)
        }
    }

    /// A size outside what core answers for never leaves the device.
    func testTheSizeIsClampedBeforeItIsSent() async throws {
        let client = try client()
        try await client.connect()
        IconURLProtocol.answer = (200, Data([0x89]), ["ETag": "\"x\""])
        _ = try await client.fetchIcon(name: "kitty", pixels: 99_999, knownDigest: nil)
        XCTAssertEqual(IconURLProtocol.lastRequest?.url?.query, "size=512")
    }
}

/// A stub that can answer with bytes and headers, which the shared JSON one
/// cannot.
final class IconURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answer: (status: Int, body: Data, headers: [String: String]) = (200, Data(), [:])
    nonisolated(unsafe) static var lastRequest: URLRequest?
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        answer = (200, Data(), [:])
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "icons.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.lastRequest = request
        let (status, body, headers) = Self.answer
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The store itself, driven the way a row drives it: ask, get nothing, and get
/// the picture on the next pass.
@MainActor
final class ICON1StoreTests: XCTestCase {

    private func store() throws -> HostIconStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("icon1-store-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = HostIconStore(cache: HostIconCache(directory: directory))
        store.adopt(hostID: "host-a")
        return store
    }

    private func png() throws -> Data {
        let data = UIImage(systemName: "star.fill")?.pngData()
        return try XCTUnwrap(data)
    }

    func testTheFirstAskGetsNothingAndTheSecondGetsThePicture() async throws {
        let store = try store()
        let bytes = try png()
        store.fetch = { _, _, _ in HostIconBytes(data: bytes, etag: "abc") }
        XCTAssertNil(store.image(named: "org.gnome.Nautilus", points: 36, scale: 2),
                     "the first pass draws the generic glyph and asks")
        try await waitUntil { store.image(named: "org.gnome.Nautilus", points: 36, scale: 2) != nil }
    }

    /// The name and the size that actually go on the wire are the host's name
    /// and Study 01's slot.
    func testTheStoreAsksForTheNameAtTheStudysSlot() async throws {
        let store = try store()
        let bytes = try png()
        let asked = Asked()
        store.fetch = { name, pixels, digest in
            await asked.record(name: name, pixels: pixels, digest: digest)
            return HostIconBytes(data: bytes, etag: "abc")
        }
        _ = store.image(named: "google-chrome", points: 16, scale: 3)
        try await waitUntil { await asked.count() == 1 }
        let recorded = await asked.first()
        let call = try XCTUnwrap(recorded)
        XCTAssertEqual(call.name, "google-chrome")
        XCTAssertEqual(call.pixels, 108)
        XCTAssertNil(call.digest, "a cold cache holds no validator")
    }

    /// A host with no picture is asked once. A menu that scrolls must not turn
    /// one `404` into a request per frame.
    func testAMissIsAskedAboutExactlyOnce() async throws {
        let store = try store()
        let asked = Asked()
        store.fetch = { name, pixels, digest in
            await asked.record(name: name, pixels: pixels, digest: digest)
            throw CompanionHostError.unavailable(code: "icon_not_found", message: "no")
        }
        _ = store.image(named: "nothing-here", points: 36, scale: 2)
        try await waitUntil { await asked.count() == 1 }
        for _ in 0..<5 { _ = store.image(named: "nothing-here", points: 36, scale: 2) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let count = await asked.count()
        XCTAssertEqual(count, 1, "a miss is permanent for the session")
    }

    /// A store with no host is a store that asks nobody — the demo host and
    /// the previews must not reach for a network.
    func testAStoreWithNoHostNeverAsks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("icon1-store-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = HostIconStore(cache: HostIconCache(directory: directory))
        let asked = Asked()
        store.fetch = { name, pixels, digest in
            await asked.record(name: name, pixels: pixels, digest: digest)
            return nil
        }
        XCTAssertNil(store.image(named: "kitty", points: 36, scale: 2))
        try await Task.sleep(nanoseconds: 200_000_000)
        let count = await asked.count()
        XCTAssertEqual(count, 0)
    }

    private func waitUntil(_ condition: @escaping () async -> Bool,
                           seconds: Double = 5, file: StaticString = #filePath,
                           line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}

private actor Asked {
    struct Call { let name: String; let pixels: Int; let digest: String? }
    var calls: [Call] = []
    func record(name: String, pixels: Int, digest: String?) {
        calls.append(Call(name: name, pixels: pixels, digest: digest))
    }
    func count() -> Int { calls.count }
    func first() -> Call? { calls.first }
}
