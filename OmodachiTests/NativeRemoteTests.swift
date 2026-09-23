import Network
import UIKit
import XCTest
@testable import Omodachi

@MainActor final class NativeRemoteTests: XCTestCase {
    func testLocalPanelKeyboardAndAccessibilityPathsNeverStartMedia() throws {
        let client = OMRemoteClient(host: "unused.invalid")
        let view = client.renderView
        let command = try XCTUnwrap(view.keyCommands?.first { $0.input == "m" })
        XCTAssertEqual(command.modifierFlags, [.command, .shift])
        var sources: [String] = []
        client.panelHandler = { sources.append($0) }
        view.perform(command.action, with: command)
        XCTAssertEqual(sources, ["keyboard"])
        // A-59 rev 5 / review #10: the second alias, for the plugin's icon.
        let settings = try XCTUnwrap(view.keyCommands?.first { $0.input == "," })
        XCTAssertEqual(settings.modifierFlags, [.command, .shift])
        view.perform(settings.action, with: settings)
        XCTAssertEqual(sources, ["keyboard", "keyboard_settings"])
        let accessibility = try XCTUnwrap(view.accessibilityCustomActions?.first)
        XCTAssertEqual(accessibility.name, "Open Panel")
        _ = (accessibility.target as? NSObject)?.perform(accessibility.selector, with: accessibility)
        XCTAssertEqual(sources, ["keyboard", "keyboard_settings", "accessibility"])
        XCTAssertTrue(client.idle)
        XCTAssertEqual(client.generation, 0)
    }

    /// The Sunshine app to launch comes from the host's connection document, not
    /// from a hard-coded title, so the managed fork can name its own entry.
    func testSunshineClientTakesItsAppAndPortFromTheHost() {
        let client = OMRemoteClient(host: "unused.invalid")
        XCTAssertEqual(client.appTitle, "Desktop")
        XCTAssertEqual(client.httpsPort, 0, "0 keeps Moonlight's own default ports")
        client.appTitle = "Omodachi Desktop"
        client.httpsPort = 47984
        XCTAssertEqual(client.appTitle, "Omodachi Desktop")
        XCTAssertEqual(client.httpsPort, 47984)
        XCTAssertTrue(client.idle, "naming an app never starts media")
    }

    func testNativeViewHasNoInputWithoutActualPresentedFrame() {
        let client = OMRemoteClient(host: "unused.invalid")
        XCTAssertTrue(client.idle)
        XCTAssertTrue(client.beginLease())
        client.setInputEnabled(true, generation: 0)
        XCTAssertTrue(client.idle)
        XCTAssertEqual(client.generation, 0)
        XCTAssertEqual(client.leaseSerial, 1)
        client.stop { stopped in XCTAssertTrue(stopped) }
        XCTAssertTrue(client.beginLease())
        XCTAssertEqual(client.leaseSerial, 2, "Local lease serial cannot repeat when host media generations reset")
        // No network operation or identity generation is invoked by construction.
    }

    func testAMockProfileBuildsNoBackendAndNeverStarts() {
        let controller = RemoteSessionController()
        var profile = HostProfile()
        profile.mock = true
        controller.configure(profile: profile)
        XCTAssertNil(controller.sunshine)
        XCTAssertNil(controller.vnc)
        XCTAssertEqual(controller.phase, .idle)
        controller.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left")
        controller.start()
        XCTAssertEqual(controller.phase, .idle, "a demo profile has no host to ask")
    }

    func testAConnectRequestWithoutAViewportIsRefusedRatherThanGuessed() {
        let controller = RemoteSessionController()
        var profile = HostProfile()
        profile.mock = false
        profile.companionURL = "https://omarchy.invalid:8099"
        controller.configure(profile: profile)
        controller.start()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.message, Strings.remoteWaitingViewport)
    }
}

/// Discovery is public network metadata only. It establishes no authorization
/// and no TLS trust, and manual address entry always stays available.
final class HostDiscoveryTests: XCTestCase {
    func testAResolvedAddressIsPreferredAndTheLocalNameIsTheFallback() throws {
        let resolved = DiscoveredHost(instanceName: "omarchy", hostID: String(repeating: "a", count: 32),
                                      hostName: "omarchy", port: 8099, fingerprintPrefix: "f105e0c940117 9fa",
                                      addresses: ["192.168.1.10"])
        XCTAssertEqual(resolved.preferredURL?.absoluteString, "https://192.168.1.10:8099")
        XCTAssertEqual(resolved.id, String(repeating: "a", count: 32))
        XCTAssertEqual(resolved.displayName, "omarchy")

        let unresolved = DiscoveredHost(instanceName: "omarchy", hostID: nil, hostName: "omarchy",
                                        port: 8099, fingerprintPrefix: nil, addresses: [])
        XCTAssertEqual(unresolved.preferredURL?.absoluteString, "https://omarchy.local:8099")
        XCTAssertEqual(unresolved.id, "omarchy", "an unidentified host is still listed, by its instance name")

        let portless = DiscoveredHost(instanceName: "omarchy", hostID: nil, hostName: "omarchy",
                                      port: nil, fingerprintPrefix: nil, addresses: ["192.168.1.10"])
        XCTAssertNil(portless.preferredURL, "no advertised port means no address to offer")
    }

    func testAnIPv6LiteralIsBracketedSoTheURLIsUsable() {
        XCTAssertEqual(DiscoveredHost.url(host: "fe80::1", port: 8099)?.absoluteString, "https://[fe80::1]:8099")
        XCTAssertEqual(DiscoveredHost.url(host: "omarchy.local", port: 8099)?.absoluteString, "https://omarchy.local:8099")
    }

    func testEveryDiscoveredURLIsAValidCompanionEndpoint() throws {
        let host = DiscoveredHost(instanceName: "omarchy", hostID: nil, hostName: "omarchy", port: 8099,
                                  fingerprintPrefix: nil, addresses: ["192.168.1.10"])
        let url = try XCTUnwrap(host.preferredURL)
        let configuration = try CompanionHostConfiguration(endpoint: url)
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://192.168.1.10:8099")
    }

    @MainActor func testABrowserThatWasNeverStartedListsNothing() {
        let browser = HostBrowser()
        XCTAssertTrue(browser.hosts.isEmpty)
        XCTAssertFalse(browser.browsing)
        XCTAssertNil(browser.failure)
        browser.stop()
        XCTAssertTrue(browser.hosts.isEmpty)
    }
}
