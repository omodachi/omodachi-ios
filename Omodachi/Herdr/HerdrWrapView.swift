import UIKit

/// HERDR-8: draws `HerdrWrap`'s blocks — the pane's screen as text at the
/// App's terminal size, soft-wrapped to this view's width, newest line at the
/// bottom.
///
/// Text is one selectable `UITextView` per run of text blocks, so a person can
/// select and copy from the mirror; a link (the program's own OSC 8 mark, or
/// an address or path `LinkDetector` finds in the joined line) opens on a tap,
/// through the same router as the grid's. A wide block is a horizontal scroll
/// view of its own, so a table pans sideways without the page doing so.
///
/// The view follows the bottom while it is there; scrolled up to read, it
/// stays put. While text is selected, new frames wait, so a selection is not
/// pulled out from under the finger.
@MainActor final class HerdrWrapView: UIScrollView, UITextViewDelegate, UIGestureRecognizerDelegate {
    var onDoubleTap: (() -> Void)?
    var onSingleTap: (() -> Void)?
    /// A link's raw text, as `LinkTarget.classify` takes it.
    var onLink: ((String) -> Void)?

    let fontSize: CGFloat
    private let stack = UIStackView()
    private var segments: [UIView] = []
    private var links: [String] = []
    private var pending: HerdrWrapResult?
    private(set) var shown: HerdrWrapResult?
    private var followsBottom = true
    static let inset: CGFloat = 8
    static let linkScheme = "omodachi-mirror" // non-copy: an internal URL scheme

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = true
        contentInsetAdjustmentBehavior = .never
        keyboardDismissMode = .none
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: Self.inset / 2),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -Self.inset),
            stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor),
        ])
        accessibilityIdentifier = "herdr-wrap" // non-copy
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        double.numberOfTapsRequired = 2
        double.delegate = self
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        single.require(toFail: double)
        single.cancelsTouchesInView = false
        single.delegate = self
        addGestureRecognizer(single)
        // HERDR-10: a finger resting on the text is starting a selection.
        // While codex works its screen changes every few frames, and each
        // change used to replace the text under that finger, so the press
        // never became a selection ("can't copy in a codex pane"). Frames
        // wait while the finger is down, and while a selection is up.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.15
        press.cancelsTouchesInView = false
        press.delaysTouchesBegan = false
        press.delegate = self
        addGestureRecognizer(press)
        delegate = nil
    }

    /// A finger is down on the text (or just lifted from it).
    private(set) var touchHeld = false
    private var releaseTask: Task<Void, Never>?

    @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            releaseTask?.cancel(); releaseTask = nil
            touchHeld = true
        case .ended, .cancelled, .failed:
            // The selection the press made lands a moment after the finger
            // lifts; wait for it before letting frames through.
            releaseTask?.cancel()
            releaseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, !Task.isCancelled else { return }
                self.touchHeld = false
                self.flushPending()
            }
        default:
            break
        }
    }

    private func flushPending() {
        if let pending, !holding { show(pending) }
        reportHeld()
    }

    /// Frames wait: a selection is up, a finger is making one, or the reader
    /// scrolled up to read (HERDR-10, Collie's reading mirror holds still;
    /// "New output ↓" brings it back).
    var holding: Bool { hasSelection || touchHeld || !followsBottom }

    /// Told whether newer output is waiting behind a held screen.
    var onNewOutput: ((Bool) -> Void)?
    private var reportedHeld = false
    private func reportHeld() {
        let held = pending != nil && holding
        guard held != reportedHeld else { return }
        reportedHeld = held
        onNewOutput?(held)
    }

    /// "New output ↓": let go of the selection, show the newest screen and
    /// follow the bottom again.
    func jumpToNewest() {
        releaseTask?.cancel(); releaseTask = nil
        touchHeld = false
        clearSelection()
        followsBottom = true
        if let pending { self.pending = nil; showNow(pending) }
        scrollToBottom()
        reportHeld()
    }

    /// HERDR-10: another pane (or session) is on show. Its text must never
    /// be the last pane's: the old blocks, a held frame and any selection
    /// go, and the view waits, empty, for the new pane's first frame. (A
    /// selection left in the old text used to hold every new frame back, so
    /// Wrap kept showing the tab Leo had left.)
    func reset() {
        releaseTask?.cancel(); releaseTask = nil
        touchHeld = false
        clearSelection()
        pending = nil
        shown = nil
        links = []
        for segment in segments { segment.removeFromSuperview() }
        segments = []
        followsBottom = true
        setContentOffset(.zero, animated: false)
        reportHeld()
    }

    /// Drop any selection (the mirror is about to show a fresh screen).
    func clearSelection() {
        for case let view as UITextView in segments where view.selectedRange.length > 0 {
            view.selectedRange = NSRange(location: 0, length: 0)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") } // non-copy

    @objc private func doubleTapped() { onDoubleTap?() }
    @objc private func singleTapped() { onSingleTap?() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: - Width

    /// One column of the terminal face at `fontSize`.
    var cellWidth: CGFloat {
        let font = HerdrWrapStyle.faces(fontSize).normal
        return max(1, ("M" as NSString).size(withAttributes: [.font: font]).width) // non-copy: a measuring glyph
    }

    /// How many columns of text fit across, which is what `HerdrWrap.layout`
    /// cuts rules and judges tables against.
    var columns: Int {
        guard bounds.width > 0 else { return 40 }
        return max(8, Int((bounds.width - 2 * Self.inset) / cellWidth))
    }

    private var laidOutWidth: CGFloat = 0
    /// Told when the width (and so the column count) changed.
    var onWidthChanged: (() -> Void)?

    private var laidOutHeight: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - laidOutWidth) > 0.5 {
            laidOutWidth = bounds.width
            onWidthChanged?()
        }
        // HERDR-9: the keyboard came up (or went away). Only the height
        // changed, so the text keeps its wrapping; a reader at the bottom
        // stays at the bottom, where the pane's input line is.
        if abs(bounds.height - laidOutHeight) > 0.5 {
            laidOutHeight = bounds.height
            if followsBottom {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.followsBottom else { return }
                    self.scrollToBottom()
                }
            }
        }
    }

    // MARK: - Content

    /// Show `result`. Held back while a selection is up; following the bottom
    /// if the reader was there.
    func show(_ result: HerdrWrapResult) {
        if holding {
            if result != shown { pending = result }
            reportHeld()
            return
        }
        pending = nil
        showNow(result)
        reportHeld()
    }

    private func showNow(_ result: HerdrWrapResult) {
        guard result != shown else { return }
        let atBottom = followsBottom || isNearBottom
        shown = result
        rebuild(result.blocks)
        if atBottom { scrollToBottom() }
    }

    /// The theme or the faces changed: draw the same blocks again.
    func restyle() {
        guard let shown else { return }
        self.shown = nil
        showNow(shown)
    }

    var hasSelection: Bool {
        segments.contains { ($0 as? UITextView).map { $0.selectedRange.length > 0 } ?? false }
    }

    private var isNearBottom: Bool {
        contentOffset.y + bounds.height >= contentSize.height - HerdrWrapStyle.faces(fontSize).normal.lineHeight * 2
    }

    func scrollToBottom() {
        layoutIfNeeded()
        let bottom = max(0, contentSize.height - bounds.height)
        setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        followsBottom = true
    }

    override var contentOffset: CGPoint {
        didSet {
            guard isTracking || isDecelerating else { return }
            readerMoved()
        }
    }

    /// The reader moved the text by hand: following the bottom is whether
    /// they are at it; back at the bottom, the held screen catches up.
    func readerMoved() {
        let was = followsBottom
        followsBottom = isNearBottom
        if followsBottom, !was {
            DispatchQueue.main.async { [weak self] in self?.flushPending() }
        } else if !followsBottom, was {
            reportHeld()
        }
    }

    private enum Piece { case text([HerdrWrapBlock]), wide([[HerdrRun]]) }

    private func rebuild(_ blocks: [HerdrWrapBlock]) {
        var pieces: [Piece] = []
        var run: [HerdrWrapBlock] = []
        for block in blocks {
            if case .wide(let rows) = block {
                if !run.isEmpty { pieces.append(.text(run)); run = [] }
                pieces.append(.wide(rows))
            } else {
                run.append(block)
            }
        }
        if !run.isEmpty { pieces.append(.text(run)) }

        links = []
        let style = HerdrWrapStyle(fontSize: fontSize, cellWidth: cellWidth)
        for (index, piece) in pieces.enumerated() {
            switch piece {
            case .text(let blocks):
                let view = textView(at: index)
                let text = style.attributed(blocks, links: &links)
                if view.attributedText != text { view.attributedText = text }
            case .wide(let rows):
                let (scroller, label) = wideView(at: index)
                label.attributedText = style.attributedRows(rows, links: &links)
                let size = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
                label.frame = CGRect(x: Self.inset, y: 0, width: size.width, height: size.height)
                scroller.contentSize = CGSize(width: size.width + 2 * Self.inset, height: size.height)
                scroller.heightConstraint?.constant = size.height + 2
            }
        }
        while segments.count > pieces.count {
            segments.removeLast().removeFromSuperview()
        }
    }

    private func textView(at index: Int) -> UITextView {
        if index < segments.count, let view = segments[index] as? UITextView { return view }
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 0, left: Self.inset, bottom: 0, right: Self.inset)
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue]
        view.delegate = self
        view.accessibilityIdentifier = "herdr-wrap-text" // non-copy
        place(view, at: index)
        return view
    }

    private func wideView(at index: Int) -> (HerdrWideScroller, UILabel) {
        if index < segments.count, let scroller = segments[index] as? HerdrWideScroller { return (scroller, scroller.label) }
        let scroller = HerdrWideScroller()
        place(scroller, at: index)
        return (scroller, scroller.label)
    }

    private func place(_ view: UIView, at index: Int) {
        if index < segments.count {
            stack.removeArrangedSubview(segments[index])
            segments[index].removeFromSuperview()
            segments[index] = view
        } else {
            segments.append(view)
        }
        stack.insertArrangedSubview(view, at: index)
    }

    // MARK: - UITextViewDelegate

    func textViewDidChangeSelection(_ textView: UITextView) {
        if textView.selectedRange.length == 0, !holding { flushPending() }
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, url.scheme == Self.linkScheme,
              let index = Int(url.lastPathComponent), links.indices.contains(index) else { return defaultAction }
        let raw = links[index]
        return UIAction { [weak self] _ in self?.onLink?(raw) }
    }

    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                  defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        guard case .link(let url) = textItem.content, url.scheme == Self.linkScheme else {
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }
        return nil
    }
}

