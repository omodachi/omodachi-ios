import UIKit
import XCTest
@testable import Omodachi

/// ATTACH-1: what the paperclip offers and refuses, the chip grammar, the
/// tray's uploads, the upload request, and the agent's echo of a message that
/// carried files.
@MainActor final class ATTACH1Tests: XCTestCase {

    // MARK: - rules

    func testThePickerRefusesBeforeAByteGoes() {
        let cases: [(String, Int, Bool, AttachmentRules.Refusal?)] = [
            ("shot.png", 10, true, nil),
            ("IMG_0001.HEIC", 10, true, nil),
            ("Photo 1", 10, true, nil),                 // a library pick with no extension
            ("paper.pdf", 10, false, nil),
            ("main.py", 10, false, nil),
            ("notes.md", 10, false, nil),
            ("big.png", AttachmentRules.maximumBytes + 1, true, .tooLarge),
            ("exact.png", AttachmentRules.maximumBytes, true, nil),
            ("drawing.svg", 10, true, .svg),
            ("drawing.svg", 10, false, .svg),
            ("bundle.zip", 10, false, .badType),
            ("Makefile", 10, false, .badType),
            ("empty.txt", 0, false, .empty),
        ]
        for (name, size, isImage, expected) in cases {
            XCTAssertEqual(AttachmentRules.refusal(name: name, size: size, isImage: isImage), expected, name)
        }
        XCTAssertEqual(AttachmentRules.maximumBytes, 25 * 1024 * 1024)
        XCTAssertEqual(AttachmentRules.kind(name: "x.heic", isImage: false), .image)
        XCTAssertEqual(AttachmentRules.kind(name: "x.pdf", isImage: false), .file)
        XCTAssertTrue(AttachmentRules.fileTypes.contains(.pdf))
        XCTAssertFalse(AttachmentRules.fileTypes.contains(.svg))
    }

    func testMarkersGoInWithASpaceAndComeOutWithOne() {
        XCTAssertEqual(AttachmentRules.marker(.image, 1), "[Image #1]")
        XCTAssertEqual(AttachmentRules.marker(.file, 2), "[File #2]")
        XCTAssertEqual(AttachmentRules.insert("[Image #1]", into: "look at"), "look at [Image #1] ")
        XCTAssertEqual(AttachmentRules.insert("[File #1]", into: ""), "[File #1] ")
        XCTAssertEqual(AttachmentRules.insert("[File #2]", into: "a "), "a [File #2] ")
        XCTAssertEqual(AttachmentRules.remove("[Image #1]", from: "see [Image #1] and [File #2] now"),
                       "see and [File #2] now")
        XCTAssertEqual(AttachmentRules.remove("[File #2]", from: "[File #2]"), "")
    }

    func testCoreRefusalsBecomeSentencesInBothLanguages() {
        XCTAssertEqual(AttachmentRules.refusal(code: "upload_too_large"), .tooLarge)
        XCTAssertEqual(AttachmentRules.refusal(code: "upload_svg_refused"), .svg)
        XCTAssertEqual(AttachmentRules.refusal(code: "upload_type_refused"), .badType)
        XCTAssertEqual(AttachmentRules.refusal(code: "upload_not_text"), .notText)
        XCTAssertEqual(AttachmentRules.refusal(code: "upload_heic_unconvertible"), .heic)
        XCTAssertEqual(AttachmentRules.refusal(code: "attachment_gone"), .gone)
        XCTAssertEqual(AttachmentRules.refusal(code: "host_unreachable"), .failed)
        for refusal in [AttachmentRules.Refusal.tooLarge, .svg, .badType, .notText, .heic, .empty, .gone, .failed, .tooMany] {
            let sentence = AttachmentRules.sentence(refusal, name: "x.png")
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertFalse(sentence.contains("upload_"), "a code never reaches the screen")
        }
        XCTAssertNotEqual(ReasonText.message("attachment_gone", domain: .herdr), "attachment_gone")
        XCTAssertNotEqual(ReasonText.message("attachment_gone", domain: .agent), "attachment_gone")
    }

