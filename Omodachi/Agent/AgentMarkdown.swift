import Foundation

/// LINKS-1 §3. The markdown an agent writes, read into blocks the Agent panel
/// draws itself.
///
/// SwiftUI only reads markdown *inline* (`Text(.init(_:))`), so a heading came
/// out as `## Status`, a fenced block was squeezed into one line and a picture
/// was its alt text with nothing to tap (ATTACH-2 §2, image 01). This is the
/// small subset agents actually emit — headings, paragraphs, lists, quotes,
/// fenced code, tables kept monospaced, rules — and the inline marks inside
/// them: code, strong, emphasis, links, images and bare addresses.
///
/// It is deliberately not CommonMark. It never produces HTML, it fetches
/// nothing, and an unfinished construct (a fence that has not closed yet while
/// the answer streams) is drawn as what it is so far rather than as raw marks.
/// Line breaks inside a paragraph are kept: the panel used to keep them, and an
/// agent that writes two lines means two lines.
enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, [MarkdownInline])
    case paragraph([MarkdownInline])
    /// `start` is the first number of an ordered list, nil for bullets.
    case list(start: Int?, items: [[MarkdownBlock]])
    case quote([MarkdownBlock])
    case code(language: String?, text: String)
    /// A pipe table, kept as its own lines in the mono face so its columns
    /// still line up.
    case table(String)
    case rule
}

indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    /// Inline code. `target` is set when the whole span is a path (with an
    /// optional `:line`) or a web address, which then opens like a link.
    case code(String, target: String?)
    case strong([MarkdownInline])
    case emphasis([MarkdownInline])
    case link([MarkdownInline], target: String)
    /// `![alt](target)`: shown as its alt text and the target as a link to the
    /// file — never fetched (Leo, 2026-10-04: the phone does not view host files).
    case image(alt: String, target: String)
    case lineBreak
}

