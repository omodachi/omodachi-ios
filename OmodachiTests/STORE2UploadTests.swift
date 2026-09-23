import XCTest
@testable import Omodachi

/// STORE-2. The four things an App Store Connect upload checks for, read back
/// out of the bundle this test is hosted in — which is the app itself.
final class STORE2UploadTests: XCTestCase {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    /// §1. actool wrote the icon set into the bundle's Info.plist.
    func testTheAppHasAnIcon() throws {
        let icons = try XCTUnwrap(info["CFBundleIcons"] as? [String: Any], "no CFBundleIcons: the icon set was not compiled")
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
    }

    /// §2. The manifest is in the bundle and says what the binary uses.
    func testThePrivacyManifestIsBundledAndDeclaresItsReasons() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
        XCTAssertEqual((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
        let types = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for entry in types {
            reasons[entry["NSPrivacyAccessedAPIType"] as? String ?? ""] = entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        XCTAssertEqual(reasons, [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        ])
    }

    /// §3 (b). CoreBluetooth stays linked (SDL2's hid.o needs it), so the
    /// purpose string the upload check asks for is there in both languages.
    func testTheBluetoothPurposeStringIsThere() throws {
        let text = try XCTUnwrap(info["NSBluetoothAlwaysUsageDescription"] as? String)
        XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty)
        for language in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let strings = try XCTUnwrap(NSDictionary(contentsOfFile: path + "/InfoPlist.strings") as? [String: String])
            XCTAssertTrue(strings["NSBluetoothAlwaysUsageDescription"]?.contains("Moonlight") == true, language)
        }
    }

    /// §5. Present, and false. Whether it stays is the maintainer's call.
    func testTheExportComplianceKeyIsDeclared() {
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false)
    }

    /// §4. The licence page's two halves come out of the bundle.
    func testTheLicenceTextIsTheRepositoryLicence() throws {
        let text = try XCTUnwrap(LicenceNotice.licenceText())
        XCTAssertTrue(text.hasPrefix("                    GNU GENERAL PUBLIC LICENSE"), String(text.prefix(80)))
        XCTAssertTrue(text.contains("Version 3, 29 June 2007"))
        XCTAssertGreaterThan(text.count, 30_000, "the whole text, not an excerpt")
    }

    func testTheComponentListIsThirdPartyMd() {
        let components = LicenceNotice.components()
        let byName = Dictionary(components.map { ($0.name, $0.licence) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byName["Moonlight iOS 9.0.2"], "GPL-3.0")
        XCTAssertEqual(byName["LibVNCClient"], "GPL-2.0-or-later")
        XCTAssertEqual(byName["SDL2"], "zlib")
        XCTAssertEqual(byName["Citadel 0.12.0"], "MIT")
        XCTAssertEqual(byName["SwiftTerm 1.20.0"], "MIT")
        XCTAssertEqual(byName["OpenSSL-Package 3.3.2000"], "Apache-2.0, OpenSSL 3's own licence")
        XCTAssertNotNil(byName.keys.first { $0.hasPrefix("swift-nio, swift-crypto") }, "a row with no version keeps its name")
        XCTAssertEqual(components.count, 15, components.map(\.name).joined(separator: " / "))
        for component in components {
            XCTAssertFalse(component.name.contains("`") || component.name.contains("**") || component.name.contains("]("), component.name)
        }
    }

    func testTheParserOnlyReadsTheComponentTables() {
        let markdown = """
        | | |
        |---|---|
        | File | `x.ttf` |

        | Component | Path | Licence |
        | --- | --- | --- |
        | **Thing** 1.0 | `a/` | **GPL-3.0** |

        | Package | Version | Licence |
        | --- | --- | --- |
        | [Pkg](https://example.org) | 2.1.0 | MIT |
        | pkg-a, pkg-b | pinned in `Package.resolved` | Apache-2.0 |
        """
        XCTAssertEqual(LicenceNotice.components(markdown: markdown), [
            .init(name: "Thing 1.0", licence: "GPL-3.0"),
            .init(name: "Pkg 2.1.0", licence: "MIT"),
            .init(name: "pkg-a, pkg-b", licence: "Apache-2.0"),
        ])
    }

    func testTheVersionLineIsReleaseAndBuild() {
        XCTAssertEqual(BuildStamp.versionLine("0.1.0", "202609232039"), "0.1.0 (202609232039)")
        XCTAssertEqual(BuildStamp.versionLine("0.1.0", ""), "0.1.0")
        XCTAssertEqual(BuildStamp.marketingVersion, "0.1.0")
    }
}
