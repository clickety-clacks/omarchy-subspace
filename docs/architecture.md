# Architecture and invariants

The constraints here are easy to lose while editing the visible QML. They are
part of the product's behaviour, not incidental implementation details.

## Components

```text
bin/subspace-communicator        launch, or present the running one
  └─ qs -p Main.qml              its own process
       ├─ SubspaceLink.qml       one per configured space
       │    └─ bridge/subspace.py   registration, WebSocket, reconnect
       └─ CommunicatorWindow.qml the window: header, transcript, composer
            ├─ ScrollPhysics.qml momentum and edge give for one Flickable
            └─ MessageRow.qml    one line of traffic
```

`Main.qml` is the application root. It owns durable settings, the list of
spaces, which one is active, and the window. It has no UI of its own.

This is an application, not part of the desktop shell. It was a shell plugin
first, and that was the wrong shape: it lived inside `omarchy-shell`, so it
could not appear in the launcher, could not be started or stopped on its own,
died with the shell, and every edit needed `omarchy restart shell` because the
shell caches compiled QML for the life of its process. None of that is true of
a program that runs itself.

`SubspaceLink.qml` is one connection: its bridge process, its identity, its
message model, its unread count and "new" mark. Everything per-space lives
here, so a second Subspace is a second one of these rather than a space id
threaded through the client. Its signals carry the link itself, because the
links are created dynamically and have no id to refer back to. It is a
`QtObject`: there is nothing to draw, and an Item created against the
application root has no scene to live in.

`CommunicatorWindow.qml` owns presentation and input. It never talks to the
network; it calls `client.send()` and reacts to what the client hands it.

`bridge/subspace.py` is the only component that knows Subspace exists as a
protocol. It uses the Python standard library and `openssl`, nothing else.

## Lifecycle invariants

1. Quickshell resolves `qs.<Module>` against the running config's own root, not
   against `QML_IMPORT_PATH`. The Omarchy shell's `Commons` singletons
   therefore have to appear inside this directory, and the launcher links them
   rather than vendoring a copy, so the palette always matches the installed
   Omarchy instead of drifting from a snapshot.
2. Closing the window closes the application. A window with no surface cannot
   be marked for attention either, so there is nothing useful a hidden one
   could do.
3. Exactly one instance runs. Launching again presents the existing window
   through `qs ipc`; it must never start a second client, because two clients
   sharing an identity invalidate each other's session token.
4. One bridge process, one identity, one connection per space. Two clients
   running under one identity on the same server invalidate each other's
   session token, so the identity must stay stable per machine and per user.
   It is derived once and the key is generated once; every later run
   re-authenticates as the same agent rather than becoming a new one.
5. The bridge is restarted on exit after a short delay. Reconnection inside a
   running bridge is the bridge's own business and does not involve QML.
6. Spaces are only handed to the Instantiator once the hostname is known. A
   link that started with a placeholder identity would register under it, and
   that registration is not undone by getting the right name a moment later.
7. The settings file is watched, so adding or removing a space takes effect
   without a restart: a removed space's link is destroyed, which stops its
   bridge.

## Connection invariants

1. Registration's `start` and `verify` must travel over one HTTP connection.
   The deployed server ties the challenge table's lifetime to the process that
   created it, so a second connection can land on a peer that never saw the
   challenge and answers 401.
2. `servers` is tried in order, advancing on each failed attempt, so a fallback
   URL is reached without restarting anything.
3. A message typed during an outage is queued in the bridge and posted after
   the next successful join. Nothing typed is dropped silently.
4. Silence is treated as failure. The server answers every heartbeat, so
   hearing nothing at all for several in a row means the link is gone even
   though the socket has not said so — a peer that disappears without a FIN
   leaves a client sitting in `select()` forever, reporting "connected" and
   receiving nothing. Anything arriving counts as proof of life; going quiet
   past `SILENCE_SECONDS` drops the connection and reconnects. TCP keepalive
   is set as well, for the same failure a layer down.
5. A replayed message already on screen is dropped, by id. A reconnect replays
   the server's buffer, which overlaps what is already shown; deduplicating
   turns that from a duplicate history into gap-filling for whatever was said
   while the connection was down. Ids are forgotten when their messages are
   trimmed, so a later replay of them is allowed back in.

   What this cannot recover is an outage longer than the server's buffer: that
   history is gone from the server too, and there is no cursor to ask for it.
6. That unrecoverable case is detectable, and is the only one marked. On a
   rejoin with history already on screen, the replayed batch is compared to
   what is held: any overlap proves the replay covers the outage. No overlap,
   plus a batch whose oldest message is newer than the newest one held, proves
   the span between them was dropped from the server's buffer before the client
   returned — and a `gap` row is inserted at the seam. Nothing is marked on a
   first connection, on an older replay, or wherever an overlap exists, because
   none of those demonstrate loss.
