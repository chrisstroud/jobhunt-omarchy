import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import qs.Commons
import qs.Ui

// JobHunt for Omarchy: one bar icon with one quiet number, and a panel that
// opens from it. Data comes from Service.qml (which runs the helper script).
Panel {
  id: root
  moduleName: "service.app"
  ipcTarget: "service.app"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  // The JobHunt figure for the bar, on a 24-unit square: the brand emblem's own shapes (head with the face cut out,
  // body, arm, laptop) without its dark field, grid or accents, the thin laptop parts thickened so they survive 16 px.
  // Filled with the bar's foreground, as the other bar icons are; no plate, border or tile.
  readonly property string barFigure: "M7.71 4.74 L10.65 2.35 L14.53 4.74 L13.31 6.63 L13.08 8.17 L11.95 9.74 L10.96 9.7 L9.83 8.03 L8.26 8.48 L7.67 7.94 Z M10.6 6.45 L13.31 6.63 L13.08 8.17 L11.95 9.74 L10.96 9.7 L9.83 8.03 Z M0 21.65 L2.44 11.05 L7.8 8.44 L11.86 11.41 L13.62 16.56 L12.23 17.01 L9.52 21.65 Z M7.76 16.33 L11.95 16.15 L14.17 16.6 L15.56 16.78 L16.96 17.5 L17.41 18.09 L15.47 18.05 L14.17 17.95 L11.82 17.73 L7.8 17.32 Z M20.39 18.23 L22.56 11.55 L24 11.55 L21.83 18.23 Z M9.38 17.77 L22.02 17.77 L21.56 19.04 L9.11 19.04 Z"

  readonly property bool needsSetup: service.dataState === "cli_missing" || service.dataState === "signed_out"
  // The one number: shown only when something is due, and only while there is data to stand behind it.
  readonly property int shownCount: service.hasData && !needsSetup ? service.dueCount : 0
  readonly property bool darkBar: (0.299 * barForeground.r + 0.587 * barForeground.g + 0.114 * barForeground.b) > 0.5
  property real nowMs: Date.now()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function ageText(value) {
    var then = Date.parse(String(value || ""))
    if (!isFinite(then)) return ""
    var seconds = Math.max(0, Math.floor((nowMs - then) / 1000))
    if (seconds < 60) return "just now"
    if (seconds < 3600) return Math.floor(seconds / 60) + " min ago"
    if (seconds < 86400) return Math.floor(seconds / 3600) + " h ago"
    return Math.floor(seconds / 86400) + " d ago"
  }

  // Bar tooltip: counts and states only, never a company or job name.
  function tooltipText() {
    if (service.dataState === "loading") return "JobHunt"
    if (service.dataState === "cli_missing") return "JobHunt: command not installed"
    if (service.dataState === "signed_out") return "JobHunt: signed out"
    if (!service.hasData) return service.dataState === "offline" ? "JobHunt: offline" : "JobHunt: something went wrong"
    var base = service.dueCount > 0 ? "JobHunt: " + service.dueCount + " to look at today" : "JobHunt: nothing due today"
    if (service.stale) base += " (offline, last read " + ageText(service.fetchedAt) + ")"
    return base
  }

  function openUrl(url) {
    var accepted = urlLauncher.openUrl(url)
    if (accepted) close()
    return accepted
  }

  // Requests to the person's own terminal agent. omarchy-agent runs agents in auto-approve modes, so every prompt
  // is fixed wording (PanelContent.qml, or the helper's templates) plus at most a UUID the helper validated. The exact
  // text is shown in the panel and nothing launches until it is confirmed there.
  function runAgent(prompt) {
    var text = String(prompt || "")
    if (text === "") return
    Util.execArgv(["omarchy-agent", "--prompt", text])
    close()
  }

  function copyText(text) {
    Util.execArgv(["wl-copy", String(text)])
  }

  // Settings live on this widget's entry in shell.json (same approach as the GitHub plugin).
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry.settingsVersion = 2   // 0.1.0 wrote none; every key it did write keeps its name and meaning
    for (var key in values) {
      if (values[key] === undefined) delete entry[key]
      else entry[key] = values[key]
    }
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function applyHostSettings() {
    // The loader assigns bar before settings; wait for it so the first read uses real settings.
    if (!bar) return
    if (service.settingsReady) service.settings = root.settings
    else service.initialize(root.settings)
  }

  // The first read after the update from plugin 0.1.0 says so once. Remember it in the settings now, so the panel can
  // show "what's new" on its next open however long that is, and until the person dismisses it.
  readonly property string pluginVersion: "0.2.0"
  function rememberUpgrade() {
    if (service.upgradedFrom !== "" && String(setting("whatsNewFrom", "")) === "" && String(setting("whatsNewSeen", "")) !== pluginVersion)
      persistSettings({ whatsNewFrom: service.upgradedFrom })
  }
  Connections {
    target: service
    function onUpgradedFromChanged() { root.rememberUpgrade() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      nowMs = Date.now()
      panelBody.reset()
      service.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      // A copied link must not wait around for the next open.
      service.cancelSave()
      service.cancelSignOut()
      panelBody.reset()
    }
  }
  onSettingsChanged: applyHostSettings()
  onBarChanged: if (bar) Qt.callLater(applyHostSettings)

  Service { id: service }

  Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.nowMs = Date.now()
  }

  UrlLauncher {
    id: urlLauncher
    linkBehavior: service.linkBehavior
    onBrowserLaunchRequested: function(argv) { Util.execArgv(argv) }
    onWebAppLaunchRequested: function(argv) { Quickshell.execDetached(argv) }
  }

  TextMetrics {
    id: countMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.bar.iconFont
    text: String(root.shownCount > 99 ? "99+" : root.shownCount)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The icon slot, plus room for the number only when there is one.
    fixedWidth: root.vertical ? -1 : Style.bar.iconSlot + (root.shownCount > 0 ? Math.ceil(countMetrics.width) + Style.space(4) : 0)
    labelText: root.shownCount > 0 ? countMetrics.text : (service.dataState === "error" && !service.hasData ? "!" : "")
    tooltipText: root.tooltipText()
    // Dimmed when there is nothing live to show; never the alarm colour for due items.
    opacity: root.needsSetup || service.stale ? 0.55 : 1
    iconComponent: Component {
      Shape {
        width: 24
        height: 24
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          fillColor: root.foreground
          strokeColor: "transparent"
          strokeWidth: 0
          fillRule: ShapePath.OddEvenFill
          PathSvg { path: root.barFigure }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) service.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panelBody.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(text) {
        if (text === "r" || text === "R") service.refresh()
        else if (panelBody.showApp && (text === "1" || text === "2" || text === "3" || text === "4")) panelBody.tab = ["overview", "board", "docs", "page"][parseInt(text, 10) - 1]
      }

      PanelContent {
        id: panelBody
        anchors.fill: parent
        jobhunt: service
        host: root
        settings: root.settings
        foreground: root.foreground
        urgent: root.urgent
        fontFamily: root.fontFamily
        darkBar: root.darkBar
        nowMs: root.nowMs
      }
    }
  }
}
