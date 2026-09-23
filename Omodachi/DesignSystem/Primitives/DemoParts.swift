import SwiftUI

/// STORE-1 §1. The one line that stays on top of every panel while the demo is
/// on: what this is, and the way out of it.
struct DemoBanner: View {
    let title: String
    let exitTitle: String
    let exit: () -> Void

    var body: some View {
        HStack(spacing: OmodachiTheme.space("sm")) {
            Text(title)
                .font(OmodachiTheme.font("caption"))
                .foregroundStyle(OmodachiTheme.warning)
                .lineLimit(1)
                .accessibilityIdentifier("demo-banner-label")
            Spacer(minLength: 0)
            TextTap(exitTitle, step: "caption", bordered: true, minimumHeight: 30, action: exit)
                .accessibilityIdentifier("demo-exit")
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(OmodachiTheme.warning.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(OmodachiTheme.warning.opacity(0.45)).frame(height: OmodachiTheme.controlBorderWidth)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("demo-banner")
    }
}

/// STORE-1 §1. What the Remote panel shows in the demo instead of a picture:
/// a desktop drawn by the app out of the theme's own roles — a bar with its
/// workspaces, two tiled windows with lines where text would be. It is a
/// diagram, never a screenshot of anybody's machine.
struct DesktopSketch: View {
    var workspaces = 5
    var activeWorkspace = 2

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let gap = max(4, w * 0.012)
            let barHeight = max(10, h * 0.06)
            VStack(spacing: gap) {
                bar(height: barHeight, gap: gap)
                HStack(spacing: gap) {
                    window(lines: 7, accentLine: 2, gap: gap)
                        .frame(width: (w - gap * 3) * 0.58)
                    VStack(spacing: gap) {
                        window(lines: 3, accentLine: nil, gap: gap)
                        window(lines: 3, accentLine: 0, gap: gap)
                    }
                }
            }
            .padding(gap)
            .frame(width: w, height: h)
            .background(OmodachiTheme.terminal)
            .overlay(Rectangle().stroke(OmodachiTheme.border.opacity(0.6), lineWidth: OmodachiTheme.controlBorderWidth))
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
    }

    private func bar(height: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: gap * 0.6) {
            ForEach(1...max(1, workspaces), id: \.self) { index in
                Rectangle()
                    .fill(index == activeWorkspace ? OmodachiTheme.accent : OmodachiTheme.text.opacity(0.35))
                    .frame(width: height * 0.6, height: height * 0.6)
            }
            Spacer(minLength: 0)
            Rectangle().fill(OmodachiTheme.text.opacity(0.35)).frame(width: height * 2.4, height: height * 0.35)
            Spacer(minLength: 0)
            Rectangle().fill(OmodachiTheme.text.opacity(0.35)).frame(width: height * 1.4, height: height * 0.35)
        }
        .padding(.horizontal, gap)
        .frame(height: height)
        .background(OmodachiTheme.barBackground)
    }

    private func window(lines: Int, accentLine: Int?, gap: CGFloat) -> some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: gap * 0.8) {
                ForEach(0..<lines, id: \.self) { index in
                    Rectangle()
                        .fill(index == accentLine ? OmodachiTheme.accent.opacity(0.8) : OmodachiTheme.text.opacity(0.22))
                        .frame(width: proxy.size.width * (0.35 + 0.1 * CGFloat((index * 3) % 5)), height: max(2, gap * 0.7))
                }
                Spacer(minLength: 0)
            }
            .padding(gap)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(OmodachiTheme.background)
        .overlay(Rectangle().stroke(OmodachiTheme.accent.opacity(0.55), lineWidth: OmodachiTheme.controlBorderWidth))
    }
}