/// A wide block: its own horizontal pan, never the page's.
final class HerdrWideScroller: UIScrollView {
    let label = UILabel()
    private(set) var heightConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = true
        isDirectionalLockEnabled = true
        label.numberOfLines = 0
        label.lineBreakMode = .byClipping
        addSubview(label)
        let height = heightAnchor.constraint(equalToConstant: 20)
        height.isActive = true
        heightConstraint = height
        accessibilityIdentifier = "herdr-wrap-wide" // non-copy
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") } // non-copy
}

/// Colours and faces for the wrap view: the host theme's terminal palette and
/// the host's terminal faces, the same the grid draws with.
@MainActor struct HerdrWrapStyle {
    let fontSize: CGFloat
    let cellWidth: CGFloat
    private let faces: TerminalFont.Faces
    private let palette: [UIColor]
    private let foreground: UIColor
    private let background: UIColor
    private let caret: UIColor

    static func faces(_ size: CGFloat) -> TerminalFont.Faces { TerminalFont.faces(size: size, fonts: OmodachiTheme.fonts) }

    init(fontSize: CGFloat, cellWidth: CGFloat, theme: HostTheme = OmodachiTheme.current) {
        self.fontSize = fontSize
        self.cellWidth = cellWidth
        faces = Self.faces(fontSize)
        palette = TerminalPalette.ansi(theme).map { UIColor(rgb: $0) }
        foreground = UIColor(rgb: TerminalPalette.foreground(theme))
        background = UIColor(rgb: TerminalPalette.background(theme))
        caret = UIColor(rgb: TerminalPalette.cursor(theme))
    }