enum AgentMarkdown {
    // MARK: - Blocks

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return blocks(lines[...])
    }

    private static func blocks(_ input: ArraySlice<String>) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var index = input.startIndex
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
            if paragraph.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }) && paragraph.count >= 2 {
                result.append(.table(text))
            } else {
                result.append(.paragraph(inlines(text)))
            }
            paragraph = []
        }

        while index < input.endIndex {
            let line = input[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush(); index += 1; continue
            }
            if let fence = fenceOpening(line) {
                flush()
                var body: [String] = []
                index += 1
                while index < input.endIndex {
                    let candidate = input[index]
                    if isFenceClosing(candidate, fence: fence.marker) { index += 1; break }
                    body.append(dedent(candidate, by: fence.indent))
                    index += 1
                }
                result.append(.code(language: fence.language, text: body.joined(separator: "\n")))
                continue
            }
            if let heading = heading(line) {
                flush()
                result.append(.heading(level: heading.level, inlines(heading.text)))
                index += 1; continue
            }
            if isRule(trimmed), paragraph.isEmpty || !trimmed.hasPrefix("-") {
                flush()
                result.append(.rule)
                index += 1; continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while index < input.endIndex {
                    let candidate = input[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var rest = candidate.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    inner.append(String(rest))
                    index += 1
                }
                result.append(.quote(blocks(inner[...])))
                continue
            }
            if let first = listItem(line) {
                flush()
                let ordered = first.number != nil
                var items: [[MarkdownBlock]] = []
                var current: [String] = [first.content]
                var contentIndent = first.contentIndent
                index += 1
                while index < input.endIndex {
                    let candidate = input[index]
                    let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                    if let next = listItem(candidate), next.indent < contentIndent, (next.number != nil) == ordered {
                        items.append(blocks(current[...]))
                        current = [next.content]
                        contentIndent = next.contentIndent
                        index += 1
                        continue
                    }
                    if candidateTrimmed.isEmpty {
                        // A blank line ends the list unless the list (or this
                        // item) carries on after it.
                        let after = index + 1
                        if after < input.endIndex {
                            let following = input[after]
                            if let next = listItem(following), next.indent < contentIndent, (next.number != nil) == ordered {
                                current.append(""); index += 1; continue
                            }
                            if leadingSpaces(following) >= contentIndent,
                               !following.trimmingCharacters(in: .whitespaces).isEmpty {
                                current.append(""); index += 1; continue
                            }
                        }
                        break
                    }
                    if leadingSpaces(candidate) >= contentIndent {
                        current.append(dedent(candidate, by: contentIndent))
                        index += 1
                        continue
                    }
                    // A lazy continuation: plain text right under the item.
                    if listItem(candidate) == nil, fenceOpening(candidate) == nil, heading(candidate) == nil,
                       !candidateTrimmed.hasPrefix(">"), !isRule(candidateTrimmed) {
                        current.append(candidateTrimmed)
                        index += 1
                        continue
                    }
                    break
                }
                items.append(blocks(current[...]))
                result.append(.list(start: first.number, items: items))
                continue
            }
            // A paragraph line; a list or a fence can interrupt it, which the
            // checks above already did.
            paragraph.append(line.trimmingCharacters(in: .whitespaces))
            index += 1
        }
        flush()
        return result
    }

    private struct Fence { let marker: String; let indent: Int; let language: String? }

    private static func fenceOpening(_ line: String) -> Fence? {
        let indent = leadingSpaces(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        for character in ["`", "~"] {
            let run = rest.prefix { String($0) == character }.count
            guard run >= 3 else { continue }
            let info = rest.dropFirst(run).trimmingCharacters(in: .whitespaces)
            // A backtick fence's info string may not hold a backtick.
            if character == "`" && info.contains("`") { return nil }
            let language = info.split(separator: " ").first.map(String.init)
            return Fence(marker: String(repeating: character, count: run), indent: indent,
                         language: language?.isEmpty == false ? language : nil)
        }
        return nil
    }

    private static func isFenceClosing(_ line: String, fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = fence.first, trimmed.hasPrefix(fence) else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard leadingSpaces(line) <= 3 else { return nil }
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s is decoration.
        if let range = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(range) }
        if text.allSatisfy({ $0 == "#" }) { text = "" }
        return (level, text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private struct ListItem { let indent: Int; let number: Int?; let content: String; let contentIndent: Int }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = leadingSpaces(line)
        let rest = line.dropFirst(indent)
        if let marker = rest.first, "-*+".contains(marker) {
            let after = rest.dropFirst()
            guard let space = after.first, space == " " || space == "\t" else { return nil }
            let content = after.drop { $0 == " " || $0 == "\t" }
            // `- - -` is a rule, not a list.
            if isRule(String(rest)) { return nil }
            return ListItem(indent: indent, number: nil, content: String(content),
                            contentIndent: indent + 1 + (after.count - content.count))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")" else { return nil }
        let tail = after.dropFirst()
        guard let space = tail.first, space == " " || space == "\t" else { return nil }
        let content = tail.drop { $0 == " " || $0 == "\t" }
        return ListItem(indent: indent, number: number, content: String(content),
                        contentIndent: indent + digits.count + 1 + (tail.count - content.count))
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else if character == "\t" { count += 4 } else { break }
        }
        return count
    }

    private static func dedent(_ line: String, by amount: Int) -> String {
        var removed = 0
        var index = line.startIndex
        while index < line.endIndex, removed < amount {
            let character = line[index]
            if character == " " { removed += 1 } else if character == "\t" { removed += 4 } else { break }
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    // MARK: - Inlines

    static func inlines(_ text: String) -> [MarkdownInline] {
        merge(scan(Array(text)[...]))
    }

    /// One pass over the characters; plain runs are handed to `LinkDetector`
    /// afterwards, so an address inside a code span is never made a link twice.
    private static func scan(_ chars: ArraySlice<Character>) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var plain = ""
        var index = chars.startIndex

        func flushPlain() {
            guard !plain.isEmpty else { return }
            result.append(contentsOf: autolinked(plain))
            plain = ""
        }

        while index < chars.endIndex {
            let character = chars[index]
            // Escapes: the next punctuation character is literal.
            if character == "\\", index + 1 < chars.endIndex {
                let next = chars[index + 1]
                if next == "\n" { flushPlain(); result.append(.lineBreak); index += 2; continue }
                if next.isPunctuation || next.isSymbol { plain.append(next); index += 2; continue }
            }
            if character == "\n" {
                flushPlain(); result.append(.lineBreak); index += 1; continue
            }
            if character == "`" {
                let run = chars[index...].prefix { $0 == "`" }.count
                if let close = findRun(of: "`", length: run, in: chars, from: index + run) {
                    flushPlain()
                    var body = String(chars[(index + run)..<close])
                    if body.count >= 2, body.first == " ", body.last == " ", body.contains(where: { $0 != " " }) {
                        body = String(body.dropFirst().dropLast())
                    }
                    result.append(.code(body, target: codeTarget(body)))
                    index = close + run
                    continue
                }
                plain.append(String(repeating: "`", count: run)); index += run; continue
            }
            if character == "!", index + 1 < chars.endIndex, chars[index + 1] == "[",
               let link = linkAt(chars, from: index + 1) {
                flushPlain()
                result.append(.image(alt: plainText(scan(link.label)), target: link.target))
                index = link.end
                continue
            }
            if character == "[", let link = linkAt(chars, from: index) {
                flushPlain()
                result.append(.link(merge(scan(link.label)), target: link.target))
                index = link.end
                continue
            }
            if character == "<", let close = chars[index...].firstIndex(of: ">") {
                let inner = String(chars[(index + 1)..<close])
                if inner.range(of: #"^[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]+$"#, options: .regularExpression) != nil {
                    flushPlain()
                    result.append(.link([.text(inner)], target: inner))
                    index = close + 1
                    continue
                }
            }
            if character == "*" || character == "_" {
                let run = chars[index...].prefix { $0 == character }.count
                let strength = min(run, 2)
                let leftOK = index + strength < chars.endIndex && !chars[index + strength].isWhitespace
                // An underscore inside a word (snake_case) is a letter, not a mark.
                let wordBefore = index > chars.startIndex && (chars[index - 1].isLetter || chars[index - 1].isNumber)
                if leftOK, !(character == "_" && wordBefore),
                   let close = findEmphasisClose(character, strength: strength, in: chars, from: index + strength) {
                    flushPlain()
                    let inner = merge(scan(chars[(index + strength)..<close]))
                    result.append(strength == 2 ? .strong(inner) : .emphasis(inner))
                    index = close + strength
                    continue
                }
                plain.append(String(repeating: character, count: run)); index += run; continue
            }
            plain.append(character)
            index += 1
        }
        flushPlain()
        return result
    }

    private static func findRun(of character: Character, length: Int, in chars: ArraySlice<Character>,
                                from start: Int) -> Int? {
        var index = start
        while index < chars.endIndex {
            if chars[index] == character {
                let run = chars[index...].prefix { $0 == character }.count
                if run == length { return index }
                index += run
            } else {
                index += 1
            }
        }
        return nil
    }

    private static func findEmphasisClose(_ character: Character, strength: Int, in chars: ArraySlice<Character>,
                                          from start: Int) -> Int? {
        var index = start
        while index < chars.endIndex {
            let current = chars[index]
            if current == "`" {
                // A code span is opaque to emphasis.
                let run = chars[index...].prefix { $0 == "`" }.count
                if let close = findRun(of: "`", length: run, in: chars, from: index + run) { index = close + run; continue }
                index += run; continue
            }
            if current == "\n", index + 1 < chars.endIndex, chars[index + 1] == "\n" { return nil }
            if current == character {
                let run = chars[index...].prefix { $0 == character }.count
                let closesHere = run >= strength && index > start && !chars[index - 1].isWhitespace
                let wordAfter = index + run < chars.endIndex
                    && (chars[index + run].isLetter || chars[index + run].isNumber)
                if closesHere, !(character == "_" && wordAfter) {
                    // `**a**` with strength 1 would close at the first `*`
                    // of a strong run; only an exact or longer run closes.
                    return index + (run - strength)
                }
                index += run
                continue
            }
            index += 1
        }
        return nil
    }

    private struct LinkParts { let label: ArraySlice<Character>; let target: String; let end: Int }

    /// `[label](target "title")`, the `(` right after the `]`.
    private static func linkAt(_ chars: ArraySlice<Character>, from open: Int) -> LinkParts? {
        guard chars[open] == "[" else { return nil }
        var depth = 0
        var index = open
        var closeBracket: Int?
        while index < chars.endIndex {
            let character = chars[index]
            if character == "\\" { index += 2; continue }
            if character == "`" {
                let run = chars[index...].prefix { $0 == "`" }.count
                if let close = findRun(of: "`", length: run, in: chars, from: index + run) { index = close + run; continue }
            }
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { closeBracket = index; break }
            }
            if character == "\n", index + 1 < chars.endIndex, chars[index + 1] == "\n" { return nil }
            index += 1
        }
        guard let close = closeBracket, close + 1 < chars.endIndex, chars[close + 1] == "(" else { return nil }
        var cursor = close + 2
        while cursor < chars.endIndex, chars[cursor] == " " { cursor += 1 }
        var target = ""
        if cursor < chars.endIndex, chars[cursor] == "<" {
            guard let end = chars[cursor...].firstIndex(of: ">") else { return nil }
            target = String(chars[(cursor + 1)..<end])
            cursor = end + 1
        } else {
            var parens = 0
            while cursor < chars.endIndex {
                let character = chars[cursor]
                if character == " " || character == "\n" { break }
                if character == "(" { parens += 1 }
                if character == ")" {
                    if parens == 0 { break }
                    parens -= 1
                }
                target.append(character)
                cursor += 1
            }
        }
        // An optional title, which is dropped.
        while cursor < chars.endIndex, chars[cursor] == " " { cursor += 1 }
        if cursor < chars.endIndex, chars[cursor] == "\"" || chars[cursor] == "'" { // non-copy: quote characters
            let quote = chars[cursor]
            guard let end = chars[(cursor + 1)...].firstIndex(of: quote) else { return nil }
            cursor = end + 1
            while cursor < chars.endIndex, chars[cursor] == " " { cursor += 1 }
        }
        guard cursor < chars.endIndex, chars[cursor] == ")" else { return nil }
        return LinkParts(label: chars[(open + 1)..<close], target: target, end: cursor + 1)
    }

    /// Bare web addresses and absolute (or `~/`) paths in prose become links.
    /// Bare file names do not: in prose they are too often just words.
    private static func autolinked(_ text: String) -> [MarkdownInline] {
        let found = LinkDetector.detect(in: text, bareNames: false)
        guard !found.isEmpty else { return [.text(text)] }
        var result: [MarkdownInline] = []
        var cursor = text.startIndex
        for match in found {
            if cursor < match.range.lowerBound { result.append(.text(String(text[cursor..<match.range.lowerBound]))) }
            result.append(.link([.text(match.text)], target: match.text))
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex { result.append(.text(String(text[cursor...]))) }
        return result
    }

    /// A code span that is wholly one address opens like a link.
    static func codeTarget(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 4096 else { return nil }
        let found = LinkDetector.detect(in: trimmed, bareNames: false)
        guard found.count == 1, let only = found.first, only.text == trimmed else { return nil }
        return trimmed
    }

    static func plainText(_ inlines: [MarkdownInline]) -> String {
        inlines.map { node -> String in
            switch node {
            case .text(let value): value
            case .code(let value, _): value
            case .strong(let inner), .emphasis(let inner), .link(let inner, _): plainText(inner)
            case .image(let alt, _): alt
            case .lineBreak: "\n"
            }
        }.joined()
    }

    /// Adjacent text runs joined, so the renderer draws one run per style.
    private static func merge(_ nodes: [MarkdownInline]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for node in nodes {
            if case .text(let value) = node, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + value)
            } else if case .text(let value) = node, value.isEmpty {
                continue
            } else {
                result.append(node)
            }
        }
        return result
    }
}
