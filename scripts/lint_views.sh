#!/bin/bash
# The four layers, enforced (ARCH-1 §1).
#
#   1. Omodachi/DesignSystem   the only place that draws pixels
#   2. Omodachi/Surfaces       the seven panels, composed out of layer 1
#   3. Omodachi/Shell          the router, the registry, the bar
#   4. everything else         no SwiftUI at all
#
# Layers 2 and 3 compose primitives; they never reach for a SwiftUI control, an
# SF Symbol, a system font or a colour of their own. Layer 4 never imports
# SwiftUI, so a store cannot quietly grow a view. And one file — the bundled
# placeholder theme — is the only place a colour may be written down (SPEC-F2
# §7.1), because everything else comes from `/v1/theme`.
#
# Output is one `path:line: rule — why` per finding and nothing at all when the
# tree is clean. `scripts/build.sh test` runs it first; a non-zero exit fails
# the build. `--self-test` proves each rule still fires, against fixtures in a
# temporary directory, and is what keeps this file from rotting into a no-op.
#
# It is one `awk` pass over every file rather than a `grep` per rule per file:
# the rule-per-file shape spawned about 1 400 processes, which on this
# maintainer's external volume produced intermittent `Bus error` kills — and a
# linter whose greps sometimes die is a linter that sometimes passes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