4. Delivery is confirmed by the server's reply to `post_message`, not by the
   write succeeding. A refused message restores the text to an empty composer
   and says why.
5. There is no local echo. Your own line appears when the server broadcasts it
   back, marked by matching agent id. That keeps the transcript exactly equal
   to what the firehose actually carried.

## Attention invariants

1. Attention is requested through the native Qt window's `alert(0)`. Quickshell's
   `FloatingWindow` is a wrapper, not a `QWindow`, and exposes neither `alert`
   nor `active`; both must be reached through `contentItem.Window.window`.
2. Attention is never raised for replayed history, for your own messages, or
   while the window has focus. Those three exclusions are what keeps the
   feature from becoming noise.
3. The compositor owns activation policy. This client raises urgency and stops
   there — it never focuses, raises, or moves its own window in response to
   traffic.
4. The unread count and the "new" mark are kept whether or not alerts are
   enabled, and whether or not the window is open. Turning alerts off makes the
   desktop quiet; it does not make the client forget.

## Multiple spaces

1. Each space has its own identity, and the same default name is fine across
   spaces: agent registries are per server.
2. Unread is per space and shows on that space's tab. Attention is not: any
   space may raise urgency, because the window is what the compositor marks.
3. A message in a space you are not looking at counts as unread even when the
   window has focus. Only the active space's traffic is cleared by looking at
   it.
4. The switcher's rows bind to each link's own properties. Rebuilding the array
   behind them to recompute a total would recreate every row on every incoming
   message.
5. Links are managed by hand, not by a model delegate. A model reset destroys
   and recreates every delegate, so adding one Subspace would drop and
   re-register every other connection. Each space is keyed by identity, owner
   and server list — what actually determines the connection — so `syncLinks()`
   reuses the link for anything whose key is unchanged, creates one for a key
   it has not seen, and destroys the links whose keys have gone.

   The name is deliberately absent from the key: it is a label, not a
   connection, and applies in place. Renaming a Subspace therefore reconnects
   nothing, and editing one's address reconnects only that one.

   This also makes the sync idempotent, which is what lets it run on every
   settings write without a comparison guard.
6. Settings are written atomically — temp file plus rename — so this app's own
   write does not reliably come back through its own watcher. Anything that
   writes the file applies the result directly rather than waiting for a
   notification that may never arrive.

## Transcript invariants

1. The transcript follows new traffic only while the reader is already at the
   bottom. Someone who scrolled up to read something is never pulled away.
2. Delegate heights are not known when a row is appended, so following the tail
   is re-asserted as the view settles rather than once at insertion.
3. A `Flickable`'s plain children are parented into its scrolling content item.
   Anything meant to stay put — the scroll indicator, the empty state — is a
   sibling anchored to the view, never a child of it.
4. The "new" mark outlives the unread count. The count answers "is there
   anything?"; the mark answers "where did I stop?". The mark is cleared when
   the reader actually reaches the tail with the window focused.
5. Reopening a window that has a backlog lands on the mark, not at the bottom.
   So does switching to a space with a backlog.
6. Following the tail happens in the same frame the content grows in.
   Deferring it by even one frame is visible: the transcript jumps up as the
   row is added and then slides back down. This client has no prompt-anchoring
   behaviour — sending snaps to the tail and stays there. Nothing may animate
   contentY towards the end at send time, because that animation would still be
   running when the message returns from the server and the two would fight.
7. The transcript is a `Flickable` holding a `Column` of every message, not a
   `ListView`. This is not a style preference. The physics drives `contentY`
   directly, which is only meaningful when `contentHeight` is measured; a
   `ListView` extrapolates `contentHeight` from the rows it has actually
   built, and with wrapped text of wildly differing heights that estimate is
   wrong by orders of magnitude. Two separate faults came from it: a
   200-message replay put the last row 64,000px above the viewport, and
   ordinary scrolling landed in estimated void with a blank viewport and a
   scroll indicator pointing at a position that did not exist. Laying every
   message out costs memory and startup time, bounded by `messageLimit`, and
   buys an exact `contentHeight`. Do not reintroduce a view that virtualizes
   rows without also replacing the way position is computed.
8. Dropping the oldest message shifts everything below it up by that row's
   height. That is invisible at the tail, where the view is re-pinned to the
   end, and a jump out from under the reader anywhere else — so the active
   space holds its trim while the reader is above the tail, and catches up
   when they return.

## Scrolling

