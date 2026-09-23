import Foundation

/// STORE-2 §4. What Settings ⑥'s About says about the licence, read from the
/// bundle rather than written down a second time.
///
/// The GPL text is the repository's own `LICENSE`, and the component list is
/// parsed out of `docs/THIRD-PARTY.md` — both are copied into the app as
/// resources by `project.yml`, so the page and the source tree cannot disagree.
/// DISTRIBUTION.md asks for this entry: a GPL-3.0 binary that says where its
/// source is and what it is made of.
enum LicenceNotice {
    static let sourceURL = URL(string: "https://github.com/omodachi/omodachi-ios")!
    static let privacyURL = URL(string: "https://omodachi.app/privacy")!

    struct Component: Equatable, Hashable, Sendable {
        let name: String
        let licence: String
    }

    /// The full GPL-3.0 text, or `nil` when the bundle does not carry it.
    static func licenceText(bundle: Bundle = .main) -> String? {
        read("LICENSE", nil, bundle)
    }

    /// Every row of THIRD-PARTY.md's two component tables, in its order.
    static func components(bundle: Bundle = .main) -> [Component] {
        read("THIRD-PARTY", "md", bundle).map(components(markdown:)) ?? []
    }

    /// The tables whose first header cell is `Component` (vendored) or
    /// `Package` (Swift Package Manager). A `Package` row's version column is
    /// folded into the name when it is a version; "pinned in …" is not one.
    static func components(markdown: String) -> [Component] {
        var result: [Component] = []
        var columns: [String]?
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else { columns = nil; continue }
            let cells = cellsOf(line)
            if columns == nil {
                let head = cells.first.map(clean) ?? ""
                columns = (head == "Component" || head == "Package") ? cells.map(clean) : []
                continue
            }
            guard let header = columns, !header.isEmpty,
                  !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) else { continue }
            guard let licenceColumn = header.firstIndex(of: "Licence"), licenceColumn < cells.count else { continue }
            var name = clean(cells[0])
            if let versionColumn = header.firstIndex(of: "Version"), versionColumn < cells.count {
                let version = clean(cells[versionColumn])
                if version.first?.isNumber == true { name += " " + version }
            }
            let licence = firstSentence(clean(cells[licenceColumn]))
            if !name.isEmpty, !licence.isEmpty { result.append(Component(name: name, licence: licence)) }
        }
        return result
    }

    private static func read(_ name: String, _ ext: String?, _ bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func cellsOf(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    }

    /// Markdown down to the words: `[text](url)` keeps the text; `**` and
    /// backticks go.
    static func clean(_ cell: String) -> String {
        var text = cell.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// A licence cell sometimes goes on to explain itself; the list keeps the
    /// first sentence, which is the licence.
    private static func firstSentence(_ text: String) -> String {
        guard let stop = text.range(of: ". ") else { return text }
        return String(text[..<stop.lowerBound])
    }
}
