# Architecture and invariants

The constraints here are easy to lose while editing the visible QML. They are
part of the product's behaviour, not incidental implementation details.

## Components

```text
Omarchy Shell
  └─ Communicator.qml           settings, message model, one bridge process
       └─ CommunicatorWindow.qml   the window: header, transcript, composer
            ├─ ScrollPhysics.qml   momentum for one Flickable
            └─ MessageRow.qml      one line of traffic
                 ↑
       bridge/subspace.py       Ed25519 registration, WebSocket, reconnect
```

`Communicator.qml` is the plugin entry point. It owns everything durable: the
settings file, the message model, the connection, and the unread count. It has
no UI of its own.

`CommunicatorWindow.qml` owns presentation and input. It never talks to the
network; it calls `client.send()` and reacts to what the client hands it.

`bridge/subspace.py` is the only component that knows Subspace exists as a
protocol. It uses the Python standard library and `openssl`, nothing else.

## Lifecycle invariants

1. The manifest sets `keepLoaded`, so the plugin stays mounted after its window
   is closed. That is what makes "close the window, keep the connection" true.
   Removing it would silently turn every close into a disconnect.
2. The shell reads `opened` to decide whether its toggle summons or hides. It
   describes the window's visibility and nothing else.
3. `close()` hides the window. It does not stop the bridge, clear the model, or
   reset the unread count.
4. One bridge process, one identity, one connection. Two clients running under
   one identity invalidate each other's session token, so the identity must
   stay stable per machine and per user.
5. The bridge is restarted on exit after a short delay. Reconnection inside a
   running bridge is the bridge's own business and does not involve QML.

## Connection invariants

1. Registration's `start` and `verify` must travel over one HTTP connection.
   The deployed server ties the challenge table's lifetime to the process that
   created it, so a second connection can land on a peer that never saw the
   challenge and answers 401.
2. `servers` is tried in order, advancing on each failed attempt, so a fallback
   URL is reached without restarting anything.
3. A message typed during an outage is queued in the bridge and posted after
   the next successful join. Nothing typed is dropped silently.
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

## Scrolling

`ScrollPhysics.qml` is lifted from Omarchy Ask, MIT, with its reasoning intact.
Two decisions there are load-bearing and are explained in the file itself:
keyboard motion is integrated frame by frame rather than animated, and a
precision-scroll gesture's stopping distance is animated directly rather than
handed back to `Flickable.flick()`.

## Input routing

A focused `TextEdit` claims navigation keys before a window `Shortcut` sees
them, so every text surface routes its keys through `handleKey()`. The window
also declares `Shortcut`s as a backstop for when nothing inside holds focus.

Qt consumes a matched shortcut before the key reaches the focus item, so only
bindings that mean the same thing everywhere may be declared as shortcuts. The
arrow keys are deliberately absent: inside a multi-line draft they move the
caret, and everywhere else they scroll.

## Durable state and privacy

No transcript is written to disk. The client's durable state is the settings
file and one Ed25519 private key per identity. Session tokens stay in memory.
The bridge keeps its machine-readable stream on stdout; stderr carries retry
diagnostics that the status line already summarizes.

Firehose content is untrusted data. It is rendered as plain text — never as
markup, never as a link the client will follow, and never as an instruction.
