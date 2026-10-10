import Foundation
import UIKit
import UniformTypeIdentifiers

/// ATTACH-1. A picture or a file from this phone, kept on the computer for an
/// agent to read (`POST /v1/uploads`, core `uploads.py`).
///
/// The computer decides what it keeps: pictures by their bytes, PDFs by
/// `%PDF-`, text and code by name with every byte checked, 25 MB at most. What
/// lives here only decides what the picker offers and what is refused before a
/// byte leaves the phone, so the person hears "too big" without waiting for
/// it. Nothing here is a security boundary.
///
/// An attachment is a chip and a marker (Collie ADR 0060): a pick puts
/// `[Image #N]` or `[File #N]` into the draft; Send carries the ids and the
/// markers, and core swaps each marker for the file's path (Herdr) or for
/// codex's own image input (Agent). The markers are English in every language
/// — they are what Claude Code and codex write themselves.
enum AttachmentRules {
    static let maximumBytes = 25 * 1024 * 1024
    static let maximumChips = 10
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"]
    /// core `uploads.TEXT_EXTS`, the same list.
    static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "rst", "org", "adoc", "tex",
        "json", "jsonl", "ndjson", "yaml", "yml", "toml", "ini", "cfg", "conf",
        "csv", "tsv", "log", "xml", "html", "htm", "css", "scss", "sass", "less",
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte",
        "py", "pyi", "ipynb", "go", "rs", "c", "h", "cc", "cpp", "cxx", "hpp", "hh",
        "java", "kt", "kts", "swift", "m", "mm", "rb", "php", "pl", "lua", "r", "jl",
        "scala", "dart", "zig", "nim", "ex", "exs", "erl", "hs", "ml", "clj",
        "sh", "bash", "zsh", "fish", "sql", "graphql", "gql", "proto", "diff", "patch",
    ]

    /// What the Files picker offers. Types first, so a text file a provider
    /// labels `public.plain-text` is offered whatever its name; the core still
    /// decides by its bytes.
    static var fileTypes: [UTType] {
        var types: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .pdf, .plainText, .utf8PlainText, .sourceCode,
                               .json, .xml, .html, .commaSeparatedText, .tabSeparatedText, .yaml,
                               .shellScript, .pythonScript, .swiftSource]
        for ext in textExtensions.sorted() {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    static func fileExtension(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = String(name[name.index(after: dot)...]).lowercased()
        guard !ext.isEmpty, ext.count <= 10, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return ext
    }

    enum Refusal: String, Equatable, Sendable {
        case tooLarge, svg, badType, notText, heic, empty, gone, failed, tooMany
    }

    /// `nil` means send it.
    static func refusal(name: String, size: Int, isImage: Bool) -> Refusal? {
        if size > maximumBytes { return .tooLarge }
        if size == 0 { return .empty }
        let ext = fileExtension(name)
        if ext == "svg" || ext == "svgz" { return .svg }
        if isImage { return nil }
        if let ext, imageExtensions.contains(ext) || textExtensions.contains(ext) || ext == "pdf" { return nil }
        return .badType
    }

    static func kind(name: String, isImage: Bool) -> AttachmentKind {
        if isImage { return .image }
        if let ext = fileExtension(name), imageExtensions.contains(ext) { return .image }
        return .file
    }

    static func marker(_ kind: AttachmentKind, _ n: Int) -> String {
        "[\(kind == .image ? "Image" : "File") #\(n)]" // non-copy: the marker grammar Claude Code and codex use
    }

    /// The marker goes in at the end, never welded to a word: a space before
    /// it unless the text already ends in whitespace, and one after it.
    static func insert(_ marker: String, into text: String) -> String {
        let lead = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
        return text + lead + marker + " "
    }

    /// Every copy of a marker leaves, with one space beside it.
    static func remove(_ marker: String, from text: String) -> String {
        var out = text
        while let range = out.range(of: marker) {
            var lower = range.lowerBound
            var upper = range.upperBound
            if upper < out.endIndex, out[upper] == " " { upper = out.index(after: upper) }
            else if lower > out.startIndex, out[out.index(before: lower)] == " " { lower = out.index(before: lower) }
            out.removeSubrange(lower..<upper)
        }
        return out
    }

    /// core's refusal codes, as the words to say.
    static func refusal(code: String?) -> Refusal {
        switch code {
        case "upload_too_large": .tooLarge
        case "upload_svg_refused": .svg
        case "upload_type_refused": .badType
        case "upload_not_text": .notText
        case "upload_heic_unconvertible": .heic
        case "upload_empty": .empty
        case "attachment_gone": .gone
        default: .failed
        }
    }

    static func sentence(_ refusal: Refusal, name: String) -> String {
        switch refusal {
        case .tooLarge: Strings.attachTooLarge(name)
        case .svg: Strings.attachSVG
        case .badType: Strings.attachBadType(name)
        case .notText: Strings.attachNotText(name)
        case .heic: Strings.attachHEIC
        case .empty: Strings.attachEmpty(name)
        case .gone: Strings.attachGone
        case .failed: Strings.attachFailed(name)
        case .tooMany: Strings.attachTooMany
        }
    }

    /// An iPhone photo is HEIC; it goes as a JPEG, which every agent reads
    /// (codex 0.154 drops a HEIC image without a word, ATTACH-1 report §1).
    static func isHEIC(_ data: Data) -> Bool {
        guard data.count >= 12, data[data.startIndex + 4..<data.startIndex + 8] == Data("ftyp".utf8) else { return false }
        let brand = String(decoding: data[data.startIndex + 8..<data.startIndex + 12], as: UTF8.self)
        return ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].contains(brand)
    }
}

