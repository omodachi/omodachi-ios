import SwiftUI

/// The mark of a thing that is not us.
///
/// Two of the app's panels are windows onto somebody else's product — ③ is the
/// host's default agent (codex today) and ④ is Herdr — and Leo asked for their
/// own marks there rather than a generic glyph: "default agent 我们可以用官方的
/// 图标么". A mark is only ever the vendor's own published artwork, packaged as
/// an SVG in `Resources/Brand.xcassets` with its provenance written down beside
/// it (`SOURCES.md`), and it is drawn as a **template** image, so it takes the
/// theme's foreground and has no colour of its own. Study 01's rule that the
/// app's icons are monochrome is not suspended for a logo.
enum BrandMark: String, Equatable, Sendable, CaseIterable {
    case codex = "brand-codex"
    case herdr = "brand-herdr"

    /// What the host says its default agent is, mapped to a mark.
    ///
    /// The value comes from core — `identity.provider` on the chat, or
    /// `state.agent.default_agent`'s configured kind on the bar (`agent.md`:
    /// "A host whose configured kind is not `codex` … rather than a silently
    /// different provider"). A provider this app has no mark for is not drawn
    /// with somebody else's: it falls through to the host's own icon and then
    /// to the study's generic agent glyph.
    static func provider(_ name: String?) -> BrandMark? {
        switch name?.lowercased() {
        case "codex", "openai", "chatgpt": .codex
        default: nil
        }
    }
}

/// The host's own glyph for an entry, the vendor's mark where nothing can draw
/// it, and the study's glyph where there is neither.
///
/// **ICON-1 turned AGENT-2's order around.** AGENT-2 put the vendor mark first
/// and the host's icon second, and Leo, looking at the two bars side by side,
/// said the result was wrong: "herdr icon 和 Omarchy 里的不一致，agent 好像也
/// 不一致（看 host bar 里的 icon）". He is right, and the reason is that the
/// host does not draw either product's logo in its bar — it draws a Nerd Font
/// code point, `U+F233` for Herdr and `U+F16A3` for the agents widget. So the
/// same code point is what this draws, through the same fallback chain as
/// every other host glyph, and the mark is what is left when no installed face
/// carries it.
struct BrandGlyph: View {
    /// The provider's mark, or `nil` when this entry is ours.
    let mark: BrandMark?
    /// What the host's catalog published for this row, if anything. Empty
    /// means the entry has no catalog row and `fallback`'s code point — which
    /// is the host's, from `Icon` — is the host's answer for it.
    var hostIcon: String = ""
    var hostIconFont: String = ""
    /// The study's glyph, which is also what this icon *means*.
    let fallback: (symbol: String, nerd: String)
    var step = "icon"
    var points: CGFloat?

    private var size: CGFloat { points ?? OmodachiTheme.fontSize(step) }

    var body: some View {
        HostGlyphView(glyph: hostIcon.isEmpty ? fallback.nerd : hostIcon,
                      iconFont: hostIconFont,
                      fallbackSymbol: mark.map { .vendor($0, symbol: fallback.symbol) }
                          ?? .symbol(fallback.symbol),
                      size: size)
            .accessibilityHidden(true)
    }
}

/// HERDR-7: what marks a Herdr pane that runs an agent. Leo: "herdr 没必要为了
/// agent 加 agent 动画啦" — the animated face belongs to the Agent panel and
/// the bar entry; a pane only needs to say *that* an agent runs there and what
/// it is doing. So this is the bar's idle Agent slot, still: the same
/// `BrandGlyph` chain (the host's agent code point, then the vendor's own mark
/// where the App ships one — codex only — then the study's agent glyph), never
/// a mark the App does not already carry. It takes the colour of the row's
/// status words (`AgentStatus.role`: working accent, blocked red, done green,
/// idle muted), so a row has one colour system, and it is hidden from
/// VoiceOver: the row's label says the agent and its state in words.
struct HerdrAgentMarker: View {
    let mark: BrandMark?
    let role: ThemeColorRole
    /// The box the marker sits in; the old face's 24, so rows keep their size.
    static let size: CGFloat = 24

    var body: some View {
        BrandGlyph(mark: mark, fallback: Icon.agent, step: "icon-large")
            .foregroundStyle(OmodachiTheme.current.color(role))
            .frame(width: Self.size, height: Self.size)
            .accessibilityHidden(true)
    }
}