rules() {
  # $1: the directory to walk. Prints findings; prints nothing when clean.
  local target="$1" base="$2"
  find "$target" -name '*.swift' -type f | sort | tr '\n' '\0' | xargs -0 awk -v base="$base" '
    function say(rule, why) { printf "%s:%d: %s — %s\n", shortname, FNR, rule, why; findings++; return 1 }
    # A file changed: work out which layer it is in, once.
    FILENAME != seen {
      seen = FILENAME
      shortname = FILENAME
      if (base != "" && index(shortname, base) == 1) shortname = substr(shortname, length(base) + 1)
      design  = (FILENAME ~ /\/DesignSystem\//)
      surface = (FILENAME ~ /\/Surfaces\//)
      shell   = (FILENAME ~ /\/Shell\//)
      backend = !(design || surface || shell)
      placeholder = (FILENAME ~ /\/DesignSystem\/FallbackTheme\.swift$/)
      # The catalog itself is where the words are allowed to be written down.
      strings = (FILENAME ~ /\/DesignSystem\/(Strings|ReasonText)\.swift$/)
      # I18N-1: a file whose literals stand in for the words of the host — the
      # fallback menu, the demo PTY, the operator harness. It declares itself.
      hostwords = 0
    }
    # I18N-1: the file-level opt-out, declared in the first lines of the file.
    /lint:host-words/ { hostwords = 1 }
    # Prose is not a call site. A rule quoted in a doc comment is documentation.
    /^[ \t]*(\/\/|\*|\/\*)/ { next }

    backend {
      if ($0 ~ /^import SwiftUI/)
        say("layer-4-swiftui", "a backend file must not import SwiftUI (ARCH-1 §1.4)")
      if ($0 ~ /(struct|class|enum)[ \t]+[A-Za-z0-9_]+/ && $0 ~ /[:,][ \t]*View([^A-Za-z0-9_]|$)/)
        say("layer-4-view", "a backend file must not declare a View (ARCH-1 §1.4)")
    }

    !backend && !design {
      if ($0 ~ /(^|[^A-Za-z0-9_.])Button[ \t]*[({]/)
        say("raw-button", "use a DesignSystem primitive instead of Button (ARCH-1 §1)")
      if ($0 ~ /(^|[^A-Za-z0-9_.])Toggle[ \t]*\(/)
        say("raw-toggle", "use SquareToggle (D-16); an iOS capsule is not this shell")
      if ($0 ~ /(^|[^A-Za-z0-9_.])Picker[ \t]*\(/)
        say("raw-picker", "use SegmentedRow (A-54/A-56)")
      if ($0 ~ /(^|[^A-Za-z0-9_.])NavigationLink([^A-Za-z0-9_]|$)/)
        say("navigation-link", "the panel area has no push stack (A-55)")
      if ($0 ~ /\.sheet[ \t]*\(/)
        say("sheet", "a panel fills the panel area; it is never a sheet (A-55)")
      if ($0 ~ /Image[ \t]*\(systemName:/)
        say("sf-symbol", "every glyph goes through Glyph (UX-1 item 8)")
      if ($0 ~ /(^|[^A-Za-z0-9_.])Color[ \t]*\(/)
        say("raw-color", "colour comes from the host theme, not from a constructor (SPEC-F2 §1)")
      if ($0 ~ /\.font\([ \t]*\.system/)
        say("system-font", "type comes from the host theme steps (A-48)")
      if ($0 ~ /\.buttonStyle[ \t]*\(/)
        say("button-style", "a control style belongs to the primitive, not to its caller")
      # A-55 leaves exactly two covers: the unpaired first screen and the
      # picture. Both are put up by the Shell, so a Surface may not have one.
      if (surface && $0 ~ /\.fullScreenCover[ \t]*\(/)
        say("full-screen-cover", "only the Shell may present a cover (A-55: Onboarding and the Remote picture)")
    }

    # --- ARCH-1 §6: every word the app says comes from the catalog -----------
    # A literal in one of these holders is a string a translator will never see.
    # `Strings.x`, `String(localized:)` and `Text(verbatim:)` are the three ways
    # to say something; the last is for text that is not language — an id, a
    # measurement, a glyph.
    !backend && !strings {
      said = 0
      if ($0 ~ /(Text|Label)\([ \t]*"/ && $0 !~ /verbatim:/)
        said = say("hardcoded-copy", "Text/Label takes a catalog string (ARCH-1 §6)")
      if ($0 ~ /(TextTap|PanelTitle|PanelArea)\([ \t]*"/)
        said = say("hardcoded-copy", "a control'"'"'s label comes from the catalog (ARCH-1 §6)")
      # `case .message: "info.circle"` is a switch arm, not an argument called
      # `message` — the Chinese-literal rule below still covers a switch arm
      # that really does hold a sentence.
      if ($0 ~ /(title|detail|label|placeholder|message|reason|note|emptyHint|confirmTitle|cancelTitle|text|name|value):[ \t]*"[^"]/ &&
          $0 !~ /identifier:|systemImage:|symbol:|nerd:|table:|key:|defaultValue:/ &&
          $0 !~ /^[ \t]*case[ \t]/)
        said = say("hardcoded-copy", "a named string argument comes from the catalog (ARCH-1 §6)")
      if ($0 ~ /\.(accessibilityLabel|accessibilityValue|accessibilityHint|navigationTitle)\([ \t]*"/)
        said = say("hardcoded-copy", "an accessibility string comes from the catalog (A-65, ARCH-1 §6)")
      # The catch-all, and the one that actually holds: the source language is
      # zh-Hans, so any literal with a Chinese character in it is a sentence a
      # translator will never see, wherever in the expression it is hiding —
      # a `case .new: "未配对"`, a `var cancelTitle = "取消"`, a tuple in a
      # SegmentedRow. The four rules above stay because they also catch an
      # English literal in the same places.
      if (!said && $0 ~ /"/ && $0 !~ /verbatim:/) {
        rest = $0
        gsub(/[ -~\t]/, "", rest)          # every printable ASCII byte
        gsub(/·|›|×|…|—|、|→|←|↑|↓|⇥|⌘|⌥|⇧|⌃|↩|⏎|①|②|③|④|⑤|⑥|⑦/, "", rest)   # the glyph allowlist
        if (rest != "")
          say("hardcoded-copy", "a Chinese literal belongs in Localizable.xcstrings (ARCH-1 §6)")
      }

      # --- I18N-1 §2 rule ①: and an English literal is a sentence too ------
      # The rules above only fire on the holder they name, so a ternary inside
      # `Text(...)`, a `ProgressView("…")`, a `.confirmationDialog("…")` and a
      # bare switch arm all walked past them — which is how `Ready`, `You`,
      # `Reattach` and `Close this local SSH session?` reached a Chinese iPad.
      # This one reads every literal in layers ② and ③ instead, and lets past
      # only what is demonstrably not a sentence: an identifier-shaped token, a
      # value fed to one of the non-copy arguments, a comparison, or a line the
      # author marked `// non-copy`.
      if (!said && !hostwords && !design && $0 !~ /verbatim:/ && $0 !~ /non-copy/ &&
          $0 !~ /OmodachiTheme\.(space|font|bodyFont|fontSize|color)\(/ &&
          $0 !~ /(step|systemName|systemImage|identifier|named|table|key|defaultValue|localized|fallbackSymbol|input|glyph):/ &&
          $0 !~ /accessibilityIdentifier|forKey|Glyph\(|Icon\./ &&
          $0 !~ /==|!=|hasPrefix\(|hasSuffix\(|contains\(/ &&
          $0 !~ /^[ \t]*case[ \t]+"/) {
        line = $0
        gsub(/\\\([^)]*\)/, "", line)     # an interpolation is a value, not a word
        n = split(line, chunk, "\"")
        for (i = 2; i <= n; i += 2) {
          word = chunk[i]
          if (word !~ /[A-Za-z][A-Za-z]/) continue          # needs two letters to be a word
          if (word ~ /^[A-Za-z0-9+]+([.:_\/-]+[A-Za-z0-9+]+)+$/) continue  # an identifier token
          if (word ~ /^#?[0-9a-fA-F]+$/) continue            # a colour; colour-literal owns it
          say("foreign-copy", "an English literal belongs in Localizable.xcstrings (I18N-1 §2)")
          break
        }
      }
    }

    # --- I18N-1 §2 rule ②: layer ④ says things too ------------------------
    # Eight `userMessage` switches lived down here, each in whichever language
    # its author wrote in, and every one of them reached the screen through a
    # `notice`. A sentence in a backend file is a sentence nobody translated:
    # it belongs in the catalog, or — when it is one of the reason codes core raises —
    # in `ReasonText`. Log lines are not copy and are left alone.
    backend && !strings && !hostwords {
      if ($0 ~ /"/ && $0 !~ /non-copy/ && FILENAME !~ /Trace\.swift$/ &&
          $0 !~ /logger|Logger|os_log|privacy:|OSLog|[A-Za-z]Trace\./) {
        line = $0
        gsub(/\\\([^)]*\)/, "", line)
        n = split(line, chunk, "\"")
        for (i = 2; i <= n; i += 2) {
          word = chunk[i]
          han = word
          gsub(/[ -~\t]/, "", han)
          gsub(/·|›|×|…|—|、|→|←|↑|↓|⇥|⌘|⌥|⇧|⌃|↩|⏎|①|②|③|④|⑤|⑥|⑦|✓|❯|│|┌|┐|└|┘|─|\r|\n/, "", han)
          words = gsub(/[A-Za-z][A-Za-z]+/, "&", word)
          if (han == "" && (words < 2 || word !~ / /)) continue
          say("backend-copy", "a backend sentence belongs in Strings or ReasonText (I18N-1 §2)")
          break
        }
      }
    }

    !placeholder {
      if ($0 ~ /"#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/)
        say("colour-literal", "only FallbackTheme.swift may write a colour down (SPEC-F2 §7.1)")
      if ($0 ~ /(^|[^A-Za-z0-9_])Color\.(red|green|blue|yellow|orange|purple|pink|black|white|gray|grey|brown|cyan|mint|indigo|teal)([^A-Za-z0-9_]|$)/)
        say("named-colour", "the theme has 25 roles; SwiftUI'"'"'s palette is not one of them (SPEC-F2 §1)")
    }

    END { exit findings > 0 ? 1 : 0 }
  '
}

self_test() {
  local work rc=0 output
  work="$(mktemp -d)"
  mkdir -p "$work/Omodachi/DesignSystem" "$work/Omodachi/Surfaces" \
           "$work/Omodachi/Shell" "$work/Omodachi/Host"

  cat > "$work/Omodachi/Surfaces/Bad.swift" <<'SWIFT'
import SwiftUI
struct Bad: View {
    var body: some View {
        Button("x") { }
        Toggle("y", isOn: .constant(true))
        Picker("z", selection: .constant(1)) { }
        NavigationLink("w") { }
        Image(systemName: "gear")
        Color(.red)
        Text(verbatim: "t").font(.system(size: 12))
        Text(verbatim: "u").buttonStyle(.plain)
        Text(verbatim: "v").sheet(isPresented: .constant(false)) { }
        Text(verbatim: "w").fullScreenCover(isPresented: .constant(false)) { }
    }
}
SWIFT
  cat > "$work/Omodachi/Host/Store.swift" <<'SWIFT'
import SwiftUI
struct Leaked: View { var body: some View { EmptyView() } }
SWIFT
  cat > "$work/Omodachi/Shell/Palette.swift" <<'SWIFT'
enum Palette { static let accent = "#7aa2f7"; static let fallback = Color.red }
SWIFT
  # The clean side: everything the rules allow, so a false positive fails too.
  cat > "$work/Omodachi/DesignSystem/Primitive.swift" <<'SWIFT'
import SwiftUI
struct Primitive: View {
    var body: some View {
        Button("x") { }.buttonStyle(.plain)
        Image(systemName: "gear")
        Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
    }
}
SWIFT
  cat > "$work/Omodachi/DesignSystem/FallbackTheme.swift" <<'SWIFT'
enum FallbackTheme { static let colors = ["accent": "#7aa2f7"] }
SWIFT
  cat > "$work/Omodachi/Surfaces/Copy.swift" <<'SWIFT'
import SwiftUI
struct Copy: View {
    var body: some View {
        Text("硬写的一句话")
        Text(verbatim: "1194 × 834")
        Text(Strings.panelSettings)
        FlowButton(title: "开始", kind: .primary) { }
        // two findings above: the Text and the title:
        FlowButton(title: Strings.remoteStartExtend, kind: .primary) { }
        Glyph(symbol: "gear").accessibilityLabel("硬写的标签")
    }
    var cancelTitle = "取消"
    var symbol: String {
        switch self {
        case .message: "info.circle"
        }
    }
}
SWIFT
  cat > "$work/Omodachi/DesignSystem/Strings.swift" <<'SWIFT'
enum Strings { static let panelSettings = String(localized: "panel.settings", defaultValue: "设置") }
SWIFT
  # I18N-1 rule ①: English in a holder the older rules never looked at.
  cat > "$work/Omodachi/Surfaces/English.swift" <<'SWIFT'
import SwiftUI
struct English: View {
    var body: some View {
        Text(ready ? "Ready" : "Working…")
        ProgressView("Loading commands…")
        Text(verbatim: "\(a) · \(b)")
        Text(Strings.panelSettings)
        Glyph(symbol: "gear")
        HStack(spacing: OmodachiTheme.space("lg")) { }
        Tap(identifier: "open-panel") { }
        Text(route == "native:agent" ? Strings.panelAgent : Strings.panelHerdr)
        Text(workspace.map { "w\($0)" } ?? id)
        Text(kind)  // non-copy
        case .running: "ellipsis" // non-copy: a glyph name
    }
}
SWIFT
  # I18N-1 rule ②: a sentence in a backend file, in either language.
  cat > "$work/Omodachi/Host/Copy.swift" <<'SWIFT'
import Foundation
enum Copy {
    static let english = "The host could not finish this request."
    static let chinese = "主机未能完成这次请求。"
    static let code = "remote_session_exists"
    static let path = "v1/remote/sessions"
    static let key = ReasonText.message("timeout", domain: .host)
    static func trace() { RemotePairingTrace.step("discover.ok", "request=\(id) status=\(status)") }
}
SWIFT
  # …and the file that declares itself as the words of the host.
  cat > "$work/Omodachi/Host/Fallback.swift" <<'SWIFT'
// lint:host-words — stands in for the menu of the host.
import Foundation
enum Fallback { static let label = "App launcher" }
SWIFT
  cat > "$work/Omodachi/Host/Wire.swift" <<'SWIFT'
import Foundation
struct Wire: Decodable { let id: String }
/// A doc comment may name Button( and Image(systemName: without being a call.
SWIFT
  cat > "$work/Omodachi/Shell/Router.swift" <<'SWIFT'
import SwiftUI
struct Router: View { var body: some View { Text(verbatim: "x").fullScreenCover(isPresented: .constant(false)) { } } }
SWIFT

  output="$(rules "$work/Omodachi" "$work/")"

  expect() {
    local rule="$1" count="$2" seen
    seen="$(printf '%s\n' "$output" | grep -c ": $rule — ")"
    if [[ "$seen" != "$count" ]]; then
      printf 'self-test: expected %s %s finding(s), saw %s\n' "$count" "$rule" "$seen" >&2
      rc=1
    fi
  }
  expect raw-button 1
  expect raw-toggle 1
  expect raw-picker 1
  expect navigation-link 1
  expect sheet 1
  expect sf-symbol 1
  expect raw-color 1
  expect system-font 1
  expect button-style 1
  expect full-screen-cover 1
  expect layer-4-swiftui 1
  expect layer-4-view 1
  expect colour-literal 1
  expect named-colour 1
  expect hardcoded-copy 5
  expect foreign-copy 2
  expect backend-copy 2
  # The clean files must produce nothing: the DesignSystem primitive draws,
  # FallbackTheme writes a colour down, the wire file has no SwiftUI and names
  # two rules in a comment, and the Shell is allowed its two covers.
  local noise
  noise="$(printf '%s\n' "$output" | grep -E 'DesignSystem/|Host/Wire|Host/Fallback|Shell/Router')"
  if [[ -n "$noise" ]]; then
    printf 'self-test: false positives\n%s\n' "$noise" >&2
    rc=1
  fi
  rm -rf "$work"
  [[ $rc -eq 0 ]] && printf 'lint_views self-test: 18 rules fire, 0 false positives\n'
  return $rc
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  "")          target="$ROOT/Omodachi"; base="$ROOT/" ;;
  *)           target="$1"; base="" ;;
esac

output="$(rules "$target" "$base")"
if [[ -n "$output" ]]; then
  printf '%s\n' "$output"
  printf '\n%s findings\n' "$(printf '%s\n' "$output" | grep -c ':')" >&2
  exit 1
fi
exit 0
