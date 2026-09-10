import QtQuick
import Quickshell
import Quickshell.Io

// One connection to one Subspace: its bridge process, its identity, its
// message model, and its unread state. Everything that is per-space lives
// here, so adding a second Subspace is adding a second one of these rather
// than threading a space id through the client.
//
// A QtObject, not an Item: there is nothing to draw, and these are created
// against the application root, which is not a scene to put an Item in.
QtObject {
  id: link

  required property string appDir
  required property var servers          // base URLs, tried in order
  required property string configuredName
  required property string identity
  required property string owner
  required property int messageLimit

  property string connectionState: "starting"
  property string connectionDetail: ""
  property string serverName: ""
  property string serverUrl: ""
  property string agentId: ""
  property int unread: 0
  property string unreadAnchorId: ""
  property int sendSequence: 0
  // Ids already in the model. A reconnect replays the server's buffer, which
  // overlaps everything already on screen; without this the whole history
  // appears a second time. With it, the replay does the opposite and useful
  // thing: it fills in whatever was said while the connection was down.
  property var seenIds: ({})

  // Rejoining replays the server's buffer. Comparing that batch against what
  // is already on screen is the one moment loss can be proven: an overlap
  // means the replay covers everything that happened, and no overlap at all
  // means whatever fell between our newest message and the batch's oldest was
  // dropped from the server's buffer before we got back. Neither the socket
  // nor the server will say so; this is the only evidence there is.
  property bool resuming: false
  property bool resumeOverlap: false
  property int resumeInsertAt: 0
  property string resumeFromTs: ""
  property string resumeOldestTs: ""
  // Set while the reader is somewhere above the tail of this space. Dropping
  // the oldest message shifts everything below it up by that row's height, and
  // doing that under someone reading history jumps the page out from under
  // them. Growth is bounded again the moment they return to the bottom.
  property bool holdTrim: false
  property var pendingSends: ({})

  readonly property bool connected: connectionState === "connected"
  readonly property var messageModel: messages

  // What to call this space in the switcher: what the config named it, else
  // what the server calls itself, else where it is.
  readonly property string displayName: {
    if (configuredName !== "") return configuredName
    if (serverName !== "") return serverName
    if (servers.length === 0) return "subspace"
    return String(servers[0]).replace(/^https?:\/\//, "").replace(/:\d+$/, "")
  }

  signal messageReceived(var space, var event)

  property ListModel messages: ListModel {}

  function start() {
    if (link.bridge.running) return
    if (!servers || servers.length === 0) {
      link.connectionState = "unconfigured"
      return
    }
    link.bridge.running = true
  }

  function stop() {
    if (!link.bridge.running) return
    link.bridge.write(JSON.stringify({ type: "quit" }) + "\n")
    link.bridge.running = false
  }

  function reconnect() {
    link.bridge.running = false
    link.restartTimer.restart()
  }

  function clearUnread() { link.unread = 0 }

  function noteUnread(id) {
    if (link.unreadAnchorId === "") link.unreadAnchorId = String(id || "")
    link.unread += 1
  }

  function indexOfMessage(id) {
    if (String(id || "") === "") return -1
    for (var index = messages.count - 1; index >= 0; index--)
      if (messages.get(index).messageId === id) return index
    return -1
  }

  function send(text) {
    var body = String(text || "").replace(/\s+$/, "")
    if (body === "" || !link.bridge.running) return false
    link.sendSequence += 1
    var ref = link.sendSequence
    var tracked = ({})
    for (var key in link.pendingSends) tracked[key] = link.pendingSends[key]
    tracked[String(ref)] = body
    link.pendingSends = tracked
    link.bridge.write(JSON.stringify({ type: "send", text: body, ref: ref }) + "\n")
    return true
  }

  function forgetSend(ref) {
    var remaining = ({})
    for (var key in link.pendingSends)
      if (key !== String(ref)) remaining[key] = link.pendingSends[key]
    link.pendingSends = remaining
  }

  function beginResume() {
    link.resuming = true
    link.resumeOverlap = false
    link.resumeInsertAt = messages.count
    link.resumeFromTs = messages.count > 0
      ? String(messages.get(messages.count - 1).timestamp) : ""
    link.resumeOldestTs = ""
  }

  // The batch is over at the first live message, or when the replay stops
  // arriving.
  function endResume() {
    resumeSettle.stop()
    if (!link.resuming) return
    link.resuming = false
    if (link.resumeOverlap) return
    if (link.resumeOldestTs === "" || link.resumeFromTs === "") return
    if (Date.parse(link.resumeOldestTs) <= Date.parse(link.resumeFromTs)) return
    if (link.resumeInsertAt > messages.count) return
    messages.insert(link.resumeInsertAt, {
      messageId: "",
      agentId: "",
      agentName: "",
      body: "",
      timestamp: link.resumeOldestTs,
      own: false,
      replay: false,
      grouped: false,
      gap: true
    })
  }

  function appendMessage(event) {
    var id = String(event.id || "")
    if (link.resuming) {
      if (event.replay === true) {
        if (id !== "" && link.seenIds[id] === true) link.resumeOverlap = true
        // The replay arrives oldest first, so the first of the batch is the
        // earliest the server still holds.
        if (link.resumeOldestTs === "") link.resumeOldestTs = String(event.ts || "")
        resumeSettle.restart()
      } else {
        link.endResume()
      }
    }
    if (id !== "" && link.seenIds[id] === true) return
    if (id !== "") link.seenIds[id] = true
    var name = String(event.agentName || "unknown")
    var previous = messages.count > 0 ? messages.get(messages.count - 1) : null
    var timestamp = String(event.ts || "")
    messages.append({
      messageId: String(event.id || ""),
      agentId: String(event.agentId || ""),
      agentName: name,
      body: String(event.text || ""),
      timestamp: timestamp,
      own: event.own === true,
      replay: event.replay === true,
      // Consecutive lines from one agent read as one turn, so only the first
      // carries a name. A pause long enough to be a new thought breaks the run.
      grouped: previous !== null && previous.agentName === name
        && !previous.gap
        && minutesBetween(previous.timestamp, timestamp) < 5,
      gap: false
    })
    if (!link.holdTrim) link.trimNow()
  }

  function trimNow() {
    var excess = messages.count - link.messageLimit
    if (excess <= 0) return
    // Forget what is being dropped, so a later replay of it is allowed back in
    // rather than being mistaken for something already on screen.
    for (var index = 0; index < excess; index++)
      delete link.seenIds[messages.get(index).messageId]
    messages.remove(0, excess)
  }

  function minutesBetween(before, after) {
    var start = Date.parse(before)
    var end = Date.parse(after)
    if (isNaN(start) || isNaN(end)) return 999
    return Math.abs(end - start) / 60000
  }

  function handleBridgeLine(line) {
    var event
    try { event = JSON.parse(String(line || "")) } catch (error) { return }
    var kind = String(event.type || "")

    if (kind === "message") {
      link.appendMessage(event)
      link.messageReceived(link, event)
      return
    }
    if (kind === "status") {
      link.connectionState = String(event.state || "")
      link.connectionDetail = String(event.detail || "")
      // A rejoin with history already on screen is the case worth inspecting;
      // a first connection has nothing to have missed.
      if (String(event.state || "") === "connected" && messages.count > 0)
        link.beginResume()
      return
    }
    if (kind === "identity") { link.agentId = String(event.agentId || ""); return }
    if (kind === "server") {
      link.serverName = String(event.name || "")
      link.serverUrl = String(event.url || "")
      return
    }
    if (kind === "sent") {
      var ref = Number(event.ref || 0)
      if (event.ok !== true)
        link.sendRejected(link, link.pendingSends[String(ref)] || "",
          String(event.detail || "The server refused the message."))
      link.forgetSend(ref)
      return
    }
    if (kind === "fatal") {
      link.connectionState = "fatal"
      link.connectionDetail = String(event.detail || "")
      return
    }
  }

  signal sendRejected(var space, string text, string detail)

  readonly property var bridgeCommand: {
    var command = ["python3", "-u", link.appDir + "/bridge/subspace.py",
      "--identity", link.identity, "--owner", link.owner]
    for (var index = 0; index < link.servers.length; index++)
      command = command.concat(["--url", String(link.servers[index])])
    return command
  }

  property Process bridge: Process {
    command: link.bridgeCommand
    running: false
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { link.handleBridgeLine(line) } }
    stderr: SplitParser {
      // The bridge keeps its machine-readable stream on stdout; stderr carries
      // retry diagnostics that the status line already summarizes.
      onRead: function(line) { }
    }
    onExited: function(code) {
      link.connectionState = "stopped"
      link.connectionDetail = "The Subspace bridge exited (" + code + ")."
      link.restartTimer.restart()
    }
  }

  property Timer resumeSettle: Timer {
    interval: 1500
    repeat: false
    onTriggered: link.endResume()
  }

  property Timer restartTimer: Timer {
    interval: 2000
    repeat: false
    onTriggered: link.start()
  }

  Component.onCompleted: link.start()
  Component.onDestruction: link.stop()
}
