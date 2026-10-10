import SwiftUI
import UIKit

/// TUTORIAL-1. Where a tour stop can point: any view that names itself with
/// `.tourAnchor(id)` hands its bounds up the tree, and the Shell's overlay
/// reads them back in its own coordinates. Merged rather than replaced, so
/// the whole bar and the slots inside it are all there at once.
struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// TUTORIAL-1: this view is what a tour stop called `id` points at.
    func tourAnchor(_ id: String) -> some View {
        transformAnchorPreference(key: TourAnchorKey.self, value: .bounds) { value, anchor in
            value[id] = anchor
        }
    }
}

/// TUTORIAL-1. One stop of the tour, drawn over the whole window: the
/// theme's scrim with a window cut where the thing is, an accent outline
/// around it, and a callout beside it on the content side of the bar.
///
/// It takes no touch it does not own. The scrim and the outline let every
/// touch through, so a tap on the bar still opens that panel — and the Shell
/// ends the tour when it does. Only the callout itself is hit-testable.
///
/// Dynamic Type: the callout's words are scaled with the person's text size
/// (the rest of the app holds the host's type scale, A-48; a tour that is
/// about reading has to be readable first). At the largest sizes the words
/// scroll inside the callout and the two controls stack.
struct TourSpotlight: View {
    /// The thing being pointed at, in this view's coordinates. `nil` puts the
    /// callout in the middle with no cut.
    let target: CGRect?
    /// Which edge the bar is on: the callout opens away from it.
    let edge: HostBarPosition
    /// The window's own insets (notch, home indicator) the callout keeps clear of.
    let safe: EdgeInsets
    /// Changes once per stop; moves VoiceOver's focus and drives the motion.
    let stepID: String
    let title: String
    let message: String
    /// "2 / 6".
    let progress: String
    /// "Step 2 of 6", for VoiceOver.
    let progressLabel: String
    let nextTitle: String
    let nextIdentifier: String
    /// `nil` on the last stop, where Done is the only way on.
    let skipTitle: String?
    let onNext: () -> Void
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @AccessibilityFocusState private var focused: Bool

    static let margin: CGFloat = 12
    static let gap: CGFloat = 10
    static let maxWidth: CGFloat = 360
    static let scrimOpacity: Double = 0.5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                scrim(size: proxy.size)
                if let target {
                    Rectangle()
                        .strokeBorder(OmodachiTheme.accent, lineWidth: 2)
                        .frame(width: target.width + 6, height: target.height + 6)
                        .position(x: target.midX, y: target.midY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TourCalloutLayout(target: target, edge: edge, safe: safe, margin: Self.margin,
                                  gap: Self.gap, maxWidth: Self.maxWidth) {
                    callout
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: stepID)
        }
        .transition(.opacity)
        .onAppear { focusSoon() }
        .onChange(of: stepID) { _, _ in focusSoon() }
    }

    // MARK: - Scrim

