import UIKit
import XCTest
@testable import Omodachi

/// PAIR-4 follow-up. The pairing request used to carry the compiled-in string
/// `"Leo 的 iPhone"`, so every install — two real devices and every throwaway
/// acceptance simulator — landed in `omodachi-host devices list` under the same
/// two names and could not be told apart.
///
/// The replacement has to survive contact with `PairingClient.begin`, which
/// refuses a name that trims to nothing, is not 1…80 unicode scalars, or
/// carries a control character. Every case here asserts that contract, not
/// just the string.
final class CompanionDeviceNameTests: XCTestCase {

    /// Exactly the three conditions `PairingClient.begin` guards on.
    private func assertTheHostWouldAccept(_ name: String,
                                          _ message: String = "",
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue((1...80).contains(name.unicodeScalars.count),
                      "length \(name.unicodeScalars.count): \(message)", file: file, line: line)
        XCTAssertFalse(name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 },
                       "control character: \(message)", file: file, line: line)
        XCTAssertFalse(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "blank: \(message)", file: file, line: line)
    }

    func testAnOrdinaryNameIsSentAsItIs() {
        XCTAssertEqual(CompanionDeviceName.resolve(raw: "Leo 的 iPad Pro", fallback: "iPad"),
                       "Leo 的 iPad Pro")
        assertTheHostWouldAccept(CompanionDeviceName.resolve(raw: "Leo 的 iPad Pro", fallback: "iPad"))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(CompanionDeviceName.resolve(raw: "  \n Leo's iPhone \t ", fallback: "iPhone"),
                       "Leo's iPhone")
    }

    /// A control character costs the character, never the whole name.
    func testControlCharactersAreRemovedRatherThanRejectingTheName() {
        let name = CompanionDeviceName.resolve(raw: "iPad\u{0}\u{7}\u{7F}Pro", fallback: "iPad")
        XCTAssertEqual(name, "iPadPro")
        assertTheHostWouldAccept(name)
    }

    func testANameWithNothingInItFallsBackToTheIdiom() {
        for blank in ["", "   ", "\n\t ", "\u{0}\u{1}"] {
            XCTAssertEqual(CompanionDeviceName.resolve(raw: blank, fallback: "iPad"), "iPad", "for \(blank.debugDescription)")
        }
    }

    /// The fallback is not trusted either: an unusable one still has to leave
    /// the host a name it will accept.
    func testAnUnusableFallbackStillProducesSomethingTheHostAccepts() {
        let name = CompanionDeviceName.resolve(raw: "   ", fallback: " \u{0} ")
        XCTAssertEqual(name, "iPhone")
        assertTheHostWouldAccept(name)
    }

    func testALongNameIsCutToTheEightyScalarsTheHostAccepts() {
        let long = String(repeating: "长", count: 300)
        let name = CompanionDeviceName.resolve(raw: long, fallback: "iPad")
        XCTAssertEqual(name.unicodeScalars.count, 80)
        assertTheHostWouldAccept(name, "300 CJK characters")

        // Exactly 80 is not cut, and 81 is.
        let eighty = String(repeating: "a", count: 80)
        XCTAssertEqual(CompanionDeviceName.resolve(raw: eighty, fallback: "iPad"), eighty)
        XCTAssertEqual(CompanionDeviceName.resolve(raw: eighty + "a", fallback: "iPad").unicodeScalars.count, 80)
    }

    /// Cutting by scalar would leave half a flag behind. An emoji costs several
    /// scalars against the host's 80, so the cut is by `Character`.
    func testTruncationNeverSplitsAGraphemeCluster() {
        let flags = String(repeating: "🇯🇵", count: 60)   // 2 scalars each
        let name = CompanionDeviceName.resolve(raw: flags, fallback: "iPad")
        XCTAssertTrue(name.unicodeScalars.count <= 80)
        XCTAssertEqual(name.count * 2, name.unicodeScalars.count, "a flag is never cut in half")
        assertTheHostWouldAccept(name, "60 flag emoji")

        let family = String(repeating: "👨‍👩‍👧‍👦", count: 20)  // 7 scalars each
        let second = CompanionDeviceName.resolve(raw: family, fallback: "iPad")
        XCTAssertTrue(second.unicodeScalars.count <= 80)
        XCTAssertEqual(second.count * 7, second.unicodeScalars.count)
    }

    /// Trailing space that only becomes trailing *after* the cut is still gone.
    func testACutThatExposesTrailingSpaceIsTrimmedAgain() {
        let raw = String(repeating: "a", count: 79) + "   tail"
        let name = CompanionDeviceName.resolve(raw: raw, fallback: "iPad")
        XCTAssertEqual(name, String(repeating: "a", count: 79))
        assertTheHostWouldAccept(name)
    }

    /// What this test host actually calls itself, recorded so the host's device
    /// list can be read against a known value rather than a guess. Since
    /// iOS 16 a real device without the user-assigned-device-name entitlement
    /// reports its model name here; a Simulator reports its own name.
    @MainActor func testTheRealDeviceNameIsUsableAsItStands() {
        let raw = UIDevice.current.name
        let resolved = CompanionDeviceName.current()
        print("[PAIR-4] UIDevice.current.name = \(raw.debugDescription) -> device_name \(resolved.debugDescription)")
        assertTheHostWouldAccept(resolved, "UIDevice.current.name was \(raw.debugDescription)")
        XCTAssertNotEqual(resolved, "Leo 的 iPhone", "the compiled-in name is gone")
        XCTAssertNotEqual(resolved, "Leo 的 iPad", "the compiled-in name is gone")
    }
}