    /// Text, rules and blank lines, one paragraph each.
    func attributed(_ blocks: [HerdrWrapBlock], links: inout [String]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakStrategy = []
            let line: NSMutableAttributedString
            switch block {
            case .text(let runs, let indent):
                line = attributed(runs, links: &links, detect: true)
                paragraph.lineBreakMode = .byWordWrapping
                paragraph.headIndent = CGFloat(indent) * cellWidth
            case .rule(let runs):
                line = attributed(runs, links: &links, detect: false)
                paragraph.lineBreakMode = .byClipping
            case .wide:
                continue
            case .blank:
                line = NSMutableAttributedString(string: " ", attributes: base)
            }
            if index < blocks.count - 1 { line.append(NSAttributedString(string: "\n", attributes: base)) }
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            result.append(line)
        }
        return result
    }

    /// A wide block's rows, as they are.
    func attributedRows(_ rows: [[HerdrRun]], links: inout [String]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, runs) in rows.enumerated() {
            result.append(attributed(runs, links: &links, detect: false))
            if index < rows.count - 1 { result.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        return result
    }

    private var base: [NSAttributedString.Key: Any] { [.font: faces.normal, .foregroundColor: foreground] }

    private func attributed(_ runs: [HerdrRun], links: inout [String], detect: Bool) -> NSMutableAttributedString {
        let line = NSMutableAttributedString()
        for run in runs {
            line.append(NSAttributedString(string: run.text, attributes: attributes(run, links: &links)))
        }
        if detect {
            // An address or a path in the joined line — including one the
            // desk's terminal cut at the edge — is a link too.
            let plain = line.string
            for match in LinkDetector.detect(in: plain, bareNames: true) {
                let range = NSRange(match.range, in: plain)
                var marked = false
                line.enumerateAttribute(.link, in: range) { value, _, _ in if value != nil { marked = true } }
                guard !marked, LinkTarget.classify(match.text) != nil else { continue }
                line.addAttribute(.link, value: url(for: match.text, links: &links), range: range)
            }
        }
        return line
    }

    private func url(for raw: String, links: inout [String]) -> URL {
        links.append(raw)
        return URL(string: HerdrWrapView.linkScheme + "://link/\(links.count - 1)")! // non-copy: an internal URL
    }

    private func attributes(_ run: HerdrRun, links: inout [String]) -> [NSAttributedString.Key: Any] {
        let style = run.style
        let font: UIFont = switch (style.bold, style.italic) {
        case (true, true): faces.boldItalic
        case (true, false): faces.bold
        case (false, true): faces.italic
        case (false, false): faces.normal
        }
        var fg = color(style.foreground, standard: foreground)
        var bg: UIColor? = style.background == .standard ? nil : color(style.background, standard: background)
        if style.inverse {
            let swapped = bg ?? background
            bg = fg
            fg = swapped
        }
        // HERDR-10 (Collie's rule): a TUI's dimmed frame - box drawing,
        // rules - keeps its colour; dimmed at 0.6 on a phone it all but
        // disappears. Dimmed words stay dimmed.
        if style.dim, !run.text.allSatisfy({ HerdrWrap.isBoxCharacter(String($0)) || $0 == " " }) {
            fg = fg.withAlphaComponent(0.6)
        }
        if run.cursor {
            bg = caret
            fg = background
        }
        var result: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        if let bg { result[.backgroundColor] = bg }
        if style.underline { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strike { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link, LinkTarget.classify(link) != nil { result[.link] = url(for: link, links: &links) }
        return result
    }

    /// The 256-colour palette: the theme's sixteen, xterm's cube and greys.
    func color(_ value: HerdrCellStyle.Color, standard: UIColor) -> UIColor {
        switch value {
        case .standard:
            return standard
        case .rgb(let red, let green, let blue):
            return UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        case .ansi(let code):
            if Int(code) < palette.count { return palette[Int(code)] }
            if code >= 232 {
                let level = (8 + 10 * CGFloat(code - 232)) / 255
                return UIColor(red: level, green: level, blue: level, alpha: 1)
            }
            let index = Int(code) - 16
            func level(_ value: Int) -> CGFloat { value == 0 ? 0 : CGFloat(55 + 40 * value) / 255 }
            return UIColor(red: level(index / 36), green: level((index / 6) % 6), blue: level(index % 6), alpha: 1)
        }
    }
}