    private func scrim(size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            if let target { path.addRect(target.insetBy(dx: -3, dy: -3)) }
        }
        // Black at half strength, not a theme role: the theme's own scrim and
        // backgrounds are the panels' colour, so over the panels they dim
        // nothing. Like `pictureLetterbox`, this is the absence of light, and
        // it reads the same on a light theme and a dark one.
        .fill(OmodachiTheme.pictureLetterbox.opacity(Self.scrimOpacity), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Callout

    private var callout: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            Text(progress)
                .font(prose(12))
                .foregroundStyle(OmodachiTheme.tertiaryText)
                .accessibilityHidden(true)
                .accessibilityIdentifier("tour-progress")
            ViewThatFits(in: .vertical) {
                words
                ScrollView { words }.scrollBounceBehavior(.basedOnSize)
            }
            controls
        }
        .padding(OmodachiTheme.space("lg"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OmodachiTheme.background)
        .overlay(Rectangle().strokeBorder(OmodachiTheme.popupBorder, lineWidth: OmodachiTheme.popupBorderWidth))
        .overlay(alignment: .leading) {
            Rectangle().fill(OmodachiTheme.accent).frame(width: 3).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tour-card")
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("sm")) {
            Text(title)
                .font(mono(OmodachiTheme.fontSize("subtitle"), weight: .semibold))
                .foregroundStyle(OmodachiTheme.text)
            Text(message)
                .font(prose(OmodachiTheme.fontSize("body")))
                .foregroundStyle(OmodachiTheme.text)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element for VoiceOver: the stop's name and its words, then
        // where in the tour this is. Focus moves here on every stop.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ". " + message)
        .accessibilityValue(progressLabel)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($focused)
        .accessibilityIdentifier("tour-step-" + stepID)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: OmodachiTheme.space("md")) {
                skip
                Spacer(minLength: 0)
                next
            }
            VStack(alignment: .leading, spacing: OmodachiTheme.space("sm")) {
                next
                skip
            }
        }
    }

    @ViewBuilder private var skip: some View {
        if let skipTitle {
            Tap(action: onSkip) {
                Text(skipTitle)
                    .font(mono(OmodachiTheme.fontSize("body-small")))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .padding(.horizontal, OmodachiTheme.space("control-padding-x"))
                    .frame(minHeight: NativeBarMetrics.hit)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("tour-skip")
        }
    }

    private var next: some View {
        Tap(bordered: true, action: onNext) {
            Text(nextTitle)
                .font(mono(OmodachiTheme.fontSize("body-small"), weight: .semibold))
                .foregroundStyle(OmodachiTheme.accent)
                .padding(.horizontal, OmodachiTheme.space("control-padding-x") * 2)
                .frame(minHeight: NativeBarMetrics.hit)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(nextIdentifier)
    }

    // MARK: - Type

    /// The person's text size applied to a point size (`UIFontMetrics`, body).
    private func scaled(_ points: CGFloat) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicType))
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: points, compatibleWith: traits)
    }

    /// The host's monospace for names and controls, as the bar draws them.
    private func mono(_ points: CGFloat, weight: Font.Weight = .regular) -> Font {
        let family = weight == .regular ? OmodachiTheme.fonts.mono : (OmodachiTheme.fonts.monoBold ?? OmodachiTheme.fonts.mono)
        guard let family else { return .system(size: scaled(points), weight: weight, design: .monospaced) }
        return .custom(family, fixedSize: scaled(points)).weight(weight)
    }

    /// The platform face for the sentences (A-07: prose is not monospace).
    private func prose(_ points: CGFloat) -> Font {
        .system(size: scaled(OmodachiTypeScale.size(points: points)))
    }

    private func focusSoon() {
        // After the callout has moved, so VoiceOver reads the new stop rather
        // than the frame it is leaving.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 250))
            focused = true
        }
    }
}

/// TUTORIAL-1. Places the callout next to its target on the content side of
/// the bar, as wide as it may be (at most `maxWidth`), as tall as its words
/// (at most what is left on that side), and slid along the bar so it stays
/// on screen whatever the edge and the orientation.
struct TourCalloutLayout: Layout {
    let target: CGRect?
    let edge: HostBarPosition
    let safe: EdgeInsets
    let margin: CGFloat
    let gap: CGFloat
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let frame = Self.frame(in: bounds.size, target: target, edge: edge, safe: safe, margin: margin, gap: gap,
                               maxWidth: maxWidth) { width, limit in
            card.sizeThatFits(ProposedViewSize(width: width, height: limit)).height
        }
        card.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                   proposal: ProposedViewSize(width: frame.width, height: frame.height))
    }

    /// The callout's frame, worked out without a view so a test can ask.
    /// `height(width, limit)` is how tall the callout wants to be at that
    /// width when it may be at most `limit` tall.
    static func frame(in size: CGSize, target: CGRect?, edge: HostBarPosition, safe: EdgeInsets,
                      margin: CGFloat, gap: CGFloat, maxWidth: CGFloat,
                      height: (CGFloat, CGFloat) -> CGFloat) -> CGRect {
        let left = safe.leading + margin, right = size.width - safe.trailing - margin
        let top = safe.top + margin, bottom = size.height - safe.bottom - margin
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { max(low, min(value, max(low, high))) }
        guard let target else {
            let width = max(0, min(maxWidth, right - left))
            let h = min(height(width, bottom - top), bottom - top)
            return CGRect(x: (size.width - width) / 2, y: (size.height - h) / 2, width: width, height: h)
        }
        switch edge {
        case .top, .bottom:
            let width = max(0, min(maxWidth, right - left))
            let x = clamp(target.midX - width / 2, left, right - width)
            if edge == .top {
                let y = max(top, target.maxY + gap)
                let h = min(height(width, bottom - y), max(0, bottom - y))
                return CGRect(x: x, y: y, width: width, height: h)
            }
            let end = min(bottom, target.minY - gap)
            let h = min(height(width, end - top), max(0, end - top))
            return CGRect(x: x, y: end - h, width: width, height: h)
        case .left, .right:
            let start = edge == .left ? max(left, target.maxX + gap) : left
            let end = edge == .left ? right : min(right, target.minX - gap)
            let width = max(0, min(maxWidth, end - start))
            let x = edge == .left ? start : end - width
            let h = min(height(width, bottom - top), bottom - top)
            let y = clamp(target.midY - h / 2, top, bottom - h)
            return CGRect(x: x, y: y, width: width, height: h)
        }
    }
}
