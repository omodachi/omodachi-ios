# P5 native Agent chat component

Owner C, 2026-09-17. Four production Swift files, no network/mock default and no
root/Remote/Host endpoint changes. A integrates the existing Agent route; B supplies
an `AgentChatTransport` adapter when its current runtime work is delivered.

## Usable component

- `AgentChatModel`: real typed message/tool/turn state, same opaque provider
  identity, startup/send/cancel/reconnect state, draft retained across navigation.
- `AgentChatStore`: explicit-entry ensure, snapshot attach for an existing identity,
  ordered observation, send request identity and no automatic resend, interrupt
  awaiting actual turn completion, navigation stops observation without killing
  the provider or touching Remote.
- `AgentChatView`: native readable You/Agent messages, expandable actual tool
  details/status, multiline composer, Send/Stop, one return-to-work header;
  existing OmodachiTheme, fullscreen, square borders. No ANSI renderer or fake chat.
- `AgentChatSurface`: small integration wrapper that opens observation when this
  explicit Agent route appears and detaches observation when it disappears.

A creates and retains one `AgentChatStore(transport: realAdapter)` for the same
host/default agent, then renders:

    AgentChatSurface(store: retainedAgentStore,
                     onReturnToWork: { /* restore prior surface, not new session */ })

Do not create this store on every body evaluation, call ensure at App startup, or
replace Herdr/SSH routes. Add the independent directory through normal project
source generation. Until a real adapter is present, do not silently inject the
fixture into the production route or claim chat works.

## Panel recall integration clarification (user update, 2026-09-17)

On entry to Agent, Herdr or SSH, the root hides Panel by default, including on
wide iPad. Retain one lightweight native bar with an Omarchy button, plus edge-pan
recall. This does not mean repeating the host desktop bar or adding stacked status
strips. The controller idle page may still show menu + right-side Shortcut columns.

A owns the shared root/bar/gesture callbacks. Route the Omarchy button and pan to
`show existing Panel`, not `returnToWork`, not `selected = nil`, and not Agent
navigation/ensure. Panel visibility must preserve the current surface, retained
AgentChatStore, draft/turn and menu search/path/scroll. Covering the chat with Panel
must not tear down/recreate the chat or restart its provider; only an actual
surface departure uses the component's observation detach behavior.

The existing `onReturnToWork` callback remains an explicit return to the previous
work surface. It is separate from Panel summon. A should compose this header with
the single lightweight bar rather than add duplicate navigation rows. No root/view
code is changed in this documentation update; P5 still has no real backend wiring.

## Transport contract handed to B

- `ensureDefault()` on the first explicit Agent entry → authoritative structured
  snapshot with existing `hostID/agentID=default/provider/providerSessionID`.
  Reuse existing `POST /v1/agent/default:ensure` / `DefaultAgentManager.ensure`;
  its current terminal-route response alone is NOT a structured-chat snapshot.
- `snapshot(for identity)` on return/reconnect → same identity, full current rows,
  actual active turn, Host replay sequence. Do not silently fork/start a new thread.
- `events(identity, after sequence)` → typed turnStarted/message(current text)/
  tool(current status/result)/turnFinished/turnFailed. Host owns the stable sequence;
  it is not a claim that raw provider events have this field. Adapter can accumulate
  real provider text deltas into one item update. A sequence gap requires snapshot.
- `send(text, requestID, identity)` → return only when accepted; throw on uncertain
  delivery. No fabricated assistant rows on ACK. Keep request identity on ambiguous
  delivery; snapshot may expose acceptedRequestIDs to resolve it. Changed draft
  cannot become a fresh request while prior delivery remains unresolved.
- `interrupt(turnID, identity)` → request interruption. View remains Stopping until
  a real matching turn completion; request ACK does not fabricate completion.

Errors returned to this component must already be user-facing messages; do not
forward credential/path-rich provider stderr. This is normal adapter hygiene,
not an extra user approval flow.

## Backend facts and unresolved integration

Read-only 2026-09-17 host probe: Omarchy default is `codex`; Herdr 0.8.2; installed
Codex CLI 0.154.0 exposes app-server and proxy commands. Herdr AgentInfo schema has
`agent_session: {agent, kind: id|path, source, value}`. That is a possible identity
bridge, not proof it is populated correctly for the currently running default.
No live transcript was read and no agent was started by this slice.

