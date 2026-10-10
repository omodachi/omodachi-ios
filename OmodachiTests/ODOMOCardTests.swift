import XCTest
@testable import Omodachi

/// ODOMO-CARD: the Notifications card can be hidden per computer and brought
/// back from Settings; a link Odomo hands to the app (`from=odomo`) teaches
/// the app that Odomo is on this device for that computer, and the card stops
/// offering it. Ids and the flag only; an unknown host teaches nothing.
@MainActor final class ODOMOCardTests: XCTestCase {
    private let paired = String(repeating: "5", count: 32)
    private let stranger = String(repeating: "a", count: 32)

    private var records: [PairedHostRecord] {
        [PairedHostRecord(account: "https://127.0.0.1:59999", hostID: paired, hostName: "pair5-host", address: "https://127.0.0.1:59999")]
    }

    private func link(_ string: String) throws -> AppLink {
        try XCTUnwrap(AppLink.parse(try XCTUnwrap(URL(string: string))))
    }

    func testEveryOdomoLinkShapeCarriesTheFlag() throws {
        // What Odomo builds (core odomo/src/lib/applink.js): the two spellings,
        // every target, and "Get the app" (`/open/`).
        for url in ["https://omodachi.app/open/remote?host=\(paired)&from=odomo",
                    "omodachi://open/remote?host=\(paired)&from=odomo",
                    "https://omodachi.app/open/host?host=\(paired)&from=odomo",
                    "https://omodachi.app/open/agent?host=\(paired)&from=odomo",
                    "omodachi://open/herdr?host=\(paired)&session=work&pane=w2%3Ap3&from=odomo",
                    "https://omodachi.app/open/?host=\(paired)&from=odomo",
                    "omodachi://open/app?host=\(paired)&from=odomo",
                    "omodachi://open/app?host=\(paired)&from=ODOMO"] {
            let parsed = try link(url)
            XCTAssertTrue(parsed.fromOdomo, url)
            XCTAssertEqual(parsed.hostID, paired, url)
        }
        let herd = try link("omodachi://open/herdr?host=\(paired)&session=work&pane=w2%3Ap3&from=odomo")
        XCTAssertEqual(herd.session, "work")
        XCTAssertEqual(herd.pane, "w2:p3", "the flag does not disturb the place")
        XCTAssertEqual(try link("omodachi://open/app?host=\(paired)&from=odomo").target, .app)
        XCTAssertEqual(try link("https://omodachi.app/open/?host=\(paired)&from=odomo").target, .app)
        for url in ["omodachi://open/app?host=\(paired)",
                    "omodachi://open/app?host=\(paired)&from=safari",
                    "omodachi://open/app?host=\(paired)&from=",
                    "omodachi://open/app?host=\(paired)&odomo=1"] {
            XCTAssertFalse(try link(url).fromOdomo, url)
        }
    }

    func testOnlyAPairedHostFromOdomoIsLearnt() throws {
        let learn = { (url: String, onMac: Bool) in
            OdomoOffer.learnsHere(from: try self.link(url), records: self.records, onMac: onMac)
        }
        XCTAssertEqual(try learn("omodachi://open/app?host=\(paired)&from=odomo", false), paired)
        XCTAssertEqual(try learn("https://omodachi.app/open/remote?host=\(paired.uppercased())&from=odomo", false), paired,
                       "the id is read the way the router reads it")
        XCTAssertNil(try learn("omodachi://open/app?host=\(stranger)&from=odomo", false), "an unknown host is ignored")
        XCTAssertNil(try learn("omodachi://open/app?from=odomo", false), "no host, nothing to remember")
        XCTAssertNil(try learn("omodachi://open/app?host=not-a-host-id&from=odomo", false))
        XCTAssertNil(try learn("omodachi://open/app?host=\(paired)", false), "a link not from Odomo says nothing")
        XCTAssertNil(try learn("omodachi://open/app?host=\(paired)&from=odomo", true),
                     "on a Mac the link came from a desktop browser, where Odomo is not gated")
        // A notification tap is a link too, never from Odomo.
        XCTAssertNil(OdomoOffer.learnsHere(from: AppLink(target: .agent, hostID: paired), records: records, onMac: false))
    }

    func testTheCardTheSwitchAndHere() throws {
        let url = try XCTUnwrap(URL(string: "https://omarchy-fixture.tail0000.ts.net/odomo/"))
        let off = OdomoOffer.State.off(url: url, counted: true)
        XCTAssertTrue(OdomoOffer.showsCard(off, dismissed: false, here: false))
        XCTAssertFalse(OdomoOffer.showsCard(off, dismissed: false, here: true), "Odomo is on this device: no offer")
        XCTAssertFalse(OdomoOffer.showsCard(.noAddress, dismissed: false, here: true))
        XCTAssertFalse(OdomoOffer.showsCard(off, dismissed: true, here: false), "hidden")
        XCTAssertFalse(OdomoOffer.showsCard(.on(devices: 1, url: url), dismissed: false, here: false))
        XCTAssertTrue(OdomoOffer.switchIsOn(dismissed: false, here: false), "on by default")
        XCTAssertFalse(OdomoOffer.switchIsOn(dismissed: true, here: false), "off after Hide")
        XCTAssertFalse(OdomoOffer.switchIsOn(dismissed: false, here: true))
    }

    func testTheTwoMemoriesArePerComputerAndApart() throws {
        let name = "odomo-card-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let hidden = OdomoOfferMemory(defaults: defaults)
        let here = OdomoOfferMemory.here(defaults: defaults)
        XCTAssertEqual(hidden.key, "omodachi.odomo.notNow.v1", "a card put away before ODOMO-CARD stays put away")
        XCTAssertNotEqual(hidden.key, here.key)
        here.remember(paired)
        here.remember(paired)
        XCTAssertTrue(here.contains(paired))
        XCTAssertFalse(hidden.contains(paired))
        XCTAssertFalse(here.contains(stranger), "another computer is still offered")
        XCTAssertEqual(defaults.stringArray(forKey: OdomoOfferMemory.hereKey), [paired], "ids only")
        here.remember("")
        XCTAssertFalse(here.contains(""))
        for index in 0..<70 { here.remember("host-\(index)") }
        XCTAssertEqual(defaults.stringArray(forKey: OdomoOfferMemory.hereKey)?.count, 64)
        here.forget("host-69")
        XCTAssertFalse(here.contains("host-69"))
    }

    func testTheWordsSayWhereItWentAndWhatIsOnThisDevice() {
        let name = Strings.odomoName, device = DeviceWord.current
        let hidden = Strings.odomoCardHidden(Strings.panelSettings, Strings.panelNotifications)
        XCTAssertTrue(hidden.contains(Strings.panelSettings) && hidden.contains(Strings.panelNotifications),
                      "the way back names the place it is")
        XCTAssertTrue(Strings.odomoStateHere(name, device).contains(name))
        XCTAssertTrue(Strings.odomoStateHere(name, device).contains(device))
        XCTAssertTrue(Strings.odomoCardShowHere(name, device).contains(device))
        for text in [Strings.odomoCardHide, Strings.odomoCardShow, Strings.odomoStateHereDetail] {
            XCTAssertFalse(text.isEmpty)
        }
        XCTAssertLessThanOrEqual(Strings.odomoCardHide.count, 12, "the quiet button stays short")
    }
}
