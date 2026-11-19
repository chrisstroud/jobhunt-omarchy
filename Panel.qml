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
  moduleName: "jobhunt.app"
  ipcTarget: "jobhunt.app"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  // The JobHunt figure for the bar, on a 24-unit square: the brand emblem's own shapes (head with the face cut out,
  // body, arm, laptop) without its dark field, grid or accents, the thin laptop parts thickened so they survive 16 px.
  // Filled with the bar's foreground, as the other bar icons are; no plate, border or tile.
  readonly property string barFigure: "M7.71 4.74 L10.65 2.35 L14.53 4.74 L13.31 6.63 L13.08 8.17 L11.95 9.74 L10.96 9.7 L9.83 8.03 L8.26 8.48 L7.67 7.94 Z M10.6 6.45 L13.31 6.63 L13.08 8.17 L11.95 9.74 L10.96 9.7 L9.83 8.03 Z M0 21.65 L2.44 11.05 L7.8 8.44 L11.86 11.41 L13.62 16.56 L12.23 17.01 L9.52 21.65 Z M7.76 16.33 L11.95 16.15 L14.17 16.6 L15.56 16.78 L16.96 17.5 L17.41 18.09 L15.47 18.05 L14.17 17.95 L11.82 17.73 L7.8 17.32 Z M20.39 18.23 L22.56 11.55 L24 11.55 L21.83 18.23 Z M9.38 17.77 L22.02 17.77 L21.56 19.04 L9.11 19.04 Z"

  readonly property string cmdInstall: "npm i -g jobhunt@0.1.2"
  readonly property string cmdLogin: "jobhunt auth login"
  readonly property string cmdMcp: "claude mcp add --transport http jobhunt https://jobhunt.app/mcp"
  readonly property string promptNext: "In JobHunt, tell me what I should do next. Do not change anything."

  readonly property bool needsSetup: jobhunt.dataState === "cli_missing" || jobhunt.dataState === "signed_out"
  readonly property var todayRows: jobhunt.due.filter(function(row) { return row.bucket === "today" })
  readonly property var laterRows: jobhunt.due.filter(function(row) { return row.bucket !== "today" })
  // The one number: shown only when something is due, and only while there is data to stand behind it.
  readonly property int shownCount: jobhunt.hasData && !needsSetup ? jobhunt.dueCount : 0
  readonly property bool darkBar: (0.299 * barForeground.r + 0.587 * barForeground.g + 0.114 * barForeground.b) > 0.5
  property real nowMs: Date.now()

  // One spacing scale, from the shell's own tokens: between sections, between blocks in a section,
  // and between a label and what it labels. The site's square corners for this plugin's own surfaces.
  readonly property int gapSection: Style.spacing.panelGap
  readonly property int gapBlock: Style.spacing.lg
  readonly property int gapTight: Style.spacing.sm
  readonly property int surfacePad: Style.spacing.xl
  // "More ways to connect" on the sign-in panel: closed each time the panel opens.
  property bool moreWays: false

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

  function plural(n, one, other) { return n + " " + (n === 1 ? one : other) }

  function whenLabel(row) {
    var days = Number(row.days)
    var text
    if (days < 0) text = "Overdue by " + plural(-days, "day", "days")
    else if (days === 0) text = "Today"
    else if (days === 1) text = "Tomorrow"
    else {
      var d = new Date(String(row.on) + "T12:00:00")
      text = isFinite(d.getTime()) ? d.toLocaleDateString(Qt.locale(), "ddd d MMM") : "In " + plural(days, "day", "days")
    }
    if (String(row.time || "") !== "") text += " at " + row.time
    return text
  }

  function summaryText() {
    if (jobhunt.dataState === "loading") return "Reading JobHunt…"
    if (jobhunt.dataState === "cli_missing") return "JobHunt command not installed"
    if (jobhunt.dataState === "signed_out") return "Signed out"
    if (!jobhunt.hasData) return jobhunt.dataState === "offline" ? "Offline" : "Something went wrong"
    var line = jobhunt.dueCount > 0 ? jobhunt.dueCount + " to look at today" : "Nothing due today"
    var age = ageText(jobhunt.fetchedAt)
    if (jobhunt.stale && age !== "") line += " · last read " + age
    return line
  }

  // Bar tooltip: counts and states only, never a company or job name.
  function tooltipText() {
    if (jobhunt.dataState === "loading") return "JobHunt"
    if (jobhunt.dataState === "cli_missing") return "JobHunt: command not installed"
    if (jobhunt.dataState === "signed_out") return "JobHunt: signed out"
    if (!jobhunt.hasData) return jobhunt.dataState === "offline" ? "JobHunt: offline" : "JobHunt: something went wrong"
    var base = jobhunt.dueCount > 0 ? "JobHunt: " + jobhunt.dueCount + " to look at today" : "JobHunt: nothing due today"
    if (jobhunt.stale) base += " (offline, last read " + ageText(jobhunt.fetchedAt) + ")"
    return base
  }

  function openUrl(url) {
    var accepted = urlLauncher.openUrl(url)
    if (accepted) close()
    return accepted
  }

  // Requests to the person's own terminal agent. omarchy-agent runs agents in auto-approve modes,
  // so every prompt is fixed wording (this file, or the helper's fixed templates) plus at most a
  // UUID the helper validated. The exact text is shown and nothing launches until it is confirmed.
  property string pendingPrompt: ""

  function askAgent(prompt) {
    pendingPrompt = String(prompt || "")
    if (panelFlick) panelFlick.contentY = 0  // the confirmation sits at the top of the panel
  }

  function launchPending() {
    var text = pendingPrompt
    pendingPrompt = ""
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
    if (jobhunt.settingsReady) jobhunt.settings = root.settings
    else jobhunt.initialize(root.settings)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      nowMs = Date.now()
      if (panelFlick) panelFlick.contentY = 0
      jobhunt.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      // A copied link must not wait around for the next open.
      jobhunt.cancelSave()
      jobhunt.cancelSignOut()
      pendingPrompt = ""
      moreWays = false
    }
  }
  onSettingsChanged: applyHostSettings()
  onBarChanged: if (bar) Qt.callLater(applyHostSettings)

  Service { id: jobhunt }

  Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.nowMs = Date.now()
  }

  UrlLauncher {
    id: urlLauncher
    linkBehavior: jobhunt.linkBehavior
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
    labelText: root.shownCount > 0 ? countMetrics.text : (jobhunt.dataState === "error" && !jobhunt.hasData ? "!" : "")
    tooltipText: root.tooltipText()
    // Dimmed when there is nothing live to show; never the alarm colour for due items.
    opacity: root.needsSetup || jobhunt.stale ? 0.55 : 1
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
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) jobhunt.refresh()
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
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(text) {
        if (text === "r" || text === "R") jobhunt.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: panelColumn
          width: panelFlick.width
          spacing: root.gapSection

          PanelHero {
            width: parent.width
            title: "JobHunt"
            meta: root.summaryText()
            foreground: root.foreground
            fontFamily: root.fontFamily
            trailingControl: Component {
              PanelActionButton {
                iconText: "\u{f0450}"
                tooltipText: jobhunt.loading ? "Reading JobHunt" : "Refresh"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: jobhunt.refresh()
              }
            }
            iconComponent: Component {
              Image {
                width: Style.font.display
                height: Style.font.display
                sourceSize: Qt.size(Style.font.display * 4, Style.font.display * 4)
                fillMode: Image.PreserveAspectFit
                smooth: true
                source: Qt.resolvedUrl(root.darkBar ? "assets/jobhunt-emblem-on-dark.svg" : "assets/jobhunt-emblem-on-light.svg")
              }
            }
          }

          // Offline or error, with or without older data to show.
          BorderSurface {
            visible: !root.needsSetup && jobhunt.dataState !== "ok" && jobhunt.dataState !== "loading"
            width: parent.width
            implicitHeight: statusText.implicitHeight + root.surfacePad * 2
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
            borderSpec: Border.flat(Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35), 1)
            radius: 0
            Text {
              id: statusText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: root.surfacePad
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: jobhunt.message + (jobhunt.hasData ? " This is what was read " + root.ageText(jobhunt.fetchedAt) + "." : "")
            }
          }

          // The exact request, shown before it is sent to the agent.
          BorderSurface {
            visible: root.pendingPrompt !== ""
            width: parent.width
            implicitHeight: promptColumn.implicitHeight + root.surfacePad * 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            borderSpec: Border.flat(Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25), 1)
            radius: 0
            Column {
              id: promptColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: root.surfacePad
              spacing: root.gapBlock
              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                text: "This exact request will be sent to your agent, which may act on your JobHunt account:"
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WrapAnywhere
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                text: root.pendingPrompt
              }
              Row {
                spacing: root.gapBlock
                Button {
                  text: "Send to my agent"
                  selected: true
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.launchPending()
                }
                Button {
                  text: "Cancel"
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.pendingPrompt = ""
                }
              }
            }
          }

          // ---- Setup (CLI missing or signed out) ----
          // One sentence and the one action; other ways to connect wait behind a quiet disclosure.
          Column {
            visible: root.needsSetup
            width: parent.width
            spacing: root.gapBlock
            PanelSeparator { foreground: root.foreground }
            SectionLabel { text: jobhunt.dataState === "cli_missing" ? "SET UP" : "SIGN IN" }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              lineHeight: 1.2
              text: jobhunt.dataState === "cli_missing"
                ? "Install the JobHunt command, then sign in to see what needs you today."
                : "Sign in to see what needs you today. JobHunt opens in your browser and asks you to approve."
            }
            CommandRow { visible: jobhunt.dataState === "cli_missing"; label: "Install the command"; command: root.cmdInstall }
            CommandRow { visible: jobhunt.dataState === "cli_missing"; label: "Then sign in"; command: root.cmdLogin }
            Button {
              visible: jobhunt.dataState === "signed_out" && jobhunt.loginState !== "waiting"
              text: "Sign in to JobHunt"
              selected: true
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              onClicked: jobhunt.startLogin()
            }
            Row {
              visible: jobhunt.dataState === "signed_out" && jobhunt.loginState === "waiting"
              spacing: root.gapBlock
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                text: "Waiting for you to approve in your browser\u2026"
              }
              Button {
                text: "Cancel"
                foreground: root.dim
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: jobhunt.cancelLogin()
              }
            }
            Text {
              visible: jobhunt.dataState === "signed_out" && jobhunt.loginState === "failed"
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: jobhunt.loginMessage + " You can try again."
            }
            Row {
              spacing: root.gapBlock
              Button {
                text: root.moreWays ? "Fewer ways to connect" : "More ways to connect"
                foreground: root.dim
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: 0
                onClicked: root.moreWays = !root.moreWays
              }
              Button {
                text: "Check again"
                foreground: root.dim
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: jobhunt.refresh()
              }
            }
            Column {
              visible: root.moreWays
              width: parent.width
              spacing: root.gapBlock
              CommandRow { visible: jobhunt.dataState === "signed_out"; label: "Or sign in from a terminal"; command: root.cmdLogin }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                text: "To let Claude Code use JobHunt too, run this once. This plugin never changes your agent settings."
              }
              CommandRow { label: "Connect Claude Code"; command: root.cmdMcp }
            }
          }

          // ---- Today ----
          Column {
            visible: !root.needsSetup && jobhunt.hasData
            width: parent.width
            spacing: root.gapTight
            PanelSeparator { foreground: root.foreground }
            SectionLabel { text: "TODAY" }
            Text {
              visible: root.todayRows.length === 0
              width: parent.width
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: "Nothing due today."
            }
            Repeater {
              model: root.todayRows
              delegate: DueRow { required property var modelData; row: modelData }
            }
            SectionLabel {
              visible: root.laterRows.length > 0
              quiet: true
              topPadding: root.gapBlock
              text: "LATER THIS WEEK"
            }
            Repeater {
              model: root.laterRows
              delegate: DueRow { required property var modelData; row: modelData }
            }
          }

          // ---- Momentum ----
          Column {
            visible: !root.needsSetup && jobhunt.hasData
            width: parent.width
            spacing: root.gapBlock
            PanelSeparator { foreground: root.foreground }
            SectionLabel { text: "MOMENTUM" }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: jobhunt.momentum.available
                ? root.plural(Number(jobhunt.momentum.recorded_actions) || 0, "recorded action", "recorded actions") + " on " + root.plural(Number(jobhunt.momentum.active_days) || 0, "day", "days") + ", in the last " + root.plural(Number(jobhunt.momentum.window_days) || 0, "day", "days") + "."
                : "Activity is not available right now."
            }
            ActivityGraph { visible: jobhunt.momentum.available; weeks: jobhunt.momentum.weeks }
          }

          // ---- Pipeline ----
          Column {
            visible: !root.needsSetup && jobhunt.hasData && jobhunt.pipeline.length > 0
            width: parent.width
            spacing: root.gapTight
            PanelSeparator { foreground: root.foreground }
            SectionLabel { text: "PIPELINE" }
            Repeater {
              model: jobhunt.pipeline
              delegate: Item {
                required property var modelData
                width: parent.width
                implicitHeight: Math.max(stageName.implicitHeight, stageCount.implicitHeight) + Style.space(4)
                Text {
                  id: stageName
                  anchors.left: parent.left
                  anchors.right: stageCount.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: modelData.name
                  color: Number(modelData.jobs) > 0 ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  id: stageCount
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: String(Number(modelData.jobs) || 0)
                  color: Number(modelData.jobs) > 0 ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          // ---- Actions ----
          Column {
            visible: !root.needsSetup
            width: parent.width
            spacing: root.gapBlock
            PanelSeparator { foreground: root.foreground }
            SectionLabel { text: "ACTIONS" }

            Flow {
              width: parent.width
              spacing: root.gapBlock
              Button {
                visible: jobhunt.saveState === "idle" || jobhunt.saveState === "done" || jobhunt.saveState === "failed"
                text: "Save job from clipboard"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: jobhunt.startSave()
              }
              Button {
                text: "What should I do next?"
                foreground: root.dim
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.askAgent(root.promptNext)
              }
              Button {
                text: "Open JobHunt"
                foreground: root.dim
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.openUrl("https://jobhunt.app/app")
              }
            }

            // Confirm before anything is written.
            Column {
              visible: jobhunt.saveState === "confirm" || jobhunt.saveState === "saving"
              width: parent.width
              spacing: Style.space(6)
              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WrapAnywhere
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                text: "Save this link to JobHunt?"
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WrapAnywhere
                maximumLineCount: 4
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                text: jobhunt.saveUrl
              }
              Row {
                spacing: Style.space(8)
                Button {
                  text: jobhunt.saveState === "saving" ? "Saving…" : "Save this job"
                  enabled: jobhunt.saveState === "confirm"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: jobhunt.confirmSave()
                }
                Button {
                  text: "Cancel"
                  enabled: jobhunt.saveState === "confirm"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: jobhunt.cancelSave()
                }
              }
            }
            Text {
              visible: jobhunt.saveState === "done" || jobhunt.saveState === "failed"
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: jobhunt.saveState === "failed" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: jobhunt.saveMessage
            }
          }

          // ---- Privacy ----
          Column {
            width: parent.width
            spacing: root.gapBlock
            PanelSeparator { foreground: root.foreground }
            SectionLabel { text: "PRIVACY" }
            Toggle {
              width: parent.width
              label: "Hide company names"
              description: "For shared screens. Names stay out of this panel."
              checked: jobhunt.hideCompany
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              onClicked: root.persistSettings({ hideCompanyNames: !jobhunt.hideCompany })
            }
            Button {
              visible: !root.needsSetup && jobhunt.dataState !== "loading" && jobhunt.signOutState === "idle"
              text: "Sign out of JobHunt"
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: jobhunt.requestSignOut()
            }
            Column {
              visible: jobhunt.signOutState !== "idle"
              width: parent.width
              spacing: root.gapBlock
              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                text: "Sign out of JobHunt on this computer? The data this plugin saved is cleared too."
              }
              Row {
                spacing: Style.space(8)
                Button {
                  text: jobhunt.signOutState === "working" ? "Signing out\u2026" : "Sign out"
                  enabled: jobhunt.signOutState === "confirm"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: jobhunt.confirmSignOut()
                }
                Button {
                  text: "Cancel"
                  enabled: jobhunt.signOutState === "confirm"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: jobhunt.cancelSignOut()
                }
              }
            }
            Text {
              visible: jobhunt.signOutMessage !== ""
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: jobhunt.signOutMessage
            }
          }
        }
      }
    }
  }

  // A section's label as the website sets one (/brand): a small square, then tracked capitals. The square
  // takes the theme's accent, so the plugin keeps following the Omarchy theme. `quiet`: a sub-label, no square.
  component SectionLabel: Row {
    property string text: ""
    property bool quiet: false
    spacing: Style.spacing.md
    Rectangle {
      visible: !parent.quiet
      anchors.verticalCenter: parent.verticalCenter
      width: Style.spacing.md
      height: Style.spacing.md
      color: Color.accent
    }
    PanelSectionHeader {
      text: parent.text
      foreground: parent.quiet ? root.dim : root.foreground
      fontFamily: root.fontFamily
      font.letterSpacing: Style.font.caption * 0.14
    }
  }

  // A command shown as text, with a button that copies it.
  component CommandRow: Column {
    id: cmd
    property string label: ""
    property string command: ""
    width: parent ? parent.width : 0
    spacing: root.gapTight
    Text {
      width: parent.width
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      text: cmd.label
    }
    Row {
      width: parent.width
      spacing: Style.space(8)
      TextEdit {
        id: cmdText
        width: parent.width - copyButton.width - Style.space(8)
        readOnly: true
        selectByMouse: true
        textFormat: TextEdit.PlainText
        wrapMode: TextEdit.WrapAnywhere
        text: cmd.command
        color: root.foreground
        selectionColor: Color.accent
        font.family: "monospace"
        font.pixelSize: Style.font.bodySmall
      }
      Button {
        id: copyButton
        text: "Copy"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: root.copyText(cmd.command)
      }
    }
  }

  // One due item. Click opens it on jobhunt.app; the small button hands a request to the agent.
  component DueRow: Item {
    id: dueRow
    property var row: ({})
    readonly property string subject: [String(row.job_title || ""), String(row.company || "")].filter(function(part) { return part !== "" }).join(" · ")
    readonly property string prompt: String((row.prompts || {}).tailor || "")
    width: parent ? parent.width : 0
    implicitHeight: rowColumn.implicitHeight + root.gapBlock * 2

    Rectangle {
      anchors.fill: parent
      radius: 0
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, rowMouse.containsMouse ? 0.07 : 0)
    }
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openUrl(String(dueRow.row.url || ""))
    }
    Column {
      id: rowColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: root.gapBlock
      anchors.rightMargin: root.gapBlock
      spacing: root.gapTight
      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: String(dueRow.row.title || "")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: root.whenLabel(dueRow.row) + (dueRow.subject !== "" ? " · " + dueRow.subject : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Button {
        visible: dueRow.prompt !== ""
        text: "Tailor my resume for this job"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: root.askAgent(dueRow.prompt)
      }
    }
  }

  // Year of activity as week columns, Sunday to Saturday, like the GitHub plugin's graph.
  // Filled days use the theme accent; empty days are a faint tint of the foreground.
  component ActivityGraph: Item {
    id: graph
    property var weeks: []
    readonly property int weekCount: weeks.length
    readonly property real cellGap: Style.space(2)
    readonly property real cellSize: weekCount > 0
      ? Math.max(3, Math.min(Style.space(10), Math.floor((width - (weekCount - 1) * cellGap) / weekCount))) : 0
    width: parent ? parent.width : 0
    height: cellSize * 7 + cellGap * 6

    function shade(level) {
      if (level < 0) return "transparent"
      if (level === 0) return Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
      var alpha = level === 1 ? 0.35 : (level === 2 ? 0.55 : (level === 3 ? 0.78 : 1.0))
      return Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, alpha)
    }

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: graph.cellGap
      Repeater {
        model: graph.weeks
        delegate: Column {
          required property var modelData
          spacing: graph.cellGap
          Repeater {
            model: modelData
            delegate: Rectangle {
              id: dayCell
              required property var modelData
              width: graph.cellSize
              height: graph.cellSize
              radius: 1
              visible: String(modelData.date || "") !== ""
              color: graph.shade(Number(modelData.level))
              MouseArea {
                id: dayMouse
                anchors.fill: parent
                hoverEnabled: true
                PanelToolTip {
                  visible: dayMouse.containsMouse && String(dayCell.modelData.date || "") !== ""
                  fontFamily: root.fontFamily
                  text: root.plural(Number(dayCell.modelData.count) || 0, "action", "actions") + " on " + String(dayCell.modelData.date || "")
                }
              }
            }
          }
        }
      }
    }
  }
}
