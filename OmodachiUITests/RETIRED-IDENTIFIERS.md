# Accessibility identifiers the app no longer emits

`scripts/check_ui_identifiers.py` fails the lint when a UI test reaches for a
name no view under `Omodachi/` can produce. This file is the list of names for
which that is already true and is not being repaired in the same change.

**Why this file exists.** GEST-1 §6b reported twice, with timestamps, that a
freshly paired simulator never received a first frame from `omarchy`. The host
was streaming the whole time. The suite was waiting 150 seconds for
`remote-edge-strip`, which MERGE-1's A-40 had deleted from the product; a wait
on a name nothing emits can only time out, and a timeout reads exactly like a
broken feature. REMOTE-5 reproduced the run 15/15 and found no defect to fix.
The cost of that was a day of two people's time, so the names are written down
now instead of being met one at a time.

**A line here is not a repair.** It says: this suite is asserting against
something that is not on screen, and until it is repointed that assertion
proves nothing. A *negative* assertion ("A-40 draws no strip") is the one
legitimate use of a retired name, and the two of them cannot be told apart from
the text of a single line — so this file does not try to, and a name being
listed does not make its use correct.

| identifier | what took it away | what a test should reach for |
| --- | --- | --- |
| `remote-edge-strip` | MERGE-1 A-40 — Remote draws no native chrome | `remote-live-picture` (the picture), `remote-picture-waiting` (before the frame) |
| `remote-keyboard` | the overlay's keyboard moved into the bar's quick actions | `quick-keyboard` |
| `remote-pointer-mode` | same move | `quick-pointerMode` |
| `remote-native-video` | the stream view stopped naming itself separately from the stage | `remote-live-picture` |
| `remote-entry-close` | the Remote entry lost its own close control when it became a panel area | the bar entry, `open-remote` |
| `panel-pin-remote` | the Panel's pinned rows are `pin-<entry id>` (`MenuRows`) | `pin-remote`, or the bar's `open-remote` |
| `panel-pin-settings` | same | `pin-settings`, or the bar's `open-setup` |
| `panel-notifications`, `panel-notifications-toggle`, `panel-notifications-unread` | the notifications surface was rebuilt (`NotificationsPanelView`) | `notifications-panel`, `panel-notifications-more`, `panel-notifications-clear`, `panel-dnd` |
| `panel-collapse` | the Panel column no longer collapses from a control of its own | — |
| `open-settings` | the bar names ⑤ `open-setup` (`BarView.identifier(for:)`) | `open-setup` |
| `open-shell` | the bar names ④ `open-ssh` | `open-ssh` |
| `settings-close` | Settings became a panel area with no close button of its own | the bar entry it came from |
| `voice-button` | dictation is drawn inside the composer, not as a named button | — |
| `search-workspace-3`, `terminal-home`, `terminal-panel-toggle` | `NavigationUITests` predates the SSH panel's current controls (`terminal-*` in `SSHPanelView`) | `terminal-reattach`, `terminal-keyboard`, `terminal-options` |

Repointing these belongs to the specs that own those suites (MERGE-1, UX-1,
REMOTE-2, AGENT-2, MENU-2, and the navigation walk); REMOTE-5 repaired only the
ones that decide whether a first frame arrived or whether a session was ended —
`GEST1AcceptanceTests` and `OperatorRemoteTests`.
