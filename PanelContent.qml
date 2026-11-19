import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// The panel's content: tabs (Overview, Board, Docs, Page), the permanent action row and the account footer.
// Panel.qml hosts it in the shell's popup and supplies `host` (open a link, copy, ask the agent, save a setting);
// nothing here talks to JobHunt: everything comes from the Service, which comes from the helper.
Item {
  id: root

  property var jobhunt: null          // Service.qml
  property var host: null             // { openUrl(url), copyText(text), askAgent(prompt), persistSettings(values), close() }
  property var settings: ({})
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property bool darkBar: true
  property real nowMs: Date.now()
  readonly property color dim: Qt.darker(foreground, 1.55)

  readonly property string pluginVersion: "0.2.0"
  readonly property string cmdInstall: "npm i -g jobhunt@0.1.2"
  readonly property string cmdUpdate: "npm i -g jobhunt@0.2.0"
  readonly property string cmdLogin: "jobhunt auth login"
  readonly property string cmdMcp: "claude mcp add --transport http jobhunt https://jobhunt.app/mcp"
  readonly property string promptNext: "In JobHunt, tell me what I should do next. Do not change anything."
  readonly property string origin: "https://jobhunt.app"

  readonly property int gapSection: Style.spacing.panelGap
  readonly property int gapBlock: Style.spacing.lg
  readonly property int gapTight: Style.spacing.sm
  readonly property int surfacePad: Style.spacing.xl

  readonly property bool needsSetup: jobhunt.dataState === "cli_missing" || jobhunt.dataState === "signed_out"
  readonly property bool showApp: !needsSetup && jobhunt.hasData
  readonly property bool readOnly: jobhunt.readOnly
  readonly property var todayRows: jobhunt.due.filter(function(row) { return row.bucket === "today" })
  readonly property var laterRows: jobhunt.due.filter(function(row) { return row.bucket !== "today" })
  readonly property var features: jobhunt.cli.features
  readonly property bool commandIsOld: !features.docs   // one flag: the 0.2.0 views are all-or-nothing

  property string tab: "overview"     // overview | board | docs | page
  property bool todayOpen: false
  property bool moreWays: false
  property string pendingPrompt: ""

  // Settings carried over from 0.1.0 keep their names and meaning. New keys: whatsNewFrom, whatsNewSeen (both written
  // only here), and settingsVersion (written by Panel.qml on every save). A missing key means the default.
  readonly property bool showWhatsNew: String(setting("whatsNewSeen", "")) !== pluginVersion && String(setting("whatsNewFrom", "")) !== ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function scrollToEnd() { bodyFlick.contentY = Math.max(0, bodyFlick.contentHeight - bodyFlick.height) }

  function reset() {
    tab = "overview"
    todayOpen = false
    moreWays = false
    pendingPrompt = ""
    bodyFlick.contentY = 0
  }

  // Panel.qml (always alive) records the update from 0.1.0 when the first read reports it; this only shows the note.
  function dismissWhatsNew() { host.persistSettings({ whatsNewSeen: pluginVersion }) }

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

  function dayWord(role) {
    var days = Number(role.days)
    if (!isFinite(days) || days < 0) return ""
    return days === 0 ? "today" : days + "d"
  }

  // The hero's second line: what the Hunt is, or why there is nothing to show.
  function summaryText() {
    if (jobhunt.dataState === "loading") return "Reading JobHunt…"
    if (jobhunt.dataState === "cli_missing") return "JobHunt command not installed"
    if (jobhunt.dataState === "signed_out") return "Signed out"
    if (!jobhunt.hasData) return jobhunt.dataState === "offline" ? "Offline" : "Something went wrong"
    return jobhunt.hunt.name !== "" ? jobhunt.hunt.name : "Your job search"
  }

  // The plan chip: a plain fact in the footer's own words, never the sentence the service writes for an assistant.
  function planText() {
    var kind = String(jobhunt.access.kind || "")
    if (kind === "trial") {
      var days = Number(jobhunt.access.days_left)
      return isFinite(days) && jobhunt.access.days_left !== null ? "Trial · " + plural(days, "day", "days") + " left" : "Trial"
    }
    if (kind === "subscribed") return "Subscribed"
    if (kind === "read_only") return "Read-only"
    return ""   // free, review and unknown: nothing to say
  }

  function connectionText() {
    if (jobhunt.dataState === "loading" || jobhunt.loading) return "Reading JobHunt…"
    if (jobhunt.dataState === "ok") return "Connected · synced " + ageText(jobhunt.fetchedAt)
    if (jobhunt.hasData) return (jobhunt.dataState === "offline" ? "Offline" : "Not connected") + " · last read " + ageText(jobhunt.fetchedAt)
    return jobhunt.dataState === "offline" ? "Offline" : "Not connected"
  }

  function openApp(path) { return host.openUrl(origin + path) }

  // The pipeline's active columns: the account's own stage names, three at most, never built in.
  readonly property var activeStages: jobhunt.pipeline.filter(function(stage) {
    return stage.final !== true && (stage.type === "saved" || stage.type === "applied" || stage.type === "interview")
  }).slice(0, 3)
  readonly property var quietStages: jobhunt.pipeline.filter(function(stage) { return activeStages.indexOf(stage) < 0 })
  function rolesFor(stage) {
    var rows = stage.type === "applied" ? jobhunt.applied : (stage.type === "interview" ? jobhunt.interviewing : [])
    return rows.slice(0, 2)
  }
  function stageOpacity(index, count) { return 0.30 + 0.55 * (count <= 1 ? 1 : index / (count - 1)) }

  implicitHeight: head.implicitHeight + (showApp ? tabBar.implicitHeight : 0) + bodyColumn.implicitHeight
    + (showApp ? actionBar.implicitHeight + footer.implicitHeight : 0)

  // ---- Fixed top: hero, notices ----
  Column {
    id: head
    width: parent.width
    spacing: root.gapBlock

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
  }

  function askAgent(prompt) { pendingPrompt = String(prompt || ""); bodyFlick.contentY = 0 }
  function launchPending() {
    var text = pendingPrompt
    pendingPrompt = ""
    if (text !== "") host.runAgent(text)
  }

  // ---- Tabs (only with data to show) ----
  Row {
    id: tabBar
    visible: root.showApp
    anchors.top: head.bottom
    anchors.topMargin: visible ? root.gapBlock : 0
    width: parent.width
    height: visible ? implicitHeight : 0
    Repeater {
      model: [
        { key: "overview", label: "Overview" },
        { key: "board", label: "Board" },
        { key: "docs", label: "Docs" },
        { key: "page", label: "Page" }
      ]
      delegate: Item {
        id: tabItem
        required property var modelData
        readonly property bool on: root.tab === modelData.key
        width: tabLabel.implicitWidth + Style.space(20)
        implicitHeight: tabLabel.implicitHeight + Style.space(14)
        height: implicitHeight
        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: tabItem.on ? 2 : 0
          color: Color.accent
        }
        Text {
          id: tabLabel
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: modelData.label
          color: tabItem.on ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: tabItem.on
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: { root.tab = tabItem.modelData.key; bodyFlick.contentY = 0 }
        }
      }
    }
    Rectangle { width: 1; height: 1; color: "transparent" }
  }
  Rectangle {
    visible: root.showApp
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: tabBar.bottom
    height: 1
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
  }

  // ---- Scrolling body ----
  Flickable {
    id: bodyFlick
    anchors.top: root.showApp ? tabBar.bottom : head.bottom
    anchors.topMargin: root.gapBlock
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: root.showApp ? actionBar.top : parent.bottom
    anchors.bottomMargin: root.showApp ? root.gapBlock : 0
    contentWidth: width
    contentHeight: bodyColumn.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: bodyColumn
      width: bodyFlick.width
      spacing: root.gapBlock

      // ---- Setup (CLI missing or signed out) ----
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
            text: "Waiting for you to approve in your browser…"
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

      // ---- What's new, once after the update ----
      BorderSurface {
        visible: root.showApp && root.showWhatsNew && root.tab === "overview"
        width: parent.width
        implicitHeight: whatsNewRow.implicitHeight + root.surfacePad * 2
        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)
        borderSpec: Border.flat(Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.40), 1)
        radius: 0
        Row {
          id: whatsNewRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: root.surfacePad
          spacing: root.gapBlock
          Text {
            width: parent.width - dismissNew.implicitWidth - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: "New in " + root.pluginVersion + ": tabs for your board, documents and Hunt Page, your account and plan, and a clearer activity graph."
          }
          Button {
            id: dismissNew
            anchors.verticalCenter: parent.verticalCenter
            text: "Got it"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: root.dismissWhatsNew()
          }
        }
      }

      // ---- Read-only account ----
      BorderSurface {
        visible: root.showApp && root.readOnly && root.tab === "overview"
        width: parent.width
        implicitHeight: readOnlyText.implicitHeight + root.surfacePad * 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
        borderSpec: Border.flat(Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45), 1)
        radius: 0
        Text {
          id: readOnlyText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: root.surfacePad
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: "Your account is read-only. You can still view and export your work; saving and changes need a subscription."
        }
      }

      // ================= Overview =================
      Column {
        visible: root.showApp && root.tab === "overview"
        width: parent.width
        spacing: Style.space(13)

        // Today, one line. The rest opens in place.
        Column {
          width: parent.width
          spacing: root.gapTight
          BorderSurface {
            width: parent.width
            implicitHeight: todayLine.implicitHeight + root.surfacePad * 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
            borderSpec: Border.flat(Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14), 1)
            radius: 0
            Row {
              id: todayLine
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: root.surfacePad
              spacing: root.gapBlock
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.spacing.md
                height: Style.spacing.md
                radius: width / 2
                color: root.todayRows.length > 0 ? Color.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
              }
              Text {
                id: todayText
                width: parent.width - parent.spacing * 2 - Style.spacing.md - (moreToday.visible ? moreToday.implicitWidth : 0)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                text: root.todayRows.length === 0 ? "Nothing due today"
                  : String(root.todayRows[0].title || "") + (String(root.todayRows[0].time || "") !== "" ? " " + root.todayRows[0].time : "")
                    + (String(root.todayRows[0].company || "") !== "" ? " · " + root.todayRows[0].company : "")
              }
              Button {
                id: moreToday
                visible: root.todayRows.length > 1 || root.laterRows.length > 0
                anchors.verticalCenter: parent.verticalCenter
                text: root.todayOpen ? "Hide" : (root.todayRows.length > 1 ? "+" + (root.todayRows.length - 1) + " today" : root.laterRows.length + " later")
                foreground: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: 0
                onClicked: root.todayOpen = !root.todayOpen
              }
            }
          }
          Column {
            visible: root.todayOpen
            width: parent.width
            spacing: root.gapTight
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
        }

        // Pipeline as columns: the stage's count, then the roles the overview already names.
        Column {
          visible: jobhunt.pipeline.length > 0
          width: parent.width
          spacing: root.gapBlock
          SectionLabel { text: "PIPELINE"; trailing: root.plural(jobhunt.jobsTotal, "job", "jobs") + (jobhunt.hunt.name !== "" ? " · " + jobhunt.hunt.name : "") }
          Row {
            id: stageBar
            visible: jobhunt.jobsTotal > 0
            width: parent.width
            height: Style.space(7)
            spacing: 2
            Repeater {
              model: jobhunt.pipeline.filter(function(stage) { return stage.jobs > 0 })
              delegate: Rectangle {
                required property var modelData
                required property int index
                width: Math.max(2, (stageBar.width - (stageBar.children.length - 2) * 2) * modelData.jobs / Math.max(1, jobhunt.jobsTotal))
                height: stageBar.height
                color: modelData.final === true ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
                  : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, root.stageOpacity(Math.min(index, 3), 4))
              }
            }
          }
          Row {
            width: parent.width
            spacing: root.gapBlock
            Repeater {
              model: root.activeStages
              delegate: Column {
                required property var modelData
                width: (parent.width - (root.activeStages.length - 1) * root.gapBlock) / Math.max(1, root.activeStages.length)
                spacing: root.gapTight
                Text {
                  textFormat: Text.PlainText
                  text: String(modelData.jobs)
                  color: modelData.jobs > 0 ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: modelData.name.toUpperCase()
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: Style.font.caption * 0.08
                }
                Repeater {
                  model: root.rolesFor(modelData)
                  delegate: Column {
                    required property var modelData
                    width: parent.width
                    spacing: 0
                    Rectangle { width: parent.width; height: 1; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) }
                    Item { width: 1; height: Style.space(3) }
                    Text {
                      width: parent.width
                      visible: String(modelData.company || "") !== ""
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      text: String(modelData.company || "")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      text: String(modelData.title || "")
                      color: String(modelData.company || "") !== "" ? root.dim : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: String(modelData.company || "") === ""
                    }
                    Item { width: 1; height: Style.space(3) }
                  }
                }
              }
            }
          }
          Row {
            spacing: root.gapBlock
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.quietStages.length > 0
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: root.quietStages.map(function(stage) { return stage.name + " " + stage.jobs }).join(" · ")
            }
            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: "See all " + jobhunt.jobsTotal + " →"
              foreground: Color.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: 0
              onClicked: { root.tab = "board"; bodyFlick.contentY = 0 }
            }
          }
        }

        // Momentum: the labelled year.
        Column {
          width: parent.width
          spacing: root.gapBlock
          SectionLabel {
            text: "MOMENTUM"
            trailing: jobhunt.momentum.available
              ? root.plural(Number(jobhunt.momentum.recorded_actions) || 0, "recorded action", "recorded actions") + " · " + root.plural(Number(jobhunt.momentum.active_days) || 0, "day", "days")
              : ""
          }
          Text {
            visible: !jobhunt.momentum.available
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: "Activity is not available right now."
          }
          ActivityGraph { visible: jobhunt.momentum.available; weeks: jobhunt.momentum.weeks }
        }

        // Hunt Docs and Hunt Page, one line each, on what the overview already says. The lists wait for the updated command.
        Column {
          width: parent.width
          spacing: root.gapBlock
          SectionLabel { text: "HUNT DOCS" }
          LineRow {
            tag: "R"
            title: jobhunt.resume.name !== "" ? "Resume · " + jobhunt.resume.name : "Your resumes and cover letters"
            actionText: "Open"
            onActivated: root.openApp("/app/documents")
          }
        }
        Column {
          width: parent.width
          spacing: root.gapBlock
          SectionLabel { text: "HUNT PAGE" }
          LineRow {
            tag: "↗"
            title: "Your public page"
            actionText: "Manage"
            onActivated: root.openApp("/app/hunt-page")
          }
        }

        UpdateLine {
          visible: root.commandIsOld
          text: "Role previews, document lists and the Hunt Page state need the updated command line."
        }
      }

      // ================= Board / Docs / Page =================
      Column {
        visible: root.showApp && root.tab !== "overview"
        width: parent.width
        spacing: root.gapBlock
        SectionLabel {
          text: root.tab === "board" ? "BOARD" : (root.tab === "docs" ? "HUNT DOCS" : "HUNT PAGE")
        }
        UpdateLine {
          visible: root.commandIsOld
          text: (root.tab === "board" ? "The board" : (root.tab === "docs" ? "Your documents" : "Your Hunt Page")) + " needs the updated command line."
        }
        Text {
          visible: !root.commandIsOld
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: "This tab arrives in the next update."
        }
        Button {
          text: root.tab === "board" ? "Open the board in JobHunt →" : (root.tab === "docs" ? "Open your documents in JobHunt →" : "Open your Hunt Page in JobHunt →")
          foreground: Color.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: 0
          onClicked: root.openApp(root.tab === "board" ? "/app/applications" : (root.tab === "docs" ? "/app/documents" : "/app/hunt-page"))
        }
      }
    }
  }

  // ---- Permanent action row, with the result of a Quick add above it ----
  Column {
    id: actionBar
    visible: root.showApp
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: footer.top
    anchors.bottomMargin: root.showApp ? root.gapBlock : 0
    spacing: root.gapBlock

    BorderSurface {
      visible: jobhunt.saveState === "done" || jobhunt.saveState === "failed"
      width: parent.width
      implicitHeight: resultRow.implicitHeight + root.surfacePad * 2
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
      borderSpec: Border.flat(jobhunt.saveState === "failed" ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.45) : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55), 1)
      radius: 0
      Row {
        id: resultRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: root.surfacePad
        spacing: root.gapBlock
        Text {
          width: parent.width - dismissResult.implicitWidth - parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: jobhunt.saveState === "failed" ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: jobhunt.saveMessage
        }
        Button {
          id: dismissResult
          anchors.verticalCenter: parent.verticalCenter
          text: "OK"
          foreground: root.dim
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: jobhunt.cancelSave()
        }
      }
    }

    Item {
      width: parent.width
      implicitHeight: buttonsRow.implicitHeight
      Row {
        id: buttonsRow
        spacing: root.gapTight
        Button {
          id: quickAdd
          text: "Quick add"
          iconText: "\u{f0415}"
          enabled: !root.readOnly && (jobhunt.saveState === "idle" || jobhunt.saveState === "done" || jobhunt.saveState === "failed")
          selected: true
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          tooltipText: root.readOnly ? "Saving needs a subscription" : "Save a job link from your clipboard"
          onClicked: jobhunt.startSave()
        }
        Button {
          text: "Open JobHunt"
          bordered: true
          foreground: root.dim
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: root.openApp("/app")
        }
        Button {
          text: "What next?"
          bordered: true
          foreground: root.dim
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          tooltipText: "Ask your agent: what should I do next?"
          onClicked: root.askAgent(root.promptNext)
        }
      }
      // The privacy switch, at the right of the row.
      Button {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: jobhunt.hideCompany ? "\u{f0209}" : "\u{f0208}"
        selected: jobhunt.hideCompany
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        tooltipText: jobhunt.hideCompany ? "Company names are hidden. Click to show them." : "Hide company names (for shared screens)"
        onClicked: root.host.persistSettings({ hideCompanyNames: !jobhunt.hideCompany })
      }
    }
  }

  // ---- Account and plan footer ----
  BorderSurface {
    id: footer
    visible: root.showApp
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    implicitHeight: visible ? footerRow.implicitHeight + root.surfacePad * 2 : 0
    height: implicitHeight
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
    borderSpec: Border.flat(Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14), 1)
    radius: 0

    Row {
      id: footerRow
      visible: jobhunt.signOutState === "idle"
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: root.surfacePad
      spacing: root.gapBlock
      Rectangle {
        id: avatar
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(28)
        height: width
        color: "transparent"
        border.width: 1
        border.color: Color.accent
        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: (String(jobhunt.account.name || "?").trim().charAt(0) || "?").toUpperCase()
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }
      Column {
        id: whoColumn
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - avatar.width - manageColumn.implicitWidth - parent.spacing * 2
        spacing: Style.space(2)
        Row {
          spacing: root.gapBlock
          Text {
            id: nameText
            width: Math.min(implicitWidth, whoColumn.width - (planChip.visible ? planChip.width + parent.spacing : 0))
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: String(jobhunt.account.name || "") !== "" ? jobhunt.account.name : "Signed in"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Rectangle {
            id: planChip
            visible: root.planText() !== ""
            anchors.verticalCenter: parent.verticalCenter
            width: planLabel.implicitWidth + Style.space(10)
            height: planLabel.implicitHeight + Style.space(3)
            color: "transparent"
            border.width: 1
            border.color: root.readOnly ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.30) : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.60)
            Text {
              id: planLabel
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.planText()
              color: root.readOnly ? root.dim : Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
        Row {
          spacing: Style.space(6)
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(6)
            height: width
            radius: width / 2
            color: jobhunt.dataState === "ok" ? Color.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.4)
          }
          Text {
            textFormat: Text.PlainText
            elide: Text.ElideRight
            width: Math.min(implicitWidth, whoColumn.width - Style.space(12))
            text: root.connectionText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
      Column {
        id: manageColumn
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0
        Button {
          anchors.right: parent.right
          text: "Manage ↗"
          foreground: Color.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: 0
          onClicked: root.openApp("/app/settings/billing")
        }
        Button {
          anchors.right: parent.right
          text: "Sign out"
          foreground: root.dim
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: 0
          onClicked: jobhunt.requestSignOut()
        }
      }
    }
    Column {
      visible: jobhunt.signOutState !== "idle"
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
        font.pixelSize: Style.font.bodySmall
        text: "Sign out of JobHunt on this computer? The data this plugin saved is cleared too."
      }
      Row {
        spacing: Style.space(8)
        Button {
          text: jobhunt.signOutState === "working" ? "Signing out…" : "Sign out"
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
  }
  Text {
    visible: jobhunt.signOutMessage !== ""
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: footer.top
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    text: jobhunt.signOutMessage
  }

  // ---- Quick add: a sheet over the panel. 0.2.0 saves jobs only; the other types are shown as coming. ----
  Item {
    id: sheetLayer
    visible: root.showApp && (jobhunt.saveState === "reading" || jobhunt.saveState === "confirm" || jobhunt.saveState === "saving")
    anchors.fill: parent
    z: 20
    Rectangle { anchors.fill: parent; color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.72) }
    MouseArea { anchors.fill: parent }   // swallows clicks behind the sheet
    BorderSurface {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.space(96)
      implicitHeight: sheetColumn.implicitHeight + root.surfacePad * 2
      color: Color.background
      borderSpec: Border.flat(Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.60), 1)
      radius: 0
      Column {
        id: sheetColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: root.surfacePad
        spacing: root.gapBlock
        SectionLabel { text: "QUICK ADD" }
        Text {
          visible: jobhunt.saveState === "reading"
          width: parent.width
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: "Reading the clipboard…"
        }
        Column {
          visible: jobhunt.saveState !== "reading"
          width: parent.width
          spacing: root.gapBlock
          BorderSurface {
            width: parent.width
            implicitHeight: sheetUrl.implicitHeight + root.surfacePad * 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
            borderSpec: Border.flat(Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55), 1)
            radius: 0
            Text {
              id: sheetUrl
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: root.surfacePad
              textFormat: Text.PlainText
              wrapMode: Text.WrapAnywhere
              maximumLineCount: 4
              elide: Text.ElideRight
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: jobhunt.saveUrl
            }
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: "From your clipboard. Nothing is saved until you press Save."
          }
          SectionLabel { quiet: true; text: "RECOGNISED" }
          Row {
            width: parent.width
            spacing: -1
            Repeater {
              model: [
                { label: "Job from link", on: true },
                { label: "Note", on: false },
                { label: "Task", on: false },
                { label: "Contact", on: false }
              ]
              delegate: Rectangle {
                required property var modelData
                width: (parent.width + 3) / 4
                height: typeText.implicitHeight + Style.space(12)
                color: modelData.on ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10) : "transparent"
                border.width: 1
                border.color: modelData.on ? Color.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
                opacity: modelData.on ? 1 : 0.5
                Text {
                  id: typeText
                  anchors.centerIn: parent
                  width: parent.width - Style.space(8)
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: modelData.label
                  color: modelData.on ? Color.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: modelData.on
                }
                MouseArea {
                  id: typeMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  PanelToolTip {
                    visible: typeMouse.containsMouse && !modelData.on
                    fontFamily: root.fontFamily
                    text: "Coming in a later version"
                  }
                }
              }
            }
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: "Saves a job to your first stage. JobHunt reads the title and company from the link; you can edit them there."
          }
          Row {
            spacing: Style.space(8)
            Button {
              text: jobhunt.saveState === "saving" ? "Saving…" : "Save"
              enabled: jobhunt.saveState === "confirm"
              selected: true
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
      }
    }
  }

  // ---------------------------------------------------------------- pieces

  // A section's label as the website sets one: a small square, then tracked capitals; `trailing` is a quiet note on the right.
  component SectionLabel: Item {
    id: label
    property string text: ""
    property string trailing: ""
    property bool quiet: false
    property real topPadding: 0
    width: parent ? parent.width : 0
    implicitHeight: labelRow.implicitHeight + topPadding
    Row {
      id: labelRow
      y: label.topPadding
      spacing: Style.spacing.md
      Rectangle {
        visible: !label.quiet
        anchors.verticalCenter: parent.verticalCenter
        width: Style.spacing.md
        height: Style.spacing.md
        color: Color.accent
      }
      PanelSectionHeader {
        text: label.text
        foreground: label.quiet ? root.dim : root.foreground
        fontFamily: root.fontFamily
        font.letterSpacing: Style.font.caption * 0.14
      }
    }
    Text {
      visible: label.trailing !== ""
      anchors.right: parent.right
      y: label.topPadding
      textFormat: Text.PlainText
      text: label.trailing
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
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
      visible: cmd.label !== ""
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
        onClicked: root.host.copyText(cmd.command)
      }
    }
  }

  // The one quiet line that stands in for anything the installed command cannot serve yet.
  component UpdateLine: Column {
    property string text: ""
    width: parent ? parent.width : 0
    spacing: root.gapTight
    Text {
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      text: parent.text
    }
    CommandRow { label: "Update the command line"; command: root.cmdUpdate }
  }

  // One line: a tag, a title, one action. Hover tint, like a due row.
  component LineRow: Item {
    id: line
    property string tag: ""
    property string title: ""
    property string actionText: ""
    signal activated()
    width: parent ? parent.width : 0
    implicitHeight: lineContent.implicitHeight + root.surfacePad * 2
    BorderSurface {
      anchors.fill: parent
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, lineMouse.containsMouse ? 0.08 : 0.04)
      borderSpec: Border.flat(Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14), 1)
      radius: 0
    }
    MouseArea {
      id: lineMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: line.activated()
    }
    Row {
      id: lineContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: root.surfacePad
      spacing: root.gapBlock
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(20)
        height: width
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: line.tag
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
      Text {
        width: parent.width - Style.space(20) - actionLabel.implicitWidth - parent.spacing * 2
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: line.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
      Text {
        id: actionLabel
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: line.actionText + " ↗"
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
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
      onClicked: root.host.openUrl(String(dueRow.row.url || ""))
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

  // A year of activity as week columns, Sunday to Saturday: month names above, Mon / Wed / Fri beside, a legend below.
  // Filled days use the theme accent; empty days are a faint tint of the foreground. Counts of recorded actions only.
  component ActivityGraph: Column {
    id: graph
    property var weeks: []
    readonly property int weekCount: weeks.length
    readonly property real labelColumn: Style.space(26)
    readonly property real cellGap: Style.space(1.4)
    readonly property real cellSize: weekCount > 0
      ? Math.max(3, Math.min(Style.space(10), (width - labelColumn - (weekCount - 1) * cellGap) / weekCount)) : 0
    readonly property real step: cellSize + cellGap
    readonly property var monthMarks: {
      var marks = []
      var lastX = -100
      for (var w = 0; w < weeks.length; w++) {
        var first = ""
        for (var d = 0; d < weeks[w].length; d++) { if (String(weeks[w][d].date || "") !== "") { first = String(weeks[w][d].date); break } }
        if (first === "") continue
        var day = parseInt(first.substring(8, 10), 10)
        var x = w * step
        if (day <= 7 && x - lastX >= Style.space(24)) {
          marks.push({ x: x, name: Qt.locale().monthName(parseInt(first.substring(5, 7), 10) - 1, Locale.ShortFormat) })
          lastX = x
        }
      }
      return marks
    }
    width: parent ? parent.width : 0
    spacing: Style.space(4)

    function shade(level) {
      if (level < 0) return "transparent"
      if (level === 0) return Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
      var alpha = level === 1 ? 0.35 : (level === 2 ? 0.55 : (level === 3 ? 0.78 : 1.0))
      return Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, alpha)
    }

    Item {
      width: parent.width
      height: monthText.implicitHeight
      Text { id: monthText; visible: false; text: "Mon"; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
      Repeater {
        model: graph.monthMarks
        delegate: Text {
          required property var modelData
          x: graph.labelColumn + modelData.x
          textFormat: Text.PlainText
          text: modelData.name
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
    Row {
      spacing: 0
      Item {
        width: graph.labelColumn
        height: graph.cellSize * 7 + graph.cellGap * 6
        Repeater {
          model: [{ row: 1, name: "Mon" }, { row: 3, name: "Wed" }, { row: 5, name: "Fri" }]
          delegate: Text {
            required property var modelData
            y: modelData.row * graph.step + (graph.cellSize - implicitHeight) / 2
            textFormat: Text.PlainText
            text: modelData.name
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
      Row {
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
    Row {
      anchors.right: parent.right
      spacing: Style.space(4)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "Recorded actions per day   Less"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Repeater {
        model: [0, 1, 2, 3, 4]
        delegate: Rectangle {
          required property int modelData
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(9)
          height: width
          radius: 1
          color: graph.shade(modelData)
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "More"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