`ScrollPhysics.qml` takes its momentum model from Omarchy Ask, MIT, with the
reasoning intact. Two decisions there are load-bearing and are explained in the
file itself: keyboard motion is integrated frame by frame rather than animated,
and a precision-scroll gesture's stopping distance is animated directly rather
than handed back to `Flickable.flick()`.

The edges give. Because every path writes `contentY` directly, Flickable's own
bounds behaviour never sees these gestures and an edge would otherwise stop
dead. A click wheel notch at an edge gets the same give as a short spring, so
the end reads as an end rather than as a dead input.

Overscroll is held as `slackRaw` — signed distance past an edge, before
damping — and never as an absolute position. That distinction is the design,
and getting it wrong produced three separate faults at the bottom edge:

- **Slack must be bounded.** A trackpad keeps sending momentum events after
  your fingers lift. Unbounded, those pile up thousands of pixels of invisible
  debt that has to be unwound before scrolling back the other way moves
  anything. `slackLimit` caps it; damping means the visible travel saturates
  long before that anyway.
- **Position is recomputed from where the edges are now.** A transcript that
  grows while you hold it past the end would otherwise tear away from the
  gesture, because the remembered absolute position no longer describes the
  end.
- **The spring animates the slack, not the position.** A spring aimed at a
  remembered `contentY` lands short when rows arrive mid-flight, and stays
  there. Animating slack to zero re-targets every frame.

All three are covered by the same rule: nothing stores an absolute position
across a frame in which the content may change.

This also depends on `ListView` keeping an out-of-bounds `contentY` rather than
fixing it up. It does — verified directly — but it is the assumption the whole
effect rests on.

## Who may move the viewport

Every fault in this file's history has been two things writing `contentY` in
the same frame, or one thing writing it from a value that was true in an
earlier frame. The rules that keep that from recurring:

1. Anything that moves the viewport must be visible in `physics.busy`, and
   `keepTail()` must refuse to run while it is set. That includes the
   click-wheel step animation and Flickable's own drag and flick, which move
   `contentY` without going through the physics at all and therefore have to
   announce themselves.
2. A deliberate scroll says so *before* it moves, not after. `userScrolled()`
   means "this was intentional"; the move that follows is what decides whether
   it ended at the tail. The other order lets a gesture that arrives at the
   bottom finish with following switched off, and nothing afterwards turns it
   back on.
3. Nothing may act on a position, row index, or edge collision computed in an
   earlier frame without re-checking it against the present. A trackpad coast
   decides whether it hit an edge when it arrives, not when it starts. A
   restored reading position carries the message's identity, not its row.
4. A gesture's pending release is state. Anything that takes the viewport
   somewhere else has to cancel it, or it fires afterwards and coasts away
   from wherever the viewport was just put.
5. State that gates behaviour must be set from the current value, not only on
   its transitions. `holdTrim` is re-synced after anything that changes which
   space is on screen, because arriving at the same value emits no signal.

## Input routing

A focused `TextEdit` claims navigation keys before a window `Shortcut` sees
them, so every text surface routes its keys through `handleKey()`. The window
also declares `Shortcut`s as a backstop for when nothing inside holds focus.

Qt consumes a matched shortcut before the key reaches the focus item, so only
bindings that mean the same thing everywhere may be declared as shortcuts. The
arrow keys are deliberately absent: inside a multi-line draft they move the
caret, and everywhere else they scroll.

## Theme

Every colour comes from Omarchy's `Color` and `Style` singletons; there are no
hardcoded colours, so a light theme and a dark one are the same code path.

Following a theme *change* is the app's own job. `Color` sets
`watchChanges: false` on the theme files on purpose — inside the shell it is
told about a change over IPC by `omarchy theme set`, so watching would be
duplicated work. An application is never told. As a shell plugin this one was
restarted along with the shell and picked the new palette up by accident; on
its own it would keep whatever palette it launched with, leaving a light window
on a dark desktop until relaunched. `ThemeSync.qml` watches the theme files and
hands them to the same singleton the shell does.

`theme.name` is the trigger rather than the palette files themselves, because
it changes exactly once per switch whether or not the individual files differ.

One consequence for the colours chosen here: selected text stays
`foreground`-coloured. The selection fill is a translucent accent wash over the
page, so text that took the page's own background colour would vanish into it
on a light theme.

## Durable state and privacy

No transcript is written to disk. The client's durable state is the settings
file and one Ed25519 private key per identity. Session tokens stay in memory.
The bridge keeps its machine-readable stream on stdout; stderr carries retry
diagnostics that the status line already summarizes.

Firehose content is untrusted data. It is rendered as plain text — never as
markup, never as a link the client will follow, and never as an instruction.