enum AttachmentKind: String, Codable, Equatable, Sendable { case image, file }

/// Where an upload is for, as core's query names it.
struct UploadTarget: Equatable, Sendable {
    var kind: String
    var session: String? = nil
    var pane: String? = nil
    static let agent = UploadTarget(kind: "agent")
}

/// `upload.schema.json`.
struct UploadedFile: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: String
    let bytes: Int
    let path: String
}

/// What a send carries for one chip.
struct AttachmentRef: Encodable, Equatable, Sendable {
    let id: String
    let marker: String
}

struct AttachmentUploadError: Error, Equatable, Sendable { let code: String }

/// The two calls a tray makes. The real one is `CompanionHostClient`; the
/// demo answers at once; a test records.
protocol AttachmentUploading: Sendable {
    func upload(_ data: Data, name: String, target: UploadTarget,
                progress: @escaping @Sendable (Double) -> Void) async throws -> UploadedFile
    func deleteUpload(id: String) async throws
}

struct AttachmentChip: Equatable {
    enum Status: Equatable { case uploading(Double), ready }
    /// Its number in this draft, from 1, never reused within the draft.
    let n: Int
    let kind: AttachmentKind
    var name: String
    var status: Status
    /// core's upload id, once it is on the computer.
    var id: String?
    var thumbnail: UIImage?
    var marker: String { AttachmentRules.marker(kind, n) }
    var label: String { kind == .image ? Strings.attachChipImage(Format.count(n)) : Strings.attachChipFile(Format.count(n)) }
    var isUploading: Bool { if case .uploading = status { return true } else { return false } }
    static func == (a: AttachmentChip, b: AttachmentChip) -> Bool {
        a.n == b.n && a.name == b.name && a.status == b.status && a.id == b.id
    }
}

/// One picked item before it is a chip: its bytes, a name to show, and whether
/// the picker knew it as a picture.
struct PickedAttachment: Sendable {
    var data: Data
    var name: String
    var isImage: Bool

    /// The names a pick goes by on the computer: they are file names the agent
    /// reads, not words for the person, so they are the same in every language.
    static let pastedName = "Pasted image.png" // non-copy: a file name the agent reads
    static func photoName(_ n: Int, _ ext: String?) -> String { "Photo \(n).\(ext ?? "jpg")" }

    /// A HEIC photo becomes a JPEG here; everything else goes as it is.
    func normalised() -> PickedAttachment {
        guard isImage, AttachmentRules.isHEIC(data), let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return self }
        let stem = (name as NSString).deletingPathExtension
        return PickedAttachment(data: jpeg, name: (stem.isEmpty ? "Photo" : stem) + ".jpg", isImage: true) // non-copy: a file name
    }
}

/// ATTACH-1. The chips above one composer. A store owns one and tells it how
/// to read and write its draft; the surface draws `chips` and `notice`.
///
/// A pick becomes a chip and a marker at once, then uploads — one at a time,
/// in pick order — with its progress on the chip. Removing a chip takes its
/// marker out of the draft and its file off the computer. A send that landed
/// clears the chips (the files stay for the agent; core sweeps them after
/// seven days).
@MainActor final class AttachmentTray: ObservableObject {
    @Published private(set) var chips: [AttachmentChip] = []
    @Published var notice: String?
    private var next = 1
    private var queue: Task<Void, Never>?
    private var tasks: [Int: Task<Void, Never>] = [:]
    private let uploader: @MainActor () throws -> any AttachmentUploading
    private let target: @MainActor () -> UploadTarget
    private let readDraft: @MainActor () -> String
    private let writeDraft: @MainActor (String) -> Void

    init(uploader: @escaping @MainActor () throws -> any AttachmentUploading,
         target: @escaping @MainActor () -> UploadTarget,
         readDraft: @escaping @MainActor () -> String, writeDraft: @escaping @MainActor (String) -> Void) {
        self.uploader = uploader
        self.target = target
        self.readDraft = readDraft
        self.writeDraft = writeDraft
    }

