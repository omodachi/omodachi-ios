import XCTest
@testable import Omodachi

/// I18N-1 §2. Core speaks in codes and the screen speaks a language; this is
/// the seam, and the thing that can rot at it is a code nobody mapped reaching
/// a panel as a bare identifier.
///
/// `scripts/check_xcstrings.py` walks `omodachi-core/contracts` and fails the
/// build when core names a reason `knownCodes` does not. These tests walk the
/// other direction: every code in `knownCodes`, in both languages, has to come
/// back as a sentence rather than as itself.
final class ReasonTextTests: XCTestCase {

    // MARK: - The whole set

    /// Every code the contracts name maps to a sentence — not to the code, not
    /// to the unknown fallback, not to nothing.
    func testEveryContractCodeHasASentence() {
        XCTAssertGreaterThan(ReasonText.knownCodes.count, 150,
                             "the contracts name more reasons than this; the list has been trimmed")
        for (code, domain) in ReasonText.knownCodes {
            let text = ReasonText.message(code, domain: domain)
            XCTAssertFalse(text.isEmpty, "\(code) says nothing")
            XCTAssertNotEqual(text, code, "\(code) is shown as itself rather than as a sentence")
            XCTAssertNotEqual(text, ReasonText.unknown(code, domain: domain),
                              "\(code) falls through to the unknown sentence")
        }
    }

    /// The same, in English. A mapping that exists only in the source language
    /// is exactly the bug this spec was opened for — Leo's iPad showed the
    /// Chinese panel and the English sentence side by side.
    ///
    /// The codes are checked through the catalog rather than through
    /// `ReasonText`, because `ReasonText` answers in whatever language the
    /// device is set to: every `reason.*` key the source language holds has to
    /// exist, translated and different, in English too.
    func testEveryReasonKeyIsInBothLanguages() throws {
        let source = try Self.table("zh-Hans")
        let english = try Self.table("en")
        let keys = source.keys.filter { $0.hasPrefix("reason.") }
        XCTAssertGreaterThan(keys.count, 100, "the reason table has been trimmed, or it was not readable")
        for key in keys.sorted() {
            let translated = try XCTUnwrap(english[key], "\(key) has no English translation")
            XCTAssertFalse(translated.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) is empty in English")
            XCTAssertNotEqual(translated, source[key],
                              "\(key) is the same string in both languages, so one of them is untranslated")
        }
    }

    /// The app's own name and its three system prompts — the sentences iOS
    /// shows, which live in `InfoPlist.xcstrings` rather than in `Strings`.
    func testTheSystemPromptsAreInBothLanguages() throws {
        for key in ["CFBundleDisplayName", "NSLocalNetworkUsageDescription",
                    "NSFaceIDUsageDescription", "NSMicrophoneUsageDescription"] {
            for language in ["zh-Hans", "en"] {
                let table = try Self.table(language, resource: "InfoPlist")
                let value = try XCTUnwrap(table[key], "\(key) is not localized for \(language)")
                XCTAssertFalse(value.isEmpty)
            }
        }
    }

    // MARK: - The shape of the mapping

    /// A code nobody mapped is still reportable: a sentence, then the code in
    /// brackets. Never the code on its own — that is what a panel showing
    /// `remote_session_exists` looked like.
    func testAnUnmappedCodeIsNamedInsideASentence() {
        let text = ReasonText.message("something_core_added_later", domain: .remote)
        XCTAssertTrue(text.contains("something_core_added_later"), "the code is dropped, so nobody can report it")
        XCTAssertGreaterThan(text.count, "something_core_added_later".count + 4,
                             "the code is shown bare rather than inside a sentence")
    }

    /// `503` reads as "that part of the host is not up yet" in every domain,
    /// rather than as a refusal.
    func testAServiceThatIsNotUpYetReadsThatWay() {
        let notReady = ReasonText.message("something_new", domain: .herdr, status: 503)
        let refused = ReasonText.message("something_new", domain: .herdr, status: 409)
        XCTAssertNotEqual(notReady, refused)
        XCTAssertTrue(notReady.contains("something_new"))
    }

    /// Four codes mean different things to different halves of the API, so the
    /// domain picks before the shared table does.
    func testADomainAnswersBeforeTheSharedTable() {
        XCTAssertNotEqual(ReasonText.message("permission_denied", domain: .remote),
                          ReasonText.message("permission_denied", domain: .media),
                          "a remote refusal and a pairing refusal are not the same sentence")
        XCTAssertEqual(ReasonText.message("permission_denied", domain: .host),
                       Strings.reasonPermissionDenied)
    }

    /// The wire types stopped carrying copy of their own in I18N-1; each one
    /// now asks `ReasonText`, which is what keeps one code from having two
    /// translations.
    func testTheWireTypesAskReasonText() {
        XCTAssertEqual(RemoteRequestError(code: "session_not_ready", status: 409).userMessage,
                       ReasonText.message("session_not_ready", domain: .remote))
        XCTAssertEqual(MediaPairingError(code: "media_pairing_invalid_pin", status: 400).userMessage,
                       ReasonText.message("media_pairing_invalid_pin", domain: .media))
        XCTAssertEqual(HerdrRequestError(code: "herdr_control_in_use", status: 409).userMessage,
                       ReasonText.message("herdr_control_in_use", domain: .herdr))
        XCTAssertEqual(VoiceReason.message("voxtype_not_installed"),
                       ReasonText.message("voxtype_not_installed", domain: .voice))
        XCTAssertEqual(AgentChatHostError(code: "agent_busy").errorDescription,
                       ReasonText.message("agent_busy", domain: .agent))
    }

    /// `remote_session_exists` is the one refusal that names who holds the
    /// host, and that sentence is a catalog string with two slots rather than
    /// a hand-built one.
    func testTheOccupiedHostNamesItsOwner() {
        let owner = RemoteRequestError.Owner(sessionID: "rs_" + String(repeating: "0", count: 32),
                                             deviceID: "ios-1", deviceName: "Leo's iPad",
                                             mode: .takeover, backend: .sunshine, startedAt: nil)
        let text = RemoteRequestError(code: "remote_session_exists", status: 409, owner: owner).userMessage
        XCTAssertTrue(text.contains("Leo's iPad"))
        XCTAssertTrue(text.contains(RemoteMode.takeover.title))
        XCTAssertNotEqual(text, ReasonText.message("remote_session_exists", domain: .remote))
    }

    // MARK: - Numbers and dates are the locale's, not C's

    func testNumbersAreFormattedRatherThanInterpolated() {
        XCTAssertEqual(Format.count(7), 7.formatted(.number.grouping(.automatic)))
        XCTAssertEqual(Format.percent(0.7), (0.7).formatted(.percent.precision(.fractionLength(0))))
        XCTAssertEqual(Format.percent(1.4), Format.percent(1), "a fraction over one is clamped, not shown as 140%")
        XCTAssertEqual(Format.list(["a", "b"]), ["a", "b"].formatted(.list(type: .and, width: .standard)))
        XCTAssertNil(Format.stamp("nope"))
        XCTAssertNil(Format.stamp("20260921"))
        XCTAssertNotNil(Format.stamp("202609210214"))
    }

    // MARK: -

    /// One compiled `.strings` table, straight out of the bundle.
    private static func table(_ language: String, resource: String = "Localizable") throws -> [String: String] {
        let lproj = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"),
                                  "the app ships no \(language).lproj")
        let url = try XCTUnwrap(Bundle(path: lproj)?.url(forResource: resource, withExtension: "strings"),
                                "\(language).lproj holds no \(resource).strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String],
                             "\(language)/\(resource).strings is not a string table")
    }
}
