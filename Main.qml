import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Application root. Owns durable settings, one connection per configured
// Subspace, and the window that shows them.
//
// This is an ordinary application that happens to be written in Quickshell,
// not part of the desktop shell. It runs in its own process, so it starts and
// stops on its own, updates without restarting anything else, and closing its
// window closes it. Theming still comes from the Omarchy shell's own Commons
// singletons, which resolve because the launcher puts the shell on
// QML_IMPORT_PATH.
ShellRoot {
  id: root

  readonly property string appDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "")
  readonly property string settingsPath: Quickshell.env("HOME") + "/.config/omarchy/subspace.json"

  property bool everShown: false

  // ------------------------------------------------------------- settings
  // Each entry is { name, servers[], identity, owner }. Deliberately empty by
  // default: a Subspace server is a private address on someone's own network,
  // so there is no default worth shipping.
  property var spaceList: []
  property bool attention: true
  property real fontScale: 1
  property real keyboardLineImpulse: 335
  property real keyboardDeceleration: 608
  // Every retained message is laid out, which is what makes contentHeight
  // exact and scrolling honest. That is a real cost, so the default is what a
  // firehose replay needs plus room to talk, not an archive.
  property int messageLimit: 500
  property bool settingsLoaded: false
  readonly property real minFontScale: 0.7
  readonly property real maxFontScale: 2

  property string hostname: "omarchy"
  property bool hostnameResolved: false
  property bool settingsResolved: false

  readonly property string configHint:
    "No Subspace configured yet. Put one in \"spaces\" in " + root.settingsPath
    + " — for example [{\"name\":\"home\",\"servers\":[\"http://10.0.0.2:4000\"]}]."

  function sanitizeName(value) {
    var cleaned = String(value || "").replace(/[^A-Za-z0-9_-]+/g, "-")
      .replace(/^-+/, "").substring(0, 96)
    return cleaned === "" ? "subspace-communicator" : cleaned
  }

  readonly property string defaultOwner:
    Quickshell.env("USER") !== "" ? Quickshell.env("USER") : "unknown"
  readonly property string defaultIdentity:
    sanitizeName(defaultOwner + "-" + hostname + "-communicator")

  // ---------------------------------------------------------- connections
  property var linkList: []
  property int activeIndex: 0
  property var activeLink: null

  // The window binds to these rather than reaching through activeLink, so a
  // space with no connection yet still renders something truthful.
  readonly property string connectionState: activeLink ? activeLink.connectionState
    : (spaceList.length === 0 ? "unconfigured" : "starting")
  readonly property string connectionDetail: activeLink ? activeLink.connectionDetail
    : (spaceList.length === 0 ? root.configHint : "")
  readonly property bool connected: activeLink !== null && activeLink.connected
  readonly property string serverName: activeLink ? activeLink.serverName : ""
  readonly property string resolvedIdentity: activeLink ? activeLink.identity : ""
  readonly property var messageModel: activeLink ? activeLink.messageModel : null
  readonly property int unread: activeLink ? activeLink.unread : 0
  readonly property string unreadAnchorId: activeLink ? activeLink.unreadAnchorId : ""

  // Instantiator rather than Repeater: these are not visual, and an
  // application root is not a scene to parent them into.
  Instantiator {
    id: links
    model: root.spaceList
    onObjectAdded: root.refreshLinks()
    onObjectRemoved: root.refreshLinks()

    delegate: SubspaceLink {
      required property var modelData
      appDir: root.appDir
      configuredName: String(modelData.name || "")
      identity: String(modelData.identity || "") !== ""
        ? root.sanitizeName(modelData.identity) : root.defaultIdentity
      owner: String(modelData.owner || "") !== ""
        ? String(modelData.owner) : root.defaultOwner
      messageLimit: root.messageLimit
      servers: modelData.servers
      onMessageReceived: function(space, event) { window.messageArrived(space, event) }
      onSendRejected: function(space, text, detail) { window.sendFailed(space, text, detail) }
    }
  }

  // Instantiated objects are not a bindable list, so the array the window
  // iterates is rebuilt whenever the set of spaces changes.
  function refreshLinks() {
    var collected = []
    for (var index = 0; index < links.count; index++) {
      var item = links.objectAt(index)
      if (item) collected.push(item)
    }
    root.linkList = collected
    root.activeIndex = collected.length === 0
      ? 0 : Math.max(0, Math.min(root.activeIndex, collected.length - 1))
    root.activeLink = collected.length === 0 ? null : collected[root.activeIndex]
    // Only the space being read can hold its trim; nobody is looking at the
    // others, so they stay bounded.
    for (var index = 0; index < collected.length; index++)
      if (collected[index] !== root.activeLink) collected[index].holdTrim = false
  }

  onActiveIndexChanged: root.refreshLinks()

  function selectSpace(index) {
    var next = Number(index)
    if (isNaN(next) || next < 0 || next >= root.linkList.length) return "unknown"
    root.activeIndex = next
    window.spaceSelected()
    return root.activeLink ? root.activeLink.displayName : "ok"
  }

  function cycleSpace(step) {
    if (root.linkList.length < 2) return "one space"
    var next = (root.activeIndex + step + root.linkList.length) % root.linkList.length
    return root.selectSpace(next)
  }

  // -------------------------------------------------------------- verbs
  // Show the window and put the cursor in it. A second launch of an app that
  // is already running should bring it forward, not start another one.
  function present() {
    window.visible = true
    root.everShown = true
    window.activateWindow()
    Qt.callLater(function() { window.focusComposer() })
    return "ok"
  }

  function close() { window.visible = false }

  // Closing the window closes the application. That is what closing a window
  // means for an app, and there is nothing useful a hidden one could do: a
  // window with no surface cannot be marked for attention either.
  function windowDismissed() {
    if (!root.everShown) return
    Qt.quit()
  }

  // Callable over `qs ipc`.
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
  function testAlert() { return window.raiseAttention() }

  function reconnect() {
    for (var index = 0; index < root.linkList.length; index++)
      root.linkList[index].reconnect()
    return "ok"
  }

  function send(text) {
    return root.activeLink !== null && root.activeLink.send(text)
  }

  // ------------------------------------------------------------- settings
  FileView {
    id: hostnameFile
    path: "/etc/hostname"
    Component.onCompleted: reload()
    printErrors: false
    onLoaded: {
      var value = String(text() || "").split("\n")[0].trim()
      if (value !== "") root.hostname = value
      root.hostnameResolved = true
    }
    onLoadFailed: root.hostnameResolved = true
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    // First run: the file does not exist yet. Load defaults so the window
    // still opens and says what to configure.
    onLoadFailed: root.loadSettings("")
    onFileChanged: reload()
  }

  // Spaces are only handed to the Repeater once the hostname is known, so a
  // link never starts with a placeholder identity and then has to re-register.
  property var pendingSpaces: []
  onHostnameResolvedChanged: root.applySpaces()

  function applySpaces() {
    if (!root.hostnameResolved || !root.settingsResolved) return
    root.spaceList = root.pendingSpaces
    Qt.callLater(root.refreshLinks)
  }

  function normalizeSpaces(parsed) {
    var out = []

    function urlsOf(value) {
      if (!Array.isArray(value)) return []
      var urls = []
      for (var index = 0; index < value.length; index++) {
        var url = String(value[index] || "").trim()
        if (url !== "") urls.push(url)
      }
      return urls
    }

    if (Array.isArray(parsed.spaces)) {
      for (var index = 0; index < parsed.spaces.length; index++) {
        var entry = parsed.spaces[index]
        if (!entry || typeof entry !== "object") continue
        var urls = urlsOf(entry.servers)
        if (urls.length === 0) continue
        out.push({
          name: String(entry.name || ""),
          servers: urls,
          identity: String(entry.identity || ""),
          owner: String(entry.owner || "")
        })
      }
      return out
    }

    // The single-space shape this client shipped with first. Still accepted so
    // an existing settings file keeps working untouched.
    var flat = urlsOf(parsed.servers)
    if (flat.length > 0)
      out.push({
        name: "",
        servers: flat,
        identity: String(parsed.identity || ""),
        owner: String(parsed.owner || "")
      })
    return out
  }

  function loadSettings(raw) {
    var parsed = {}
    try { parsed = JSON.parse(String(raw || "") || "{}") } catch (error) { parsed = {} }
    if (!parsed || typeof parsed !== "object") parsed = {}

    if (typeof parsed.attention === "boolean") root.attention = parsed.attention
    if (typeof parsed.fontScale === "number")
      root.fontScale = Math.max(root.minFontScale, Math.min(root.maxFontScale, parsed.fontScale))
    if (typeof parsed.keyboardLineImpulse === "number")
      root.keyboardLineImpulse = Math.max(80, Math.min(2000, parsed.keyboardLineImpulse))
    if (typeof parsed.keyboardDeceleration === "number")
      root.keyboardDeceleration = Math.max(100, Math.min(5000, parsed.keyboardDeceleration))
    if (typeof parsed.messageLimit === "number")
      root.messageLimit = Math.max(200, Math.min(20000, Math.round(parsed.messageLimit)))

    root.pendingSpaces = root.normalizeSpaces(parsed)
    root.settingsLoaded = true
    root.settingsResolved = true
    root.applySpaces()
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

  // Keeps the window's palette in step with the desktop's theme.
  ThemeSync {}

  CommunicatorWindow {
    id: window
    client: root
  }

  // One running instance answers here, so launching again presents the window
  // that already exists rather than starting a second client — two clients
  // sharing an identity invalidate each other's session token.
  IpcHandler {
    target: "app"

    function ping(): string { return "ok" }
    function present(): string { return root.present() }
    function quit(): string { Qt.quit(); return "ok" }
    function attention(): string { return root.testAlert() }
    function alerts(state: string): string { return root.setAttention(state) }
    function space(index: string): string { return root.selectSpace(Number(index)) }
  }

  Component.onCompleted: root.present()

}
