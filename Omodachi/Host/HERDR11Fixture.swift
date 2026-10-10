// lint:host-words — the host's folders, standing in for the host's words.
import Foundation

/// HERDR-11, simulator UI runs only (`--ui-testing --herdr11-fixture`): the
/// demo's New workspace card opens over these folders and launchers, a star and Create
/// are written to the fixture's list instead of a host - the shape
/// `GET /v1/herdr/folders` answers with (`contracts/fixtures/`).
enum HERDR11Fixture {
    static var requested: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--herdr11-fixture")
        #else
        return false
        #endif
    }

    static var folders: HerdrFoldersDTO? {
        guard requested else { return nil }
        func row(_ display: String, _ name: String) -> HerdrFolderDTO {
            HerdrFolderDTO(path: display.replacingOccurrences(of: "~", with: "/home/user"), display: display, name: name)
        }
        var value = HerdrFoldersDTO(home: "/home/user",
                                    recent: [row("~/code/uptime", "uptime"), row("~/Work/notes", "notes")],
                                    common: [row("~", "~"), row("~/code", "code")], browse: nil)
        value.favourites = [row("~/code/uptime", "uptime")]
        value.launchers = [HerdrLauncherDTO(command: "codex", label: "codex"),
                           HerdrLauncherDTO(command: "claude", label: "claude")]
        return value
    }
}
