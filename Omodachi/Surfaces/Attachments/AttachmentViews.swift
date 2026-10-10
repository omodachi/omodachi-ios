import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// ATTACH-1. The paperclip beside a composer, and the chips above it.
///
/// The paperclip is a menu: Photos (the library, several at once), Files (the
/// Files app, so a `.py` or a PDF), and — when the clipboard holds a picture —
/// Paste image. A pick becomes a chip at once and uploads with its progress on
/// the chip; a refusal is said in words under the chips. Odomo draws the same
/// three things (`odomo/src/panels/Attachments.jsx`).
struct AttachButton: View {
    @ObservedObject var tray: AttachmentTray
    var enabled = true
    var identifier: String
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            LabelledMenuItem(title: Strings.attachPhotos, symbol: "photo.on.rectangle") { choosingPhotos = true }
                .accessibilityIdentifier("\(identifier)-photos")
            LabelledMenuItem(title: Strings.attachFiles, symbol: "folder") { choosingFiles = true } // non-copy: a glyph name
                .accessibilityIdentifier("\(identifier)-files")
            LabelledMenuItem(title: Strings.attachPaste, symbol: "doc.on.clipboard") { pasteImage() }
                .accessibilityIdentifier("\(identifier)-paste")
        } label: {
            // Inside the composer's own box, at its leading edge: no border of
            // its own, the 44 a finger needs.
            Glyph(Icon.attach)
                .foregroundStyle(enabled ? OmodachiTheme.text : OmodachiTheme.secondaryText)
                .frame(width: 40, height: NativeBarMetrics.hit)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .disabled(!enabled)
        .accessibilityLabel(Strings.attachButton)
        .accessibilityIdentifier(identifier)
        .photosPicker(isPresented: $choosingPhotos, selection: $photos,
                      maxSelectionCount: AttachmentRules.maximumChips, matching: .images)
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: AttachmentRules.fileTypes,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            tray.add(AttachmentLoading.files(urls, refuse: { tray.say($0) }))
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task { tray.add(await AttachmentLoading.photos(items)) }
        }
    }

    /// The clipboard's picture, read only now that the person asked for it
    /// (iOS asks them once whether this app may paste).
    private func pasteImage() {
        guard let image = UIPasteboard.general.image, let data = image.pngData() else {
            tray.say(Strings.attachPasteNone)
            return
        }
        tray.add([PickedAttachment(data: data, name: PickedAttachment.pastedName, isImage: true)])
    }
}

/// Reading what a picker handed over, off the main actor where it can be.
enum AttachmentLoading {
    static func photos(_ items: [PhotosPickerItem]) async -> [PickedAttachment] {
        var picked: [PickedAttachment] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension
            picked.append(PickedAttachment(data: data, name: PickedAttachment.photoName(index + 1, ext), isImage: true))
        }
        return picked
    }

    /// A file that is plainly too big is refused by its size, before it is read.
    @MainActor static func files(_ urls: [URL], refuse: (String) -> Void) -> [PickedAttachment] {
        var picked: [PickedAttachment] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > AttachmentRules.maximumBytes {
                refuse(AttachmentRules.sentence(.tooLarge, name: name))
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                refuse(AttachmentRules.sentence(.failed, name: name))
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension)
            picked.append(PickedAttachment(data: data, name: name,
                                           isImage: type?.conforms(to: .image) == true && type?.conforms(to: .svg) != true))
        }
        return picked
    }
}

/// The chips: a 40×40 thumbnail for a picture, a tile for a file, its `#N`,
/// the name or how far its upload got, and an × with a 44 hit area. A chip
/// whose marker was edited out of the text is drawn dashed and says Send will
/// put it first (Collie ADR 0060 §7).
struct AttachmentChipStrip: View {
    @ObservedObject var tray: AttachmentTray
    var identifier: String

    var body: some View {
        if !tray.chips.isEmpty || tray.notice != nil {
            VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
                if let notice = tray.notice { noticeRow(notice) }
                if !tray.chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: OmodachiTheme.space("md")) {
                            ForEach(tray.chips, id: \.n) { chip in chipView(chip) }
                        }
                        .padding(.horizontal, OmodachiTheme.panelPadding)
                    }
                    .accessibilityIdentifier(identifier)
                }
            }
            .padding(.top, OmodachiTheme.space("md"))
        }
    }

    @ViewBuilder private func chipView(_ chip: AttachmentChip) -> some View {
        let loose = chip.status == .ready && tray.markerMissing(chip)
        HStack(spacing: OmodachiTheme.space("md")) {
            Group {
                if let thumbnail = chip.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Glyph(symbol: chip.kind == .image ? "photo" : "doc.text").foregroundStyle(OmodachiTheme.secondaryText)
                }
            }
            .frame(width: 40, height: 40)
            .background(OmodachiTheme.normalFill)
            .clipped()
            .opacity(chip.isUploading ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(loose ? chip.label + " ←" : chip.label)
                    .font(OmodachiTheme.font("caption", weight: .semibold))
                    .foregroundStyle(OmodachiTheme.accent)
                Text(caption(chip))
                    .font(OmodachiTheme.font("caption"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: 140, alignment: .leading)
            Tap(action: { tray.remove(chip.n) }) {
                Glyph(Icon.close, step: "icon-small")
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .frame(width: 36, height: NativeBarMetrics.hit)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Strings.attachRemove(chip.name))
            .accessibilityIdentifier("\(identifier)-remove-\(chip.n)")
        }
        .padding(.leading, OmodachiTheme.space("sm"))
        .frame(height: 52)
        .overlay(alignment: .bottomLeading) {
            if case .uploading(let fraction) = chip.status {
                GeometryReader { box in
                    Rectangle().fill(OmodachiTheme.accent).frame(width: box.size.width * fraction, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .accessibilityHidden(true)
            }
        }
        .overlay(
            Rectangle().strokeBorder(loose ? OmodachiTheme.warning : OmodachiTheme.controlBorder,
                                     style: StrokeStyle(lineWidth: OmodachiTheme.controlBorderWidth, dash: loose ? [4, 3] : []))
                .allowsHitTesting(false))
        .accessibilityElement(children: .combine)
        .accessibilityHint(loose ? Strings.attachMarkerGone : "")
        .accessibilityIdentifier("\(identifier)-\(chip.n)")
    }

    private func caption(_ chip: AttachmentChip) -> String {
        if case .uploading(let fraction) = chip.status { return Strings.attachUploading(Format.percent(fraction)) }
        return chip.name
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: OmodachiTheme.space("lg")) {
            Text(text).font(OmodachiTheme.bodyFont("body-small")).foregroundStyle(OmodachiTheme.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
            Tap(action: { tray.notice = nil }) {
                Glyph(Icon.close, step: "icon-small").frame(width: NativeBarMetrics.hit, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel(Strings.actionDismiss)
        }
        .padding(.leading, OmodachiTheme.panelPadding)
        .accessibilityIdentifier("\(identifier)-notice")
    }
}

/// A user row's pictures: core counts them, the row says how many.
struct AgentMessagePictures: View {
    let count: Int
    var body: some View {
        HStack(spacing: OmodachiTheme.space("sm")) {
            Glyph(symbol: "photo", points: OmodachiTheme.fontSize("caption"))
            Text(count == 1 ? Strings.attachPicture : Strings.attachPictures(Format.count(count)))
        }
        .font(OmodachiTheme.font("caption"))
        .foregroundStyle(OmodachiTheme.secondaryText)
        .accessibilityElement(children: .combine)
    }
}
