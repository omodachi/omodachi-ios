// lint:host-words — a pane's screen (codex, a shell), standing in for the host's words.
import Foundation

/// HERDR-9, simulator UI runs only (`--ui-testing --herdr-choices-fixture`):
/// the demo's Herdr session with a question on two panes, and a pane that
/// takes the keys. The shipped demo refuses every write (it has no computer);
/// here the writes are kept in a list the UI test reads back, and the panes
/// answer them the way codex and a shell would, so a test can tap the strip,
/// see what went out, and see the question leave the screen.
///
/// * `w1:p1` is codex, waiting on a command approval (the wording of the real
///   codex 0.160 capture in `OmodachiTests/HerdrFrames`, on a 96-column pane);
///   `1` / `y` approves, `3` / Esc declines, and the screen moves on.
/// * `w1:p2` is a shell asking `[y/N]`; `y` or `n` and Enter answers it.
enum HerdrChoicesFixture {
    static var requested: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--herdr-choices-fixture")
        #else
        return false
        #endif
    }

    static let codexPane = "w1:p1"
    static let shellPane = "w1:p2"

    private static let dim = "\u{1b}[2m", bold = "\u{1b}[1m", reverse = "\u{1b}[1;7m", off = "\u{1b}[0m"

    static let approval = [
        "\(bold)›\(off) Use a shell command to create a file named hello.txt in this folder containing the word hi.",
        "",
        "• Running printf hi > hello.txt",
        "",
        "  \(bold)Would you like to run the following command?\(off)",
        "",
        "  Environment: local",
        "",
        "  Reason: Allow creating hello.txt in this folder containing hi?",
        "",
        "  $ printf hi > hello.txt",
        "",
        "",
        "\(reverse)› 1. Yes, proceed (y)\(off)",
        "  2. Yes, and don't ask again for commands that start with `printf hi > hello.txt` (p)",
        "  3. No, and tell Codex what to do differently (esc)",
        "",
        "  \(dim)Press \(off)\(bold)enter\(off)\(dim) to confirm or \(off)\(bold)esc\(off)\(dim) to cancel\(off)",
    ].joined(separator: "\r\n")

    static let approved = [
        "\(bold)›\(off) Use a shell command to create a file named hello.txt in this folder containing the word hi.",
        "",
        "✔ You approved codex to run printf hi > hello.txt this time",
        "",
        "• Ran printf hi > hello.txt",
        "  └ (no output)",
        "",
        "• Created hello.txt containing hi.",
        "",
        "\(bold)›\(off) \(dim)Ask Codex to do anything\(off)",
        "",
        "  \(dim)~/code/uptime\(off)",
    ].joined(separator: "\r\n")

    static let declined = [
        "\(bold)›\(off) Use a shell command to create a file named hello.txt in this folder containing the word hi.",
        "",
        "✗ You canceled the request to run printf hi > hello.txt",
        "",
        "■ Conversation interrupted - tell the model what to do differently.",
        "",
        "\(bold)›\(off) \(dim)Ask Codex to do anything\(off)",
        "",
        "  \(dim)~/code/uptime\(off)",
    ].joined(separator: "\r\n")

    static let question = "~/code/uptime ❯ ./clean.sh\r\nRemove the old notes file? [y/N] "

    /// The demo data with the two questions on screen.
    static func apply(_ data: Data) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var layout = root["layout"] as? [String: Any],
              var workspaces = layout["workspaces"] as? [[String: Any]], !workspaces.isEmpty,
              var tabs = workspaces[0]["tabs"] as? [[String: Any]], !tabs.isEmpty,
              var panes = tabs[0]["panes"] as? [[String: Any]], panes.count >= 2,
              var screens = root["screens"] as? [String: String]
        else { return nil }
        panes = panes.map { pane in
            var pane = pane
            if pane["id"] as? String == codexPane {
                pane["agent"] = ["name": "codex", "kind": "codex", "status": "blocked"]
                pane["agent_status"] = "blocked"
                pane["title"] = "codex"
                // HERDR-10: the Chinese question card, on Leo's pane size.
                if HerdrCJKFixture.requested {
                    pane["size"] = ["cols": HerdrCJKFixture.size.cols, "rows": HerdrCJKFixture.size.rows]
                }
            }
            return pane
        }
        screens[codexPane] = HerdrCJKFixture.requested ? HerdrCJKFixture.questionOne : approval
        screens[shellPane] = question
        tabs[0]["panes"] = panes
        workspaces[0]["tabs"] = tabs
        layout["workspaces"] = workspaces
        root["layout"] = layout
        root["screens"] = screens
        return try? JSONSerialization.data(withJSONObject: root)
    }

    /// What the pane shows after `keys` arrive on it, if they answer it.
    static func reaction(pane: String, keys: [String]) -> String? {
        switch (pane, keys) {
        case (codexPane, ["1"]), (codexPane, ["y"]), (codexPane, ["Enter"]): approved
        case (codexPane, ["3"]), (codexPane, ["Escape"]): declined
        case (shellPane, ["y", "Enter"]): question + "y\r\nanswer: y\r\n~/code/uptime ❯ "
        case (shellPane, ["n", "Enter"]): question + "n\r\nanswer: n\r\n~/code/uptime ❯ "
        default: nil
        }
    }

    /// A write as the line the test reads back: `w1:p1 keys 1`, `w1:p1 text …`.
    static func line(pane: String, write: HerdrWrite) -> String {
        switch write {
        case .keys(let keys): "\(pane) keys \(keys.joined(separator: " "))"
        case let .text(text, submit): "\(pane) text\(submit ? "+enter" : "") \(text)"
        case let .attached(text, _): "\(pane) text+enter \(text)"
        }
    }
}
