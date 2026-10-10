import Foundation
import UIKit

/// HERDR-8: the three ways the mirror shows a pane, in the order a double tap
/// (or the chip) goes through them. HERDR-12 (Leo): on an iPhone the cycle is
/// Wrap ↔ Fit only; Actual size is the iPad's.
///
/// * **wrap** — the pane's rows as text that fits the phone (`HerdrWrap`).
///   The iPhone's default.
/// * **fit** — the grid at the pane's own size, scaled to the width
///   (`HerdrFitView`). The iPad's default, which was fine all along.
/// * **actual** — the grid at the host face's own size, panned.
enum HerdrMirrorMode: String, CaseIterable, Sendable {
    case wrap, fit, actual

    /// The mode after this one. An iPad goes Fit → Actual → Wrap → Fit; an
    /// iPhone only between Wrap and Fit, so any grid goes on to Wrap there.
    func next(phone: Bool) -> HerdrMirrorMode {
        switch self {
        case .wrap: .fit
        case .fit: phone ? .wrap : .actual
        case .actual: .wrap
        }
    }
}

/// The mode a person last chose, per kind of pane — a shell, or an agent by
/// its name — on this device. A phone and a tablet start where each reads
/// best; a choice is remembered from then on.
@MainActor struct HerdrMirrorPreference {
    let defaults: UserDefaults
    let phone: Bool

    init(defaults: UserDefaults = .standard, phone: Bool? = nil) {
        self.defaults = defaults
        self.phone = phone ?? (UIDevice.current.userInterfaceIdiom == .phone)
    }

    static let shell = "shell" // non-copy: a preference key part
    static func key(_ kind: String) -> String { "omodachi.herdr.mirror." + kind + ".v1" } // non-copy: defaults key

    /// `agent` is `HerdrPaneKind.agentName`, nil for a shell. HERDR-12: a
    /// phone that remembered Actual size (before it left the phone's cycle)
    /// opens that kind on Fit.
    func mode(agent: String?) -> HerdrMirrorMode {
        let stored = defaults.string(forKey: Self.key(agent ?? Self.shell)).flatMap(HerdrMirrorMode.init(rawValue:))
        guard let stored else { return phone ? .wrap : .fit }
        return phone && stored == .actual ? .fit : stored
    }

    func remember(_ mode: HerdrMirrorMode, agent: String?) {
        defaults.set(mode.rawValue, forKey: Self.key(agent ?? Self.shell))
    }
}

/// The mirror's one view: the grid (`HerdrFitView`) and the wrapped text
/// (`HerdrWrapView`) on top of each other, one of them showing. Both stay laid
/// out, so the grid keeps the pane's size while the text is up and switching
/// is instant.
final class HerdrMirrorView: UIView {
    let fit: HerdrFitView
    let wrap: HerdrWrapView

    /// HERDR-10: "New output ↓" over a Wrap screen that holds still while
    /// it is being read or selected; a tap shows the newest and follows it.
    let newOutput = UIButton(type: .system)

    init(fit: HerdrFitView, wrap: HerdrWrapView) {
        self.fit = fit
        self.wrap = wrap
        super.init(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        addSubview(fit)
        addSubview(wrap)
        var config = UIButton.Configuration.filled()
        config.title = Strings.herdrNewOutput
        config.cornerStyle = .capsule
        // The host theme's own pair, as the mirror's text is drawn with.
        config.baseBackgroundColor = UIColor(rgb: TerminalPalette.foreground(OmodachiTheme.current))
        config.baseForegroundColor = UIColor(rgb: TerminalPalette.background(OmodachiTheme.current))
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
            return attributes
        }
        newOutput.configuration = config
        newOutput.isHidden = true
        newOutput.accessibilityIdentifier = "herdr-new-output" // non-copy
        newOutput.addAction(UIAction { [weak wrap] _ in wrap?.jumpToNewest() }, for: .primaryActionTriggered)
        addSubview(newOutput)
        wrap.onNewOutput = { [weak self] held in
            self?.heldOutput = held
        }
        applyVisibility()
    }

    private var heldOutput = false {
        didSet { updatePill() }
    }

    private func updatePill() {
        newOutput.isHidden = !(showsWrap && heldOutput)
        setNeedsLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") } // non-copy

    var showsWrap: Bool = false {
        didSet { applyVisibility() }
    }

    /// HERDR-10: also called from `init`, where `didSet` does not run. It
    /// used to be set only there, so until the first switch to Wrap (never,
    /// on an iPad, whose default is Fit) the empty wrap view lay unhidden over
    /// the grid and took its touches: a long press, a tap on a link, a pan.
    private func applyVisibility() {
        wrap.isHidden = !showsWrap
        fit.isHidden = showsWrap
        fit.accessibilityElementsHidden = showsWrap
        wrap.accessibilityElementsHidden = !showsWrap
        updatePill()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if fit.frame != bounds { fit.frame = bounds }
        if wrap.frame != bounds { wrap.frame = bounds }
        let size = newOutput.sizeThatFits(bounds.size)
        newOutput.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 12,
                                 width: size.width, height: size.height)
        bringSubviewToFront(newOutput)
    }
}
