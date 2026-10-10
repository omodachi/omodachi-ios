import Foundation

// AGENT-COLLIE-1. What a long codex turn looks like on a phone: each step in a
// few words, runs of steps folded into one line, every edit as a card with its
// change, and a way to find your place again.
//
// The run folding (`AgentRun.group`, `liveTail`), the step line and the find
// stepping follow Collie (https://github.com/AltanS/collie, `web/src/
// components/chat-cards.tsx` `groupRuns` / `ToolGroup` / `stepLine` and
// `web/src/lib/transcript-search.ts`), MIT, Copyright (c) 2026 Altan Sarisin;
// see the acknowledgements. Ported to this app's own rows: the data is codex's
// structured items as core projects them, never a parsed screen.

/// One changed file of a `fileChange` row (core's `changes[]`). `diff` is
/// unified-diff lines - `@@` hunk headers, `+`, `-` and context - exactly as
/// many as core carried; `diffOmitted` counts the ones it did not.
struct AgentChatChange: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case add, delete, update }
    let path: String
    let kind: Kind
    var movePath: String? = nil
    let added: Int
    let removed: Int
    let diff: [String]
    var diffOmitted: Int = 0

    var name: String { Self.name(path) }
    /// Where a moved file went: its name, or its folder and name when the
    /// name stayed the same.
    var moveName: String? {
        guard let movePath else { return nil }
        let moved = Self.name(movePath)
        guard moved == name else { return moved }
        let parts = movePath.split(separator: "/")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: "/") : moved
    }
    static func name(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }

    /// The card's verb: "Created", "Deleted", "Moved", "Edited".
    var verb: String {
        switch kind {
        case .add: Strings.agentStepCreated
        case .delete: Strings.agentStepDeleted
        case .update: movePath == nil ? Strings.agentStepEdited : Strings.agentStepMoved
        }
    }
    var subject: String { moveName.map { "\(name) → \($0)" } ?? name } // non-copy: file names

    /// One drawn diff line.
    enum Line: Equatable, Sendable {
        case hunk, added(String), removed(String), context(String)
    }
    var lines: [Line] {
        diff.compactMap { raw in
            if raw.hasPrefix("@@") { return .hunk }
            if raw.hasPrefix("\\") { return nil } // `\ No newline at end of file`
            if raw.hasPrefix("+") { return .added(String(raw.dropFirst())) }
            if raw.hasPrefix("-") { return .removed(String(raw.dropFirst())) }
            return .context(raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw)
        }
    }
}

/// codex's reading of a command (`commandActions`, as core projects it).
struct AgentChatAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case read, listFiles, search, unknown }
    let type: Kind
    var name: String? = nil
    var path: String? = nil
    var query: String? = nil
}

enum AgentStepKind: Equatable, Sendable { case command, read, search, edit, other }

/// A step in a few words: a verb in the chrome face and the thing it acted on.
/// `mono` says the subject is machine text (a path, a command, a query).
struct AgentStepLine: Equatable, Sendable {
    let verb: String
    let subject: String
    let mono: Bool
    var text: String { verb.isEmpty ? subject : "\(verb) \(subject)" } // non-copy: two catalog parts
}

extension AgentChatTool {
    /// Core sends these only for a `commandExecution`.
    var isCommand: Bool { command != nil || !(actions ?? []).isEmpty || exitCode != nil }

    var stepKind: AgentStepKind {
        if !(changes ?? []).isEmpty { return .edit }
        let kinds = Set((actions ?? []).map(\.type))
        if !kinds.isEmpty && kinds.isSubset(of: [.read, .listFiles, .search]) {
            return kinds.contains(.read) && kinds.count == 1 ? .read : .search
        }
        return isCommand ? .command : .other
    }