Official Codex app-server docs were fetched (HTTP200) at
`https://developers.openai.com/codex/app-server/`: initialize, thread/read/resume,
turn/start/interrupt and typed item progress/message notifications are supported.
Prioritize that official structured interface; don't parse PTY output. The
remaining dependency is mapping the Herdr default to its actual provider thread
and attaching to the existing owner safely rather than starting another agent.
A separate app-server process and `thread/resume` alone do NOT prove simultaneous
same-thread/TUI ownership works. Verify the installed proxy/daemon integration
and same-thread event/control behavior before choosing how B attaches.

## Local runnable validation, explicit limits

`python3 Tools/ChatAgentTests/run_tests.py` compiles/runs the model and a fixture
transport store journey, then typechecks actual component files with real Theme
against the iOS17 simulator SDK. The fixture covers explicit ensure once, send,
structured message/tool updates, leave/reattach same identity/draft, and stop.
`Tools/ChatAgentTests/AgentChatFixturePreview.swift` is an optional preview harness
with a visible MOCK banner, outside the production App source directory. It has
no socket/provider calls. Do not include it in the production target.

This is not full App compilation, rendered UI QA, or a real conversation. A/B must
still prove actual same-default chat, starting only on entry, real tool/stream
updates, cancellation, reconnect, and return to the prior Remote desktop. Those
are the P5/J3 acceptance checks, not claims made by synthetic tests.

## Existing-TUI handoff UI addition

A's real transport must map Host code `existing_thread_handoff_required` to
`AgentChatHostError(code:)`; no localized-string parsing. Only this error shows
one inline card. A fresh default's normal ensure/snapshot path shows no migration
confirmation. Implement the two additive protocol methods using B's exact APIs:

- `prepareHandoff()` → POST `/v1/agent/default/chat/handoff:prepare` with `{}`;
  decode `AgentChatHandoffPlan` (plan_id/status/requires_confirmation/agent_id/
  provider/provider_session_id/pane_id/impact/rollback).
- `confirmHandoff(planID:)` → POST `/v1/agent/default/chat/handoff:confirm` with
  `{plan_id: planID, confirmed: true}`; decode `AgentChatHandoffResult`.

`confirmed:true` is sent only because the view's explicit Confirm this handoff
button called `confirmPreparedHandoff`; never from ensure, prepare, Retry or
App-launch callbacks. The component presents the actual plan impact and rollback
text before that button exists. Not now invalidates the visible prepared step.
Duplicate taps are blocked by confirming state. On completed/same-thread/same-pane
result it re-enters normal ensure and displays the real snapshot.

Map busy/expired/target-changed/rolled-back/unconfirmed error codes to
AgentChatHostError. Busy keeps the user's task untouched; Review again prepares a
fresh plan, never repeats confirmation automatically. Leaving the surface discards
any displayed preparation so it cannot be confirmed invisibly on return.

No default mock is added. Protocol default methods throw unsupported only to keep
existing transport conformances compiling while A adds HTTP. These placeholders
are not implemented handoff. Tests now prove no confirm on open/prepare/Not now,
exactly one confirm after explicit review, and same-thread snapshot after success.

## Native slash commands (current slice)

A implements new transport methods:
- slashCommands(): GET `/v1/agent/default/chat/commands`, decode AgentSlashCatalog
  (revision/provider/provider_version/commands id/name/description/argument_hint/
  execution/available/reason/turn_policy; extra contract_revision is ignored).
- executeSlash(commandID:revision:arguments:requestID:): POST
  `/v1/agent/default/chat/commands/{id}:execute` with revision, arguments unchanged,
  request_id. Map status/command_id/result to AgentSlashResult. For
  native_action_required map native_request.action/arguments to
  AgentSlashNativeRequest; onNativeCommand opens the existing recognized native UI.
  Unknown native actions remain unsupported; never feed their text into turn/start.

Composer text beginning with / opens the provider command list. It supports name
filtering, descriptions, argument hints and precise unsupported feedback. Selecting
only changes the draft; Run executes. The whitespace separator and all arguments
are preserved exactly. Code blocks, quoted lines and embedded slash stay normal
chat. Unknown/unsupported slash stays in draft and never becomes a model prompt.
Treat as message text explicitly opts back into literal ordinary send.

No command runs on initialization/list loading/selection. New/reset/context-changing
commands remain unsupported until an explicit native confirmation flow is wired;
this component never blindly executes a native_request. Current turn_policy allowed
works during a turn; idle_required/interrupts do not silently interrupt current work.
A may add the corresponding explicit interaction later. Full official command list
and exact supported subset come from B; UI does not claim every command works.

A's WebSocket initial snapshot race is also supported: AgentChatEnvelope.event is
optional; yield snapshot: actual AgentChatSnapshot instead of inventing an event or
requiring its sequence to equal the earlier ensure response. The store restores
same-identity snapshot rows/turn/sequence, then processes later events normally.
