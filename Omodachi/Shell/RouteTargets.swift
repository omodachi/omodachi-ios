import Foundation

/// Launch targets belong to the native app. Catalog routes arrive prevalidated
/// by the companion; no shell syntax or window wrappers are parsed on iOS.
///
/// ARCH-1 renamed this out of the way of `Shell/SurfaceRouter`: one of the two
/// decides what is on screen, and this one only turns a catalog row into the
/// session descriptor that opens it.
enum SurfaceRouteTargets {
    static func agent(host: HostProfile) -> SessionDescriptor {
        let argv = host.herdrSession.isEmpty ? HerdrCommandAdapter.agentAttach().argv
            : ["herdr", "--session", host.herdrSession, "agent", "attach", "default"] // non-copy: argv
        return .init(title: Strings.panelAgent, kind: .agent, host: host, argv: argv)
    }
    static func herdr(host: HostProfile) -> SessionDescriptor {
        .init(title: Strings.panelHerdr, kind: .herdr, host: host, argv: HerdrCommandAdapter.herdr(session: host.herdrSession.isEmpty ? nil : host.herdrSession).argv)
    }
    static func shell(host: HostProfile, title: String, argv: [String]) -> SessionDescriptor {
        if argv == HerdrCommandAdapter.agentAttach().argv { return agent(host: host) }
        if argv.count == 6, Array(argv.prefix(2)) == ["herdr", "--session"], Array(argv.suffix(3)) == ["agent", "attach", "default"] { // non-copy: argv
            var named = host; named.herdrSession = argv[2]
            return .init(title: Strings.panelAgent, kind: .agent, host: named, argv: argv)
        }
        if argv == ["herdr"] { return herdr(host: host) }
        if argv.count == 4, Array(argv.prefix(3)) == ["herdr", "session", "attach"] { // non-copy: argv
            var named = host; named.herdrSession = argv[3]
            return herdr(host: named)
        }
        return .init(title: title, kind: argv.isEmpty ? .shell : .command, host: host, argv: argv)
    }
}

/// Inactive is a temporary loss of interaction, not a background teardown.
/// Only background ends the foreground-only Remote session.
enum SurfaceLifecyclePhase: Sendable { case active, inactive, background }
struct SurfaceLifecycleEffects: Equatable, Sendable {
    let foregroundConnections: Bool?
    let pauseRemoteInteraction: Bool
    let disconnectRemote: Bool
}
enum SurfaceLifecyclePolicy {
    static func effects(_ phase: SurfaceLifecyclePhase) -> SurfaceLifecycleEffects {
        switch phase {
        case .active: .init(foregroundConnections: true, pauseRemoteInteraction: false, disconnectRemote: false)
        case .inactive: .init(foregroundConnections: nil, pauseRemoteInteraction: true, disconnectRemote: false)
        case .background: .init(foregroundConnections: false, pauseRemoteInteraction: true, disconnectRemote: true)
        }
    }
}
enum NativeRoutePolicy {
    static func supported(_ route: String) -> Bool {
        ["native:agent", "native:herdr", "native:panel"].contains(route)
    }
    static let unavailableMessage = Strings.routeUnavailable
}
