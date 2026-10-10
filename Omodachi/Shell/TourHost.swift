import SwiftUI

/// TUTORIAL-1. The tour over the Shell: which stop is up, where its thing is
/// on screen, and the three rules that keep it out of the way.
///
/// * It **starts** only on the first panel with nothing over it — the place a
///   pairing or the demo lands — so it never appears over a panel the person
///   has already gone into. An armed tour waits there until it can.
/// * It **ends** the moment the person goes somewhere themselves: a tap on a
///   bar entry (the scrim lets it through), a summon from the host, Remote
///   taking the screen. That counts as seen, like Skip and Done.
/// * It is **put down**, not ended, when the bar itself goes away under it.
struct TourHost: View {
    @ObservedObject var tour: FirstStepsTour
    @ObservedObject var router: SurfaceRouter
    @ObservedObject var registry: PanelRegistry
    let anchors: [String: Anchor<CGRect>]
    let edge: HostBarPosition
    let insets: EdgeInsets

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if let step = tour.step, let position = tour.position {
                TourSpotlight(target: anchors[step.anchor].map { proxy[$0] },
                              edge: edge, safe: insets, stepID: step.rawValue,
                              title: TourWords.title(step), message: TourWords.message(step),
                              progress: "\(position.number) / \(position.count)", // non-copy: a counter
                              progressLabel: Strings.tourProgress(Format.count(position.number),
                                                                  Format.count(position.count)),
                              nextTitle: tour.isLast ? Strings.tourDone : Strings.tourNext,
                              nextIdentifier: tour.isLast ? "tour-done" : "tour-next",
                              skipTitle: tour.isLast ? nil : Strings.tourSkip,
                              onNext: { tour.next() }, onSkip: { tour.finish() })
            }
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: tour.isShowing)
        .task(id: startKey) { await startWhenReady() }
        .onChange(of: router.panel) { _, _ in stepAside() }
        .onChange(of: router.stage) { _, _ in stepAside() }
        .onChange(of: router.overlayVisible) { _, visible in if !visible { stepAside() } }
        .onDisappear { tour.suspend() }
    }

    /// What decides whether an armed tour can start now.
    private var startKey: String {
        "\(tour.pending)-\(tour.isShowing)-\(router.panel.rawValue)-\(router.stage == .panels)" // non-copy: a task id
    }

    private var available: [TourStep] {
        TourStep.available { entry in PanelID(rawValue: entry).map(registry.isEnabled) ?? true }
    }

    private func startWhenReady() async {
        guard tour.pending, !tour.isShowing, router.stage == .panels, router.panel == .menu else { return }
        // Let the Panel draw its bar first: the first stop points at it.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled, router.stage == .panels, router.panel == .menu else { return }
        tour.startIfPending(available: available)
    }

    private func stepAside() {
        if tour.isShowing { tour.finish() }
    }
}

/// TUTORIAL-1. Each stop's two lines.
enum TourWords {
    static func title(_ step: TourStep) -> String {
        switch step {
        case .bar: Strings.tourBarTitle
        case .remote: Strings.tourRemoteTitle
        case .agent: Strings.tourAgentTitle
        case .herdr: Strings.tourHerdrTitle
        case .notifications: Strings.tourNotificationsTitle
        case .settings: Strings.tourSettingsTitle
        }
    }

    static func message(_ step: TourStep) -> String {
        switch step {
        case .bar: Strings.tourBarBody
        case .remote: Strings.tourRemoteBody
        case .agent: Strings.tourAgentBody
        case .herdr: Strings.tourHerdrBody
        case .notifications: Strings.tourNotificationsBody
        case .settings: Strings.tourSettingsBody
        }
    }
}
