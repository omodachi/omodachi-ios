import Foundation
import XCTest
@testable import Omodachi

private actor CursorFixtureService: CompanionServing {
    var state: HostStateDTO
    private var continuation: AsyncThrowingStream<SanitizedHostEvent, Error>.Continuation?
    init() throws { state = try Self.makeState(revision: 10, cursor: 12, workspace: 2) }
    static func makeState(revision: Int, cursor: Int, workspace: Int, instance: String = "instance-a") throws -> HostStateDTO {
        try JSONDecoder().decode(HostStateDTO.self, from: Data("{\"revision\":\(revision),\"event_cursor\":\(cursor),\"instance_id\":\"\(instance)\",\"host\":{\"name\":\"cursor-fixture\",\"connected\":true},\"workspace\":{\"active\":\(workspace)}}".utf8))
    }
    func setState(revision: Int, cursor: Int, workspace: Int, instance: String = "instance-a") throws { state = try Self.makeState(revision: revision, cursor: cursor, workspace: workspace, instance: instance) }
    func connect() async throws {}
    func disconnect() async { continuation?.finish(); continuation = nil }
    func fetchState() async throws -> HostStateDTO { state }
    func fetchSnapshot() async throws -> CompanionSnapshot {
        let decoder = JSONDecoder()
        return try CompanionSnapshot(state: state,
            capabilities: decoder.decode(HostCapabilitiesDTO.self, from: Data(#"{"terminal":true,"desktop":false}"#.utf8)),
            catalog: decoder.decode(HostCatalogDTO.self, from: Data(#"{"revision":"cursor-catalog","entries":[]}"#.utf8)),
            herdr: decoder.decode(HostHerdrDTO.self, from: Data(#"{"available":false}"#.utf8)))
    }
    func invoke(entryID: String, catalogRevision: String, parameters: [String : CompanionParameter], targetToken: String?, stateRevision: Int?) async throws -> CompanionActionResponse { throw CompanionHostError.notConnected }
    func submitDefaultAgentTask(_ text: String, requestID: String) async throws -> AgentTaskResponse { throw CompanionHostError.notConnected }
    func events(since: Int, instanceID: String?) async -> AsyncThrowingStream<SanitizedHostEvent, Error> { AsyncThrowingStream { continuation = $0 } }
    func send(seq: Int, after: Int) throws {
        let data = Data("{\"event\":{\"seq\":\(seq),\"event_id\":\"evt-\(seq)\",\"type\":\"cursor.test\"},\"instance_id\":\"instance-a\",\"after_cursor\":\(after)}".utf8)
        continuation?.yield(try CompanionHostClient.decodeEvent(data))
    }
    var isListening: Bool { continuation != nil }
}

@MainActor final class HomeCursorContinuityTests: XCTestCase {
    private func store(_ service: CursorFixtureService, defaults: UserDefaults) throws -> HomeStore {
        var profile = HostProfile(); profile.mock = false; profile.companionURL = "https://cursor.invalid"
        defaults.set(try JSONEncoder().encode(profile), forKey: "omodachi.profile.v1")
        return HomeStore(defaults: defaults, clientFactory: { _, _ in service }, autoConnect: false)
    }
    func testHTTPRefreshCannotChangeWSSCursorOrApplyOlderState() async throws {
        let service = try CursorFixtureService()
        let name = "home-cursor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let home = try store(service, defaults: defaults)
        await home.connectCompanion()
        for _ in 0..<100 where !(await service.isListening) { await Task.yield() }
        XCTAssertEqual(home.eventResumePosition.cursor, 12)
        try await service.send(seq: 15, after: 12)
        for _ in 0..<100 where home.eventResumePosition.cursor != 15 { await Task.yield() }
        XCTAssertEqual(home.eventResumePosition.cursor, 15)
        try await service.setState(revision: 11, cursor: 99, workspace: 3)
        await home.refreshCompanionState()
        XCTAssertEqual(home.state.workspace, 3)
        XCTAssertEqual(home.eventResumePosition.cursor, 15, "Global HTTP cursor includes private events")
        try await service.send(seq: 16, after: 15)
        for _ in 0..<100 where home.eventResumePosition.cursor != 16 { await Task.yield() }
        XCTAssertEqual(home.eventResumePosition.cursor, 16)
        XCTAssertEqual(home.connectionDiagnostics.stateRevision, 11)
        XCTAssertEqual(home.connectionDiagnostics.deliveredEventCursor, 16)
        try await service.setState(revision: 9, cursor: 1, workspace: 4)
        await home.refreshCompanionState()
        XCTAssertEqual(home.state.workspace, 3, "Out-of-order GET cannot replace newer state")
        XCTAssertEqual(home.eventResumePosition.cursor, 16)
        XCTAssertEqual(home.eventResumePosition.instanceID, "instance-a")
        await home.disconnectCompanion()
    }
}