    func testAnIPhonePhotoGoesAsAJPEG() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let heic = try XCTUnwrap(image.heicData())
        XCTAssertTrue(AttachmentRules.isHEIC(heic))
        let picked = PickedAttachment(data: heic, name: "IMG_0001.HEIC", isImage: true).normalised()
        XCTAssertEqual(picked.name, "IMG_0001.jpg")
        XCTAssertEqual(Array(picked.data.prefix(3)), [0xFF, 0xD8, 0xFF])
        let png = try XCTUnwrap(image.pngData())
        XCTAssertFalse(AttachmentRules.isHEIC(png))
        XCTAssertEqual(PickedAttachment(data: png, name: "s.png", isImage: true).normalised().data, png)
    }

    // MARK: - the tray

    private final class FakeUploader: AttachmentUploading, @unchecked Sendable {
        let lock = NSLock()
        var uploaded: [(String, UploadTarget)] = []
        var deleted: [String] = []
        var fail: [String: String] = [:]
        func upload(_ data: Data, name: String, target: UploadTarget,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> UploadedFile {
            progress(0.5)
            let refusal: String? = lock.withLock { uploaded.append((name, target)); return fail[name] }
            if let refusal { throw AttachmentUploadError(code: refusal) }
            let id = String(repeating: String(lock.withLock { uploaded.count }), count: 32)
            return UploadedFile(id: id, name: name, kind: "image", bytes: data.count, path: "/u/" + name)
        }
        func deleteUpload(id: String) async throws { lock.withLock { deleted.append(id) } }
    }

    private func settle(_ tray: AttachmentTray) async {
        for _ in 0..<200 where tray.isUploading { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private final class Draft { var text = "" }

    func testAPickIsAChipAndAMarkerThenUploadsInOrder() async {
        let box = Draft()
        box.text = "compare"
        let fake = FakeUploader()
        let tray = AttachmentTray(uploader: { fake }, target: { UploadTarget(kind: "herdr", session: "a1test", pane: "w1:p1") },
                                  readDraft: { box.text }, writeDraft: { box.text = $0 })
        tray.add([PickedAttachment(data: Data([1, 2, 3]), name: "a.png", isImage: true),
                  PickedAttachment(data: Data("x=1\n".utf8), name: "b.py", isImage: false)])
        XCTAssertEqual(box.text, "compare [Image #1] [File #2] ")
        XCTAssertEqual(tray.chips.map(\.n), [1, 2])
        XCTAssertTrue(tray.isUploading)
        await settle(tray)
        XCTAssertFalse(tray.isUploading)
        XCTAssertEqual(fake.uploaded.map(\.0), ["a.png", "b.py"])
        XCTAssertEqual(fake.uploaded.first?.1, UploadTarget(kind: "herdr", session: "a1test", pane: "w1:p1"))
        XCTAssertEqual(tray.refs.map(\.marker), ["[Image #1]", "[File #2]"])
        XCTAssertEqual(tray.readyImageCount, 1)
        // taking a chip off takes its marker out and its file off the computer
        tray.remove(1)
        XCTAssertEqual(box.text, "compare [File #2] ")
        await settle(tray)
        XCTAssertEqual(fake.deleted.count, 1)
        // its marker edited away, a chip still goes (in front, core's rule) and says so
        box.text = "compare"
        XCTAssertTrue(tray.markerMissing(tray.chips[0]))
        tray.clear()
        XCTAssertTrue(tray.isEmpty)
        tray.add([PickedAttachment(data: Data([1]), name: "c.png", isImage: true)])
        XCTAssertEqual(tray.chips.first?.n, 1, "a landed send restarts the numbering")
    }

    func testARefusedPickNeverUploadsAndAHostRefusalSaysWhy() async {
        let box = Draft()
        let fake = FakeUploader()
        fake.fail["bin.py"] = "upload_not_text"
        let tray = AttachmentTray(uploader: { fake }, target: { .agent }, readDraft: { box.text }, writeDraft: { box.text = $0 })
        tray.add([PickedAttachment(data: Data("<svg/>".utf8), name: "d.svg", isImage: false)])
        XCTAssertTrue(tray.isEmpty)
        XCTAssertEqual(tray.notice, AttachmentRules.sentence(.svg, name: "d.svg"))
        tray.add([PickedAttachment(data: Data([0]), name: "bin.py", isImage: false)])
        await settle(tray)
        XCTAssertTrue(tray.isEmpty, "the refused chip is gone")
        XCTAssertEqual(box.text, "", "and its marker with it")
        XCTAssertEqual(tray.notice, AttachmentRules.sentence(.notText, name: "bin.py"))
        let many = (1...11).map { PickedAttachment(data: Data([1]), name: "p\($0).png", isImage: true) }
        tray.add(many)
        XCTAssertEqual(tray.chips.count, AttachmentRules.maximumChips)
        XCTAssertEqual(tray.notice, AttachmentRules.sentence(.tooMany, name: ""))
        tray.discard()
        await settle(tray)
        XCTAssertTrue(tray.isEmpty)
    }

    // MARK: - the wire

    private func client() throws -> CompanionHostClient {
        CompanionURLProtocol.storage.reset()
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [CompanionURLProtocol.self]
        return CompanionHostClient(configuration: try CompanionHostConfiguration(endpoint: URL(string: "https://fixture.invalid:8443")!),
                                   credentials: FixtureCredential(), pinnedFingerprint: nil,
                                   session: URLSession(configuration: options))
    }

    func testTheUploadIsTheFileWithTheNameAndTargetInTheQuery() async throws {
        let client = try client()
        try await client.connect()
        CompanionURLProtocol.storage.set("/v1/uploads", body: #"{"contract_revision":"omodachi.v1","id":"0123456789abcdef0123456789abcdef","name":"shot.png","kind":"image","bytes":3,"path":"/home/user/.local/state/omodachi/uploads/agent-x.png","media_type":"image/png","expires_at":"2026-10-11T00:00:00Z"}"#)
        let done = try await client.upload(Data([1, 2, 3]), name: "shot.png",
                                           target: UploadTarget(kind: "herdr", session: "a1test", pane: "w1:p2")) { _ in }
        XCTAssertEqual(done.kind, "image")
        let request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }),
                       ["name": "shot.png", "target": "herdr", "session": "a1test", "pane": "w1:p2"])
        CompanionURLProtocol.storage.set("/v1/uploads", status: 415, body: #"{"error":{"code":"upload_svg_refused","message":"no"}}"#)
        do {
            _ = try await client.upload(Data([1]), name: "x.svg", target: .agent) { _ in }
            XCTFail("refused")
        } catch let error as AttachmentUploadError {
            XCTAssertEqual(error.code, "upload_svg_refused")
        }
    }

    func testSendsCarryTheChipsOnlyWhenThereAreSome() async throws {
        let client = try client()
        try await client.connect()
        CompanionURLProtocol.storage.set("/v1/agent/default/chat/messages", body: #"{"accepted":true,"turnID":"t","delivery":"accepted","images":"path"}"#)
        let receipt = try await client.chatSend("see [Image #1]", id: UUID(), model: nil, effort: nil,
                                                attachments: [AttachmentRef(id: String(repeating: "a", count: 32), marker: "[Image #1]")])
        XCTAssertTrue(receipt.imagesAsPaths)
        let sent = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.body(sent)) as? [String: Any])
        XCTAssertEqual((body["attachments"] as? [[String: String]])?.first?["marker"], "[Image #1]")
        CompanionURLProtocol.storage.set("/v1/herdr/panes/w1:p1/text", body: #"{"action":"text","pane":"w1:p1","delivered":true,"submitted":true,"reason":null,"proof":"tail"}"#)
        _ = try await client.herdrText(pane: "w1:p1", text: "plain", submit: true)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.body(try XCTUnwrap(CompanionURLProtocol.storage.requests.last))) as? [String: Any])
        XCTAssertNil(plain["attachments"])
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 2048)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    // MARK: - the agent's echo

    func testAMessageOfOnlyFilesCanBeSentAndItsEchoGoesWithTheHostsRow() throws {
        let identity = AgentChatIdentity(hostID: "h", agentID: "default", provider: "codex", providerSessionID: "t")
        var model = AgentChatModel()
        XCTAssertNotNil(model.beginEnsure())
        XCTAssertTrue(model.restore(identity: identity, rows: [], activeTurn: nil, sequence: 0))
        XCTAssertFalse(model.canSend)
        XCTAssertTrue(model.canSend(attached: true))
        model.draft = "what is [Image #1]"
        XCTAssertNotNil(model.beginSend(attachments: 1, images: 1))
        XCTAssertEqual(model.localEcho?.images, 1)
        XCTAssertTrue(model.apply(.turnStarted("turn-1"), identity: identity, sequence: 1))
        // core echoes the words with its own changes (paths, renumbering)
        let echoed = AgentChatMessage(id: "u1", turnID: "turn-1", role: .user, text: "what is [Image #1]\n\nAttached: /u/a.pdf", images: 1)
        XCTAssertTrue(model.apply(.message(echoed), identity: identity, sequence: 2))
        XCTAssertNil(model.localEcho)
    }

    func testAUserRowCarriesItsPictureCount() throws {
        let json = #"{"identity":{"hostID":"h","agentID":"default","provider":"codex","providerSessionID":"t"},"rows":[{"kind":"message","id":"u1","turnID":"t1","role":"user","text":"look","images":2},{"kind":"message","id":"u2","turnID":"t1","role":"user","text":"plain"}],"activeTurn":null,"sequence":3}"#
        let snapshot = try JSONDecoder().decode(AgentChatSnapshotWire.self, from: Data(json.utf8)).value()
        guard case .message(let first) = snapshot.rows[0], case .message(let second) = snapshot.rows[1] else { return XCTFail() }
        XCTAssertEqual(first.images, 2)
        XCTAssertNil(second.images)
    }
}
