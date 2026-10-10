import SwiftTerm
import UIKit

/// HERDR-4: fit to width, without ever touching the pane's size.
///
/// HERDR-3 measured that `observe` at the phone's size *truncates* a wide
/// desktop pane: Herdr cuts each row at the requested columns, so a 160-column
/// Claude pane showed its left 46 columns on an iPhone. The cure is not to ask
/// the computer for a smaller pane (that would be `control`, and it resizes the
/// shared PTY); it is to watch the pane at its own size and draw it smaller.
///
/// So the terminal view is laid out at the pane's own columns and rows in the
/// host face at `HerdrStore.fontSize` — exactly the size SwiftTerm needs to
/// hold that grid — and this scroll view zooms it:
///
/// * **Fit** scales it to the panel's width, but never below a readable
///   minimum (`readablePoints`); a pane wider than that pans sideways.
/// * **1:1** is the host face at its own size, panning both ways.
/// * A pinch goes anywhere between the whole pane at once and 1.6×; a double
///   tap toggles fit and 1:1.
///
/// After a zoom settles, the terminal's layer is re-rendered at the scale it
/// is shown at (`contentScaleFactor`), so small text is drawn crisp instead of
/// being a shrunk bitmap — and a big pane shown small costs less memory.
///
/// With no pane size (Take keyboard, or a pane Herdr has not laid out yet) the
/// terminal simply fills the view at 1:1, which is what `control` resizes the
/// PTY to.
final class HerdrFitView: UIScrollView, UIScrollViewDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    enum Zoom: Equatable, Sendable {
        case fit, actual, custom
    }

    /// The smallest type "fit" goes to, in points of the host face. Below it a
    /// wide pane pans sideways instead of shrinking further.
    static let readablePoints: CGFloat = 7
    static let maximumZoom: CGFloat = 1.6

    let terminal: HerdrTerminalView
    private(set) var paneSize: (cols: Int, rows: Int)?
    private(set) var zoomMode: Zoom = .fit
    /// Told when the zoom settles: what it is and the scale it settled at.
    var onZoomChanged: ((Zoom, CGFloat) -> Void)?
    /// HERDR-5: one tap that was not the first half of a double tap, and
    /// (LINKS-1) where it landed on the terminal, to open a link there.
    var onSingleTap: ((CGPoint) -> Void)?
    /// HERDR-8: a double tap goes to the store, which steps the mirror
    /// through Wrap, Fit and Actual; without one it toggles fit and 1:1.
    var onDoubleTap: ((CGPoint) -> Void)?
    private var anchorBottom = true
    private var doubleTap: UITapGestureRecognizer!
    private let simultaneous = HerdrSimultaneousTaps()

    init(terminal: HerdrTerminalView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        delegate = self
        bouncesZoom = true
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        isDirectionalLockEnabled = true
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = true
        decelerationRate = .fast
        addSubview(terminal)
        accessibilityIdentifier = "herdr-fit" // non-copy
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        tap.numberOfTapsRequired = 2
        addGestureRecognizer(tap)
        doubleTap = tap
        tap.delegate = simultaneous
        // SwiftTerm's own taps (a single tap that focuses, a double tap that
        // selects a word) wait for this one: on a mirror the double tap is
        // the zoom toggle, and a single tap would otherwise claim the touch.
        for recognizer in terminal.gestureRecognizers ?? [] where recognizer is UITapGestureRecognizer {
            recognizer.require(toFail: tap)
        }
        // HERDR-5: a single tap waits for the double tap to fail, so a zoom is
        // never also a "put the keyboard away"; it never cancels SwiftTerm's.
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
        single.require(toFail: tap)
        single.cancelsTouchesInView = false
        single.delegate = simultaneous
        addGestureRecognizer(single)
        // HERDR-10: select and copy from the grid. SwiftTerm's own long
        // press asks to become the first responder - which a read-only
        // mirror refuses unless Type is on - and then offers Paste; so it
        // is off, and this one selects the word under the finger, extends
        // as the finger moves, and shows the system edit menu: Copy and
        // Select All.
        for recognizer in terminal.gestureRecognizers ?? [] where recognizer is UILongPressGestureRecognizer {
            recognizer.isEnabled = false
        }
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.4
        // Alongside the terminal's own recognizers (on an iPad SwiftTerm
        // claims a long press of its own), never after them.
        press.delegate = simultaneous
        press.allowedTouchTypes = [UITouch.TouchType.direct, .indirect, .indirectPointer, .pencil].map { NSNumber(value: $0.rawValue) }
        addGestureRecognizer(press)
        // The edit menu lives on a view that takes no touches: on an iPad
        // UIKit backs it with a context-menu interaction whose own long press
        // would otherwise beat the one above.
        menuHost.isUserInteractionEnabled = false
        menuHost.isAccessibilityElement = false
        addSubview(menuHost)
        let menu = UIEditMenuInteraction(delegate: self)
        menuHost.addInteraction(menu)
        editMenu = menu
    }

    private var editMenu: UIEditMenuInteraction?
    private let menuHost = UIView()

    /// The grid cell under `point` (in the terminal's own coordinates).
    func cell(at point: CGPoint) -> Position? {
        guard let cell = cellSize, cell.width > 0, cell.height > 0 else { return nil }
        let grid = terminal.getTerminal()
        let col = min(max(0, Int(point.x / cell.width)), max(0, grid.cols - 1))
        let row = min(max(0, Int(point.y / cell.height)), max(0, grid.rows - 1))
        return Position(col: col, row: row)
    }

    @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: terminal)
        guard let hit = cell(at: point) else { return }
        switch recognizer.state {
        case .began:
            panGestureRecognizer.isEnabled = false
            selectWord(at: hit)
            // Nothing but blanks under the finger: the whole row.
            if (selectedText ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                terminal.selection.select(row: hit.row)
                terminal.setNeedsDisplay()
            }
        case .changed:
            terminal.selection.pivotExtend(bufferPosition: hit)
            terminal.setNeedsDisplay()
        case .ended:
            panGestureRecognizer.isEnabled = true
            showEditMenu(at: recognizer.location(in: self))
        default:
            panGestureRecognizer.isEnabled = true
        }
    }

    /// The word (or path, or address) under `cell`, selected.
    func selectWord(at cell: Position) {
        let selection = terminal.selection!
        selection.selectWordOrExpression(at: cell, in: terminal.getTerminal().buffer)
        selection.selectionMode = .character
        selection.pivot = selection.start
        terminal.setNeedsDisplay()
    }

    /// What is selected on the grid, if anything.
    var selectedText: String? {
        guard terminal.hasActiveSelection, let text = terminal.getSelection(), !text.isEmpty else { return nil }
        return text
    }

    func clearSelection() {
        guard terminal.hasActiveSelection else { return }
        terminal.clearSelection()
        terminal.setNeedsDisplay()
    }

    private func showEditMenu(at point: CGPoint) {
        menuHost.frame = CGRect(origin: .zero, size: CGSize(width: max(contentSize.width, bounds.width),
                                                          height: max(contentSize.height, bounds.height)))
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: convert(point, to: menuHost)))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        let copy = UIAction(title: Strings.herdrCopy, image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            self?.copySelection()
        }
        let all = UIAction(title: Strings.herdrSelectAll) { [weak self] _ in
            guard let self else { return }
            self.terminal.selectAll()
            self.terminal.setNeedsDisplay()
            DispatchQueue.main.async { self.showEditMenu(at: configuration.sourcePoint) }
        }
        return UIMenu(children: selectedText == nil ? [all] : [copy, all])
    }

    /// Copy what is selected, and let the selection go.
    func copySelection() {
        guard let text = selectedText else { return }
        UIPasteboard.general.string = text
        clearSelection()
    }

    @objc private func singleTapped(_ recognizer: UITapGestureRecognizer) {
        // A tap away from a selection puts it away, as in any iOS text.
        if terminal.hasActiveSelection {
            clearSelection()
            return
        }
        onSingleTap?(recognizer.location(in: terminal))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") } // non-copy

    // MARK: - Geometry

    /// The pane's own size (fit-to-width) or nil (fill the view at 1:1).
    func setPaneSize(_ size: (cols: Int, rows: Int)?) {
        if size?.cols == paneSize?.cols && size?.rows == paneSize?.rows { return }
        let changedShape = (size == nil) != (paneSize == nil)
        paneSize = size
        if changedShape || size == nil {
            zoomMode = .fit
            anchorBottom = true
        }
        setNeedsLayout()
    }

    /// A fresh pane on screen: back to fit, the cursor's row in view.
    func resetZoom() {
        zoomMode = .fit
        anchorBottom = true
        setNeedsLayout()
    }

    /// One cell of the host face at `HerdrStore.fontSize`, read from SwiftTerm.
    var cellSize: CGSize? {
        let grid = terminal.getTerminal()
        let optimal = terminal.getOptimalFrameSize()
        guard grid.cols > 0, grid.rows > 0, optimal.width > 0, optimal.height > 0 else { return nil }
        return CGSize(width: optimal.width / CGFloat(grid.cols), height: optimal.height / CGFloat(grid.rows))
    }

    /// The grid this view holds at 1:1 — what `control` asks for when the
    /// keyboard is taken.
    var fillGeometry: (cols: Int, rows: Int)? {
        guard let cell = cellSize, bounds.width > 0, bounds.height > 0 else { return nil }
        return (max(1, Int(bounds.width / cell.width)), max(1, Int(bounds.height / cell.height)))
    }

    /// The terminal's unscaled size for the pane's grid. Half a cell of slack
    /// keeps SwiftTerm's `Int(width / cell)` on the right side of rounding.
    var naturalSize: CGSize? {
        guard let paneSize, let cell = cellSize else { return nil }
        return CGSize(width: ceil(cell.width * (CGFloat(paneSize.cols) + 0.5)),
                      height: ceil(cell.height * (CGFloat(paneSize.rows) + 0.5)))
    }

    /// The scale "fit" means right now: the panel's width, floored at the
    /// readable minimum, and never larger than 1:1.
    var fitScale: CGFloat {
        guard let natural = naturalSize, natural.width > 0, bounds.width > 0 else { return 1 }
        let width = min(1, bounds.width / natural.width)
        let readable = min(1, Self.readablePoints / HerdrStore.fontSize)
        return max(width, readable)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let natural = naturalSize else {
            // Fill: the terminal is this view, at 1:1.
            if minimumZoomScale != 1 || maximumZoomScale != 1 || zoomScale != 1 {
                minimumZoomScale = 1; maximumZoomScale = 1; zoomScale = 1
            }
            if terminal.frame != CGRect(origin: .zero, size: bounds.size) {
                terminal.transform = .identity
                terminal.frame = CGRect(origin: .zero, size: bounds.size)
            }
            if contentSize != bounds.size { contentSize = bounds.size }
            rerender(at: 1)
            return
        }
        if terminal.bounds.size != natural {
            let scale = zoomScale
            terminal.bounds = CGRect(origin: .zero, size: natural)
            terminal.center = CGPoint(x: natural.width * scale / 2, y: natural.height * scale / 2)
            contentSize = CGSize(width: natural.width * scale, height: natural.height * scale)
        }
        // A pinch may show the whole pane at once, however small.
        let whole = min(1, bounds.width / natural.width, bounds.height / natural.height)
        let minimum = min(whole, fitScale)
        if abs(minimumZoomScale - minimum) > 0.0001 { minimumZoomScale = minimum }
        if maximumZoomScale != Self.maximumZoom { maximumZoomScale = Self.maximumZoom }
        let target: CGFloat? = switch zoomMode {
        case .fit: fitScale
        case .actual: 1
        case .custom: nil
        }
        // Never fight a pinch in progress; the zoom it settles at decides.
        if let target, !isZooming, !isZoomBouncing, abs(zoomScale - target) > 0.0001 {
            setZoomScale(target, animated: false)
        }
        if anchorBottom {
            anchorBottom = false
            revealCursor()
            rerender(at: zoomScale)
        }
        keepBottomOnShrink()
    }

    /// VERIFY-1: when the view gets shorter under the mirror (the Quick dock
    /// opens) the bottom rows stay in view if they were. On the real host the
    /// Quick dock covered codex's approval dialog - the pane's last rows -
    /// while the buttons meant to answer it were showing. A terminal is read
    /// from the bottom: an agent's question and its input line are there, and
    /// codex hides its cursor, so the cursor's row alone cannot be trusted.
    private var shownHeight: CGFloat = 0
    private func keepBottomOnShrink() {
        let previous = shownHeight
        guard abs(bounds.height - previous) > 0.5 else { return }
        shownHeight = bounds.height
        guard previous > 0, bounds.height < previous, naturalSize != nil, let cell = cellSize,
              !isZooming, !isDragging, !isDecelerating else { return }
        let rowHeight = cell.height * zoomScale
        let maximum = max(0, contentSize.height - bounds.height)
        let wasAtBottom = contentOffset.y + previous >= contentSize.height - rowHeight
        if wasAtBottom {
            setContentOffset(CGPoint(x: contentOffset.x, y: maximum), animated: false)
            return
        }
        // Scrolled up to read: keep the cursor's row in view if it was.
        let row = CGFloat(terminal.getTerminal().getCursorLocation().y)
        let bottomOfCursor = (row + 2) * rowHeight
        guard bottomOfCursor <= contentOffset.y + previous + rowHeight,
              bottomOfCursor > contentOffset.y + bounds.height else { return }
        setContentOffset(CGPoint(x: contentOffset.x, y: min(maximum, bottomOfCursor - bounds.height)), animated: false)
    }

    /// The left edge, scrolled so the cursor's row is in view (an agent's
    /// input line is where its cursor is), else the top.
    func revealCursor() {
        guard naturalSize != nil, let cell = cellSize, bounds.height > 0 else { return }
        let row = CGFloat(terminal.getTerminal().getCursorLocation().y)
        let bottomOfCursor = (row + 2) * cell.height * zoomScale
        let maximum = max(0, contentSize.height - bounds.height)
        setContentOffset(CGPoint(x: 0, y: min(maximum, max(0, bottomOfCursor - bounds.height))), animated: false)
    }

    // MARK: - Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        naturalSize == nil ? nil : terminal
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if abs(scale - fitScale) < 0.01 { zoomMode = .fit }
        else if abs(scale - 1) < 0.01 { zoomMode = .actual }
        else { zoomMode = .custom }
        rerender(at: scale)
        onZoomChanged?(zoomMode, scale)
    }

    /// Double tap: fit ↔ 1:1, zooming in around the finger.
    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        if let onDoubleTap {
            onDoubleTap(recognizer.location(in: terminal))
            return
        }
        guard naturalSize != nil else { return }
        toggleZoom(around: recognizer.location(in: terminal))
    }

    /// HERDR-8: go to fit or 1:1 on purpose (the mirror's cycle), zooming
    /// in around `point` when there is one.
    func setZoom(_ target: Zoom, around point: CGPoint? = nil) {
        guard naturalSize != nil else { zoomMode = target; return }
        switch target {
        case .actual where zoomMode != .actual:
            toggleZoom(around: point)
        case .fit, .custom:
            if zoomMode != .fit {
                zoomMode = .fit
                setZoomScale(fitScale, animated: false)
                revealCursor()
                rerender(at: fitScale)
                onZoomChanged?(.fit, fitScale)
            }
        default:
            break
        }
    }

    func toggleZoom(around point: CGPoint? = nil) {
        guard naturalSize != nil else { return }
        defer { onZoomChanged?(zoomMode, zoomMode == .actual ? 1 : fitScale) }
        if zoomMode == .actual {
            zoomMode = .fit
            setZoomScale(fitScale, animated: point != nil)
            if point == nil { revealCursor() }
            rerender(at: fitScale)
        } else {
            zoomMode = .actual
            if let point {
                let size = CGSize(width: bounds.width, height: bounds.height)
                zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                width: size.width, height: size.height), animated: true)
            } else {
                // From the chip: 1:1 at the left edge with the bottom rows in
                // view, where an agent's input line is.
                setZoomScale(1, animated: false)
                revealCursor()
                rerender(at: 1)
            }
        }
    }

    /// The layer drawn at the pixels it is shown with: a shrunk pane is
    /// re-rendered small (crisp, and lighter), not scaled down from 1:1.
    private func rerender(at scale: CGFloat) {
        let screen = window?.screen.scale ?? traitCollection.displayScale
        guard screen > 0 else { return }
        // HERDR-10: rounded up, never down: at Fit on a phone (~0.54×) the
        // nearest quarter was below the pixels the text lands on, and thin
        // grey text came out soft and faded.
        let wanted = max(1, ceil(screen * scale * 4) / 4)
        if abs(terminal.contentScaleFactor - wanted) > 0.01 {
            terminal.contentScaleFactor = wanted
            terminal.setNeedsDisplay()
        }
    }

    /// VoiceOver: the zoom, said in the reader's words.
    override var accessibilityValue: String? {
        get { naturalSize == nil ? nil : (zoomMode == .actual ? Strings.herdrZoomActual : Strings.herdrZoomFit) }
        set {}
    }
}

/// The double tap is looked for alongside SwiftTerm's own recognizers rather
/// than after one of them has claimed the touch.
private final class HerdrSimultaneousTaps: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
