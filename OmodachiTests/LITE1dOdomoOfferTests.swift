import XCTest
@testable import Omodachi

/// LITE-1d: Odomo offered where people look for notifications — what core
/// says (`odomo: {url, push_devices}`), the state both places read, "Not now"
/// per computer, and the words.
@MainActor final class LITE1dOdomoOfferTests: XCTestCase {
    private func fixture(_ name: String) throws -> HostRoadsDTO {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "CoreFixtures"))
        return try JSONDecoder().decode(HostRoadsDTO.self, from: Data(contentsOf: url))
    }

    private func roads(_ tail: String) throws -> HostRoadsDTO {
        let json = #"{"host_id":"00000000000000000000000000000000","tls_fingerprint_sha256":null,"endpoints":[]"# + tail + "}"
        return try JSONDecoder().decode(HostRoadsDTO.self, from: Data(json.utf8))
    }

    func testCoreFixturesDecodeToTheReading() throws {
        let on = try fixture("host-roads-odomo").odomoReading
        XCTAssertEqual(on.url?.absoluteString, "https://omarchy-fixture.tail0000.ts.net/odomo/")
        XCTAssertEqual(on.pushDevices, 1)
        let none = try fixture("host-roads-odomo-none").odomoReading
        XCTAssertNil(none.url)
        XCTAssertEqual(none.pushDevices, 0)
        // A core from before LITE-1d: no `odomo`, so no count.
        XCTAssertEqual(try fixture("host-roads").odomoReading, OdomoReading(url: nil, pushDevices: nil))
    }

    func testTheReadingTakesOnlyWhatCoreCanSend() throws {
        let url = "https://omarchy-fixture.tail0000.ts.net/odomo/"
        // `odomo.url` alone is enough (and is checked the same way as `odomo_url`).
        XCTAssertEqual(try roads(#","odomo":{"url":"\#(url)","push_devices":2}"#).odomoReading.url?.absoluteString, url)
        XCTAssertNil(try roads(#","odomo":{"url":"https://evil.example/odomo/","push_devices":2}"#).odomoReading.url)
        XCTAssertNil(try roads(#","odomo":{"url":null,"push_devices":-1}"#).odomoReading.pushDevices)
        XCTAssertNil(try roads(#","odomo":{"url":null,"push_devices":65}"#).odomoReading.pushDevices)
        XCTAssertEqual(try roads(#","odomo":{"url":null}"#).odomoReading, OdomoReading(url: nil, pushDevices: nil))
    }

    func testStateAndTheCard() {
        let url = URL(string: "https://omarchy-fixture.tail0000.ts.net/odomo/")!
        XCTAssertEqual(OdomoOffer.state(nil), .unknown)
        XCTAssertEqual(OdomoOffer.state(OdomoReading(url: url, pushDevices: 0)), .off(url: url, counted: true))
        XCTAssertEqual(OdomoOffer.state(OdomoReading(url: url, pushDevices: nil)), .off(url: url, counted: false))
        XCTAssertEqual(OdomoOffer.state(OdomoReading(url: url, pushDevices: 2)), .on(devices: 2, url: url))
        XCTAssertEqual(OdomoOffer.state(OdomoReading(url: nil, pushDevices: 1)), .on(devices: 1, url: nil))
        XCTAssertEqual(OdomoOffer.state(OdomoReading(url: nil, pushDevices: 0)), .noAddress)
        XCTAssertEqual(OdomoOffer.state(OdomoReading(url: nil, pushDevices: nil)), .noAddress)

        XCTAssertTrue(OdomoOffer.showsCard(.off(url: url, counted: true), dismissed: false))
        XCTAssertTrue(OdomoOffer.showsCard(.noAddress, dismissed: false), "explains instead of disappearing")
        XCTAssertFalse(OdomoOffer.showsCard(.on(devices: 1, url: url), dismissed: false))
        XCTAssertFalse(OdomoOffer.showsCard(.unknown, dismissed: false))
        XCTAssertFalse(OdomoOffer.showsCard(.off(url: url, counted: true), dismissed: true))
        XCTAssertFalse(OdomoOffer.showsCard(.noAddress, dismissed: true))
    }

    func testNotNowIsPerComputerAndStays() throws {
        let name = "lite1d-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let memory = OdomoOfferMemory(defaults: defaults)
        XCTAssertFalse(memory.isDismissed("a"))
        memory.dismiss("a")
        memory.dismiss("a")
        XCTAssertTrue(memory.isDismissed("a"))
        XCTAssertFalse(memory.isDismissed("b"), "another computer is still offered")
        XCTAssertEqual(defaults.stringArray(forKey: OdomoOfferMemory.key), ["a"])
        memory.dismiss("")
        XCTAssertFalse(memory.isDismissed(""))
        for index in 0..<70 { memory.dismiss("host-\(index)") }
        XCTAssertEqual(defaults.stringArray(forKey: OdomoOfferMemory.key)?.count, 64)
        XCTAssertTrue(OdomoOfferMemory(defaults: defaults).isDismissed("host-69"))
        memory.forget("host-69")
        XCTAssertFalse(memory.isDismissed("host-69"))
    }

    func testTheWordsNameOdomoOnceAndSayWhy() {
        let name = Strings.odomoName
        XCTAssertTrue(Strings.odomoCardWhy(name, DeviceWord.current).contains(name))
        XCTAssertTrue(Strings.odomoCardWhy(name, DeviceWord.current).contains(DeviceWord.current))
        XCTAssertTrue(Strings.odomoCardTitle(DeviceWord.current).contains(DeviceWord.current))
        XCTAssertTrue(Strings.odomoCardOpen(name).contains(name))
        XCTAssertTrue(Strings.odomoLockedRow(DeviceWord.current, name).hasSuffix(name))
        XCTAssertTrue(Strings.odomoNoneTailscale(name).contains(name))
        for text in [Strings.odomoCardHide, Strings.odomoCardHidden(Strings.panelSettings, Strings.panelNotifications), Strings.odomoStateOn, Strings.odomoStateOff] {
            XCTAssertFalse(text.isEmpty)
        }
    }
}
