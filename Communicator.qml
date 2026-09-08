import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Plugin entry point. Owns durable settings, the one bridge process, the one
// message model, and the window that shows them. The shell keeps this item
// loaded (`keepLoaded` in the manifest) so the connection survives closing the
// window: traffic that arrives while you are away is still there when you
// come back.
Item {
  id: root

  // Set by the shell when the plugin loads.
  property var shell: null
  property var manifest: null

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "")
  readonly property string settingsPath: Quickshell.env("HOME") + "/.config/omarchy/subspace.json"

  // The shell reads `opened` to decide whether its toggle summons or hides.
  readonly property bool opened: window.visible

  // ------------------------------------------------------------- settings
  // Deliberately empty: a Subspace server is a private address on someone's
  // own network, so there is no default worth shipping. The window says what
  // to configure until one is set.
  property var servers: []
  property string identity: ""
  property string owner: ""
  property bool attention: true
  property real fontScale: 1
  property real keyboardLineImpulse: 335
  property real keyboardDeceleration: 608
  property int messageLimit: 1500
  property bool settingsLoaded: false
  readonly property real minFontScale: 0.7
  readonly property real maxFontScale: 2

  readonly property string resolvedOwner: owner !== "" ? owner
    : (Quickshell.env("USER") !== "" ? Quickshell.env("USER") : "unknown")
  readonly property string resolvedIdentity: identity !== "" ? identity
    : sanitizeName(resolvedOwner + "-" + hostname + "-communicator")
  property string hostname: "omarchy"

  function sanitizeName(value) {
    var cleaned = String(value || "").replace(/[^A-Za-z0-9_-]+/g, "-")
      .replace(/^-+/, "").substring(0, 96)
    return cleaned === "" ? "subspace-communicator" : cleaned
  }

  // ------------------------------------------------------ connection state
  property string connectionState: "starting"
  property string connectionDetail: ""
  property string serverName: ""
  property string serverUrl: ""
  property string agentId: ""
  property int unread: 0
  property int sendSequence: 0
  property var pendingSends: ({})

  readonly property bool connected: connectionState === "connected"

  ListModel { id: messages }
  readonly property var messageModel: messages

  // ----------------------------------------------------------- shell verbs
  function open(payload) {
    window.visible = true
    window.activateWindow()
    Qt.callLater(function() { window.focusComposer() })
  }

  function close() {
    window.visible = false
  }

  function toggle() { opened ? close() : open("{}") }

  // Callable over `omarchy-shell shell call clickety-clacks.subspace ...`.
  function setAttention(value) {
    var next = String(value) === "true" || value === true
    if (next === root.attention) return root.attention ? "on" : "off"
    root.attention = next
    saveTimer.restart()
    return next ? "on" : "off"
  }

  function toggleAttention() { return setAttention(!root.attention) }

  // Ask the compositor for attention right now. Whether urgency does anything
  // visible is the desktop's business, not this client's, so there has to be a
  // way to find out which side is quiet.
  function testAlert() {
    return window.raiseAttention()
  }

  function reconnect() {
    bridge.running = false
    restartTimer.restart()
    return "ok"
  }

  // ------------------------------------------------------------- messages
  function appendMessage(event) {
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
        && minutesBetween(previous.timestamp, timestamp) < 5
    })
    while (messages.count > root.messageLimit) messages.remove(0, 1)
  }

  function minutesBetween(before, after) {
    var start = Date.parse(before)
    var end = Date.parse(after)
    if (isNaN(start) || isNaN(end)) return 999
    return Math.abs(end - start) / 60000
  }

  function send(text) {
    var body = String(text || "").replace(/\s+$/, "")
    if (body === "") return false
    if (!bridge.running) return false
    root.sendSequence += 1
    var ref = root.sendSequence
    var tracked = ({})
    for (var key in root.pendingSends) tracked[key] = root.pendingSends[key]
    tracked[String(ref)] = body
    root.pendingSends = tracked
    bridge.write(JSON.stringify({ type: "send", text: body, ref: ref }) + "\n")
    return true
  }

  function forgetSend(ref) {
    var remaining = ({})
    for (var key in root.pendingSends)
      if (key !== String(ref)) remaining[key] = root.pendingSends[key]
    root.pendingSends = remaining
  }

  // --------------------------------------------------------------- bridge
  function handleBridgeLine(line) {
    var event
    try { event = JSON.parse(String(line || "")) } catch (error) { return }
    var kind = String(event.type || "")

    if (kind === "message") {
      root.appendMessage(event)
      window.messageArrived(event)
      return
    }
    if (kind === "status") {
      root.connectionState = String(event.state || "")
      root.connectionDetail = String(event.detail || "")
      return
    }
    if (kind === "identity") {
      root.agentId = String(event.agentId || "")
      return
    }
    if (kind === "server") {
      root.serverName = String(event.name || "")
      root.serverUrl = String(event.url || "")
      return
    }
    if (kind === "sent") {
      var ref = Number(event.ref || 0)
      if (event.ok !== true) window.sendFailed(root.pendingSends[String(ref)] || "",
        String(event.detail || "The server refused the message."))
      root.forgetSend(ref)
      return
    }
    if (kind === "fatal") {
      root.connectionState = "fatal"
      root.connectionDetail = String(event.detail || "")
      return
    }
  }

  readonly property var bridgeCommand: {
    var command = ["python3", "-u", root.pluginDir + "/bridge/subspace.py",
      "--identity", root.resolvedIdentity, "--owner", root.resolvedOwner]
    for (var index = 0; index < root.servers.length; index++)
      command = command.concat(["--url", String(root.servers[index])])
    return command
  }

  Process {
    id: bridge
    command: root.bridgeCommand
    running: false
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleBridgeLine(line) } }
    stderr: SplitParser {
      // The bridge keeps its machine-readable stream on stdout; stderr carries
      // retry diagnostics that the status line already summarizes.
      onRead: function(line) { }
    }
    onExited: function(code) {
      root.connectionState = "stopped"
      root.connectionDetail = "The Subspace bridge exited (" + code + ")."
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 2000
    repeat: false
    onTriggered: root.startBridge()
  }

  function startBridge() {
    if (!root.settingsResolved || !root.hostnameResolved || bridge.running) return
    if (root.servers.length === 0) {
      root.connectionState = "unconfigured"
      root.connectionDetail = "No Subspace server yet. Put its base URL in "
        + "\"servers\" in " + root.settingsPath + " — for example "
        + "[\"http://10.0.0.2:4000\"]."
      return
    }
    bridge.running = true
  }

  // ------------------------------------------------------------- settings
  FileView {
    id: hostnameFile
    path: "/etc/hostname"
    printErrors: false
    onLoaded: {
      var value = String(text() || "").split("\n")[0].trim()
      if (value !== "") root.hostname = value
      root.startWhenReady()
    }
    onLoadFailed: root.startWhenReady()
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    // First run: the file does not exist yet. Load defaults so the client
    // still starts and so the first preference change can be written.
    onLoadFailed: root.loadSettings("")
    onFileChanged: reload()
  }

  property bool hostnameResolved: false
  property bool settingsResolved: false

  function startWhenReady() {
    root.hostnameResolved = true
    root.startBridge()
  }

  function loadSettings(raw) {
    var parsed = {}
    try { parsed = JSON.parse(String(raw || "") || "{}") } catch (error) { parsed = {} }
    if (!parsed || typeof parsed !== "object") parsed = {}

    if (Array.isArray(parsed.servers) && parsed.servers.length > 0) {
      var urls = []
      for (var index = 0; index < parsed.servers.length; index++) {
        var url = String(parsed.servers[index] || "").trim()
        if (url !== "") urls.push(url)
      }
      if (urls.length > 0) root.servers = urls
    }
    if (typeof parsed.identity === "string") root.identity = String(parsed.identity).trim()
    if (typeof parsed.owner === "string") root.owner = String(parsed.owner).trim()
    if (typeof parsed.attention === "boolean") root.attention = parsed.attention
    if (typeof parsed.fontScale === "number")
      root.fontScale = Math.max(root.minFontScale, Math.min(root.maxFontScale, parsed.fontScale))
    if (typeof parsed.keyboardLineImpulse === "number")
      root.keyboardLineImpulse = Math.max(80, Math.min(2000, parsed.keyboardLineImpulse))
    if (typeof parsed.keyboardDeceleration === "number")
      root.keyboardDeceleration = Math.max(100, Math.min(5000, parsed.keyboardDeceleration))
    if (typeof parsed.messageLimit === "number")
      root.messageLimit = Math.max(200, Math.min(20000, Math.round(parsed.messageLimit)))

    root.settingsLoaded = true
    root.settingsResolved = true
    root.startBridge()
  }

  function saveSettings() {
    if (!root.settingsLoaded) return
    // Merge into whatever is on disk: this file is small, but it is a user's
    // file and may hold keys a later version added.
    var current = {}
    try { current = JSON.parse(settingsFile.text() || "{}") } catch (error) { current = {} }
    if (!current || typeof current !== "object") current = {}
    current.attention = root.attention
    current.fontScale = Math.round(root.fontScale * 100) / 100
    current.keyboardLineImpulse = Math.round(root.keyboardLineImpulse)
    current.keyboardDeceleration = Math.round(root.keyboardDeceleration)
    settingsFile.setText(JSON.stringify(current, null, 2) + "\n")
  }

  Timer {
    id: saveTimer
    interval: 250
    repeat: false
    onTriggered: root.saveSettings()
  }

  function setFontScale(value) {
    root.fontScale = Math.max(root.minFontScale,
      Math.min(root.maxFontScale, Math.round(value * 100) / 100))
    saveTimer.restart()
  }

  function stepFontScale(step) { root.setFontScale(root.fontScale + step) }

  CommunicatorWindow {
    id: window
    client: root
  }

  Component.onCompleted: hostnameFile.reload()
  Component.onDestruction: {
    if (bridge.running) bridge.write(JSON.stringify({ type: "quit" }) + "\n")
    bridge.running = false
  }
}