    /// "$ git status", "Read app.py", "Searched TODO", "Edited app.py".
    var stepLine: AgentStepLine {
        if let changes, let first = changes.first {
            let more = changes.count - 1
            let subject = more > 0 ? Strings.agentStepAndMore(first.subject, Format.count(more)) : first.subject
            return AgentStepLine(verb: first.verb, subject: subject, mono: true)
        }
        switch stepKind {
        case .read:
            let names = (actions ?? []).compactMap(\.name)
            return AgentStepLine(verb: Strings.agentStepRead, subject: names.isEmpty ? commandLine : names.joined(separator: ", "), // non-copy: file names
                                 mono: true)
        case .search:
            let action = (actions ?? []).first { $0.type != .read } ?? (actions ?? [])[0]
            if action.type == .listFiles {
                // codex names the folder only when the command did.
                guard let path = action.path else { return AgentStepLine(verb: "$", subject: commandLine, mono: true) } // non-copy: a shell prompt
                return AgentStepLine(verb: Strings.agentStepListed, subject: path, mono: true)
            }
            return AgentStepLine(verb: Strings.agentStepSearched, subject: action.query ?? action.path ?? commandLine, mono: true)
        case .command:
            return AgentStepLine(verb: "$", subject: commandLine, mono: true) // non-copy: a shell prompt
        case .edit, .other:
            return AgentStepLine(verb: "", subject: name, mono: false)
        }
    }

    /// The words that ran, first line only: core's `command` (without the
    /// shell codex wraps them in) or, from an older core, the row's name.
    var commandLine: String {
        let words = command ?? name
        return words.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? words
    }

    /// How many files an edit step changed (a run counts files, not rows).
    var editCount: Int { (changes?.count ?? 0) + (changesOmitted ?? 0) }
}

// MARK: - Runs

/// A run of three or more consecutive steps (Collie `groupRuns`, minRun 3).
/// Answered prompts stay with the step they were about, inside the run.
struct AgentRun: Identifiable, Equatable, Sendable {
    let id: String
    let entries: [AgentTimelineEntry]

    /// A run that is working shows its newest steps (Collie `LIVE_TAIL`).
    static let liveTail = 6

    var tools: [AgentChatTool] {
        entries.compactMap { if case .row(.tool(let tool)) = $0 { tool } else { nil } }
    }
    var failed: Int { tools.filter { $0.status == .failed }.count }
    var running: Bool { tools.contains { $0.status == .running } }
    func waiting(on items: Set<String>) -> Bool { tools.contains { items.contains($0.id) } }
    /// "4 commands, 2 edits" - each kind counted on its own.
    var counts: AgentRunCounts {
        var counts = AgentRunCounts()
        for tool in tools {
            switch tool.stepKind {
            case .command: counts.commands += 1
            case .read: counts.reads += 1
            case .search: counts.searches += 1
            case .edit: counts.edits += tool.editCount
            case .other: counts.others += 1
            }
        }
        return counts
    }

    /// Where the drawn tail starts: the newest `liveTail` steps, or earlier
    /// when a step that is waiting for the person is further up.
    func tailStart(waiting items: Set<String>) -> Int {
        let firstWaiting = entries.firstIndex { entry in
            if case .row(.tool(let tool)) = entry { items.contains(tool.id) } else { false }
        }
        var steps = 0
        var start = entries.count
        // Count steps (tools) from the end; answered lines ride along.
        for index in entries.indices.reversed() {
            if case .row(.tool) = entries[index] { steps += 1 }
            if steps > Self.liveTail { break }
            start = index
        }
        if let firstWaiting { start = min(start, firstWaiting) }
        return start
    }
    /// The steps before `tailStart`, for "N earlier steps".
    func steps(before index: Int) -> Int {
        entries[..<index].filter { if case .row(.tool) = $0 { true } else { false } }.count
    }

