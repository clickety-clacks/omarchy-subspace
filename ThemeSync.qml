import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Follow the desktop's theme while running.
//
// Omarchy's Color singleton deliberately does not watch the theme files: the
// shell is *told* about a change over IPC by `omarchy theme set`, so watching
// would be redundant work inside the shell. An application is never told. As a
// shell plugin this app was restarted along with the shell and so picked up
// the new palette by accident; on its own it would keep whatever palette it
// launched with, leaving a light window on a dark desktop until relaunched.
//
// So it watches for itself and hands the new files to the same singleton the
// shell does. theme.name is the trigger rather than the palette files, because
// it changes exactly once per theme switch whether or not the individual files
// happen to differ.
QtObject {
  id: sync

  readonly property string themeDir: Color.currentThemePath
  readonly property string namePath:
    Quickshell.env("HOME") + "/.local/state/omarchy/current/theme.name"

  function apply() {
    colorsFile.reload()
    shellFile.reload()
  }

  property FileView nameFile: FileView {
    path: sync.namePath
    watchChanges: true
    printErrors: false
    // The change signal carries stale content, so both paths go through
    // reload() and read in onLoaded.
    onFileChanged: reload()
    onLoaded: sync.apply()
  }

  property FileView colorsFile: FileView {
    path: sync.themeDir + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      Color.loadColors(text())
      Style.scheduleRefresh()
    }
  }

  property FileView shellFile: FileView {
    path: sync.themeDir + "/shell.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      Color.loadShell(text())
      Style.scheduleRefresh()
    }
  }
}