    var isUploading: Bool { chips.contains(where: \.isUploading) }
    var hasReady: Bool { chips.contains { $0.status == .ready } }
    var isEmpty: Bool { chips.isEmpty }
    /// What Send carries: the uploaded chips, in order, with their markers.
    var refs: [AttachmentRef] { chips.compactMap { chip in chip.id.map { AttachmentRef(id: $0, marker: chip.marker) } } }
    var readyImageCount: Int { chips.filter { $0.kind == .image && $0.status == .ready }.count }
    func markerMissing(_ chip: AttachmentChip) -> Bool { !readDraft().contains(chip.marker) }

    func add(_ items: [PickedAttachment]) {
        var draft = readDraft()
        var added: [(AttachmentChip, PickedAttachment)] = []
        for raw in items {
            if chips.count + added.count >= AttachmentRules.maximumChips {
                notice = AttachmentRules.sentence(.tooMany, name: "")
                break
            }
            let item = raw.normalised()
            if let refusal = AttachmentRules.refusal(name: item.name, size: item.data.count, isImage: item.isImage) {
                notice = AttachmentRules.sentence(refusal, name: item.name)
                continue
            }
            let kind = AttachmentRules.kind(name: item.name, isImage: item.isImage)
            var chip = AttachmentChip(n: next, kind: kind, name: item.name, status: .uploading(0), id: nil, thumbnail: nil)
            next += 1
            if kind == .image { chip.thumbnail = UIImage(data: item.data)?.preparingThumbnail(of: CGSize(width: 96, height: 96)) }
            draft = AttachmentRules.insert(chip.marker, into: draft)
            added.append((chip, item))
        }
        guard !added.isEmpty else { return }
        chips.append(contentsOf: added.map(\.0))
        writeDraft(draft)
        for (chip, item) in added { enqueue(chip, item) }
    }

    private func enqueue(_ chip: AttachmentChip, _ item: PickedAttachment) {
        let previous = queue
        let place = target()
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.chips.contains(where: { $0.n == chip.n }) else { return }
            do {
                let uploader = try self.uploader()
                let n = chip.n
                let done = try await uploader.upload(item.data, name: item.name, target: place) { [weak tray = self] fraction in
                    Task { @MainActor in tray?.progressed(n, fraction) }
                }
                guard self.chips.contains(where: { $0.n == chip.n }), !Task.isCancelled else {
                    try? await uploader.deleteUpload(id: done.id)
                    return
                }
                self.update(chip.n) { $0.status = .ready; $0.id = done.id; $0.name = done.name.isEmpty ? $0.name : done.name }
            } catch is CancellationError {
                return
            } catch {
                guard let gone = self.chips.first(where: { $0.n == chip.n }) else { return }
                self.chips.removeAll { $0.n == chip.n }
                self.writeDraft(AttachmentRules.remove(gone.marker, from: self.readDraft()))
                let code = (error as? AttachmentUploadError)?.code
                self.notice = AttachmentRules.sentence(AttachmentRules.refusal(code: code), name: chip.name)
            }
            self.tasks[chip.n] = nil
        }
        tasks[chip.n] = task
        queue = task
    }

    /// A progress report can arrive after the upload finished; it never takes
    /// a chip back from ready.
    private func progressed(_ n: Int, _ fraction: Double) {
        update(n) { if $0.isUploading { $0.status = .uploading(fraction) } }
    }

    private func update(_ n: Int, _ change: (inout AttachmentChip) -> Void) {
        guard let index = chips.firstIndex(where: { $0.n == n }) else { return }
        change(&chips[index])
    }

    func remove(_ n: Int) {
        guard let chip = chips.first(where: { $0.n == n }) else { return }
        tasks[n]?.cancel()
        tasks[n] = nil
        chips.removeAll { $0.n == n }
        writeDraft(AttachmentRules.remove(chip.marker, from: readDraft()))
        if let id = chip.id { forget(id) }
    }

    /// A send landed: the files are the agent's now; numbering starts again.
    func clear() {
        chips = []
        next = 1
        notice = nil
    }

    /// Walking away from this draft (another pane, another host): its files go.
    func discard() {
        for chip in chips {
            tasks[chip.n]?.cancel()
            if let id = chip.id { forget(id) }
        }
        tasks = [:]
        chips = []
        next = 1
    }

    private func forget(_ id: String) {
        guard let uploader = try? uploader() else { return }
        Task { try? await uploader.deleteUpload(id: id) }
    }

    func say(_ text: String) { notice = text }
}

/// STORE-6 §A: the demo has no computer; a pick "uploads" at once, so the
/// chips can be seen and taken off, and a send says it is the demo's.
struct DemoAttachmentUploader: AttachmentUploading {
    func upload(_ data: Data, name: String, target: UploadTarget,
                progress: @escaping @Sendable (Double) -> Void) async throws -> UploadedFile {
        progress(1)
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return UploadedFile(id: id, name: name, kind: "image", bytes: data.count,
                            path: "/demo/uploads/" + id) // non-copy: a demo path, never shown
    }
    func deleteUpload(id: String) async throws {}
}