    /// Splits the timeline into single entries and runs. `minRun` steps or
    /// more in a row become a run; fewer stay as they are.
    static func group(_ entries: [AgentTimelineEntry], minRun: Int = 3) -> [AgentTranscriptItem] {
        var out: [AgentTranscriptItem] = []
        var pending: [AgentTimelineEntry] = []
        func flush() {
            let steps = pending.filter { if case .row(.tool) = $0 { true } else { false } }.count
            if steps >= minRun, case .row(.tool(let first))? = pending.first(where: {
                if case .row(.tool) = $0 { true } else { false }
            }) {
                out.append(.run(AgentRun(id: "run:\(first.id)", entries: pending)))
            } else {
                out.append(contentsOf: pending.map { .entry($0) })
            }
            pending = []
        }
        for entry in entries {
            switch entry {
            case .row(.tool): pending.append(entry)
            case .answered where !pending.isEmpty: pending.append(entry)
            default:
                flush()
                out.append(.entry(entry))
            }
        }
        flush()
        return out
    }
}

struct AgentRunCounts: Equatable, Sendable {
    var commands = 0, reads = 0, searches = 0, edits = 0, others = 0
    /// "4 commands, 2 edits", in the reader's language, kinds in a fixed order.
    var summary: String {
        let parts = [
            commands > 0 ? (commands == 1 ? Strings.agentRunCommand : Strings.agentRunCommands(Format.count(commands))) : nil,
            reads > 0 ? (reads == 1 ? Strings.agentRunRead : Strings.agentRunReads(Format.count(reads))) : nil,
            searches > 0 ? (searches == 1 ? Strings.agentRunSearch : Strings.agentRunSearches(Format.count(searches))) : nil,
            edits > 0 ? (edits == 1 ? Strings.agentRunEdit : Strings.agentRunEdits(Format.count(edits))) : nil,
            others > 0 ? (others == 1 ? Strings.agentRunOther : Strings.agentRunOthers(Format.count(others))) : nil,
        ].compactMap { $0 }
        return parts.dropFirst().reduce(parts.first ?? "") { Strings.pair($0, $1) }
    }
}

/// What the transcript draws: a single entry or a run of steps.
enum AgentTranscriptItem: Identifiable, Equatable, Sendable {
    case entry(AgentTimelineEntry)
    case run(AgentRun)
    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .run(let run): run.id
        }
    }
}

// MARK: - Find

/// Find in the conversation (Collie `transcript-search.ts`). Only what is on screen with every output folded is
/// searched - the words, the step lines, the files an edit names - so every
/// match is one you can see.
enum AgentFind {
    static func searchable(_ entry: AgentTimelineEntry) -> String {
        switch entry {
        case .row(.message(let message)): return message.text
        case .row(.tool(let tool)):
            let files = (tool.changes ?? []).map { "\($0.verb) \($0.subject)" } // non-copy: catalog verb and file
            return ([tool.stepLine.text] + files).joined(separator: "\n")
        case .answered(let approval):
            return ([approval.summary] + (approval.answered ?? [])).joined(separator: "\n")
        }
    }

    /// Case- and width-insensitive substring, never a pattern: a stray `(`
    /// must not throw or quietly match nothing.
    static func contains(_ text: String, _ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    /// The ids of the timeline entries that match, oldest first.
    static func matches(_ entries: [AgentTimelineEntry], query: String) -> [String] {
        entries.filter { contains(searchable($0), query) }.map(\.id)
    }

    /// The next stop strictly after (or before) `from`, wrapping at the ends.
    /// `from` is a position in `order`; nil means "past the end".
    static func step(_ stops: [String], in order: [String], from: String?, forward: Bool) -> String? {
        guard !stops.isEmpty else { return nil }
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let at = from.flatMap { position[$0] } ?? (forward ? -1 : order.count)
        let indexed = stops.compactMap { stop in position[stop].map { (stop, $0) } }
        if forward {
            return (indexed.first { $0.1 > at } ?? indexed.first)?.0
        }
        return (indexed.last { $0.1 < at } ?? indexed.last)?.0
    }
}
