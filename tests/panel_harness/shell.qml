//@ pragma OmarchyLoadPatch
import QtQuick
import QtQuick.Window
import Quickshell
import qs.Commons as Commons
import "plugin"

// Test harness (tests/render_panel.sh): the real PanelContent, Service and helper, in the shell's real theme and
// components, in a plain window with no bar. It runs offscreen with its own HOME and never touches a desktop session.
// Steps (JH_STEPS, comma separated): wait:MS  tab:NAME  today:0|1  bottom  quickadd  confirm  hide:0|1  shot:PATH
ShellRoot {
  id: shellRoot
  readonly property string cli: Quickshell.env("JH_CLI")
  property var steps: String(Quickshell.env("JH_STEPS") || "").split(",").filter(function(s) { return s !== "" })
  property int stepIndex: 0

  Service { id: svc }

  QtObject {
    id: stub
    property var settings: ({ id: "jobhunt.app", cliPath: shellRoot.cli, hideCompanyNames: Quickshell.env("JH_HIDE") === "1",
                              whatsNewFrom: Quickshell.env("JH_WHATSNEW") === "1" ? "0.1.0" : "" })
    function openUrl(url) { console.log("OPEN", url); return true }
    function copyText(text) { console.log("COPY", text) }
    function runAgent(prompt) { console.log("AGENT", prompt) }
    function persistSettings(values) {
      var entry = {}
      for (var k in stub.settings) entry[k] = stub.settings[k]
      for (var key in values) { if (values[key] === undefined) delete entry[key]; else entry[key] = values[key] }
      entry.settingsVersion = 2
      stub.settings = entry
      svc.settings = entry
      console.log("PERSIST", JSON.stringify(values))
    }
  }

  Window {
    id: win
    visible: true
    readonly property int pad: Commons.Style.spacing.popupPadding
    width: Commons.Style.space(420) + pad * 2
    height: Math.round(Math.min(Commons.Style.space(680), content.implicitHeight) + pad * 2)
    color: Commons.Color.popups.background
    Component.onCompleted: svc.initialize(stub.settings)
    Rectangle { anchors.fill: parent; color: Commons.Color.popups.background }   // grabToImage skips the window's own colour
    PanelContent {
      id: content
      x: win.pad; y: win.pad
      width: win.width - win.pad * 2
      height: win.height - win.pad * 2
      jobhunt: svc
      host: stub
      settings: stub.settings
      foreground: Commons.Color.popups.text
      urgent: Commons.Color.urgent
      darkBar: (0.299 * Commons.Color.popups.text.r + 0.587 * Commons.Color.popups.text.g + 0.114 * Commons.Color.popups.text.b) > 0.5
    }
  }

  function grab(path) {
    var scale = parseFloat(Quickshell.env("JH_SCALE") || "1")
    win.contentItem.grabToImage(function(r) { r.saveToFile(path); console.log("SHOT", path, win.width, win.height, scale); step() }, Qt.size(win.width * scale, win.height * scale))
  }
  function step() {
    if (stepIndex >= steps.length) { Qt.quit(); return }
    var s = steps[stepIndex++].split(":")
    var arg = s.slice(1).join(":")
    if (s[0] === "wait") { waitTimer.interval = parseInt(arg); waitTimer.restart() }
    else if (s[0] === "tab") { content.tab = arg; step() }
    else if (s[0] === "bottom") { content.scrollToEnd(); step() }
    else if (s[0] === "today") { content.todayOpen = arg === "1"; step() }
    else if (s[0] === "quickadd") { svc.startSave(); step() }
    else if (s[0] === "confirm") { svc.confirmSave(); step() }
    else if (s[0] === "hide") { stub.persistSettings({ hideCompanyNames: arg === "1" }); step() }
    else if (s[0] === "shot") grab(arg)
    else step()
  }
  Timer { id: waitTimer; onTriggered: shellRoot.step() }
  Component.onCompleted: Qt.callLater(step)
}
