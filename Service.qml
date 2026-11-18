import QtQuick
import Quickshell
import Quickshell.Io

// JobHunt data service. The helper script owns everything about the JobHunt
// command line tool; this item schedules it and exposes one defensive model.
Item {
  id: root

  property var settings: ({})
  property bool settingsReady: false
  property bool loading: false

  // Mirrors the helper's snapshot document.
  property string dataState: "loading"   // loading | ok | cli_missing | signed_out | offline | error
  property string message: ""
  property bool hasData: false
  property bool stale: false
  property string fetchedAt: ""
  property var due: []
  property int dueCount: 0
  property var pipeline: []
  property int jobsTotal: 0
  property var streak: ({ available: false, current_days: 0, total_actions: 0, active_days: 0, weeks: [] })

  // Save from clipboard: idle | reading | confirm | saving | done | failed
  property string saveState: "idle"
  property string saveUrl: ""
  property string saveMessage: ""

  readonly property bool hideCompany: boolSetting("hideCompanyNames", false)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 900, 300, 3600)
  readonly property string cliPath: String(setting("cliPath", "") || "")
  readonly property string linkBehavior: String(setting("linkBehavior", "Browser tab")).toLowerCase() === "web app window" ? "Web app window" : "Browser tab"
  property string _snapshotOut: ""
  property string _clipOut: ""
  property string _saveOut: ""
  property bool refreshQueued: false

  onHideCompanyChanged: if (settingsReady) refresh()
  onCliPathChanged: if (settingsReady) refresh()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }
  function intSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }
  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (value === true || value === false) return value
    var text = String(value).toLowerCase()
    return text === "true" || text === "yes" || text === "on" || text === "1"
  }

  function helperPath() {
    return decodeURIComponent(Qt.resolvedUrl("helper/jobhunt_omarchy.py").toString().replace(/^file:\/\//, ""))
  }
  function cliArgs() {
    return cliPath !== "" ? ["--cli", cliPath] : []
  }

  function initialize(initialSettings) {
    if (settingsReady) return
    settings = initialSettings || {}
    settingsReady = true
    refresh()
  }

  function refresh() {
    if (!settingsReady) return
    if (snapshotProcess.running) { refreshQueued = true; return }
    refreshQueued = false
    loading = true
    _snapshotOut = ""
    // argv only: nothing from settings or from JobHunt is ever read by a shell.
    snapshotProcess.command = ["python3", helperPath(), "snapshot"].concat(hideCompany ? ["--hide-company"] : []).concat(cliArgs())
    snapshotProcess.running = true
  }

  function apply(raw) {
    var doc = null
    try { doc = JSON.parse(String(raw || "")) } catch (error) { doc = null }
    if (!doc || doc.schema !== 1 || typeof doc.state !== "string") {
      dataState = "error"
      message = "The JobHunt helper gave an unreadable answer."
      return
    }
    dataState = doc.state
    message = String(doc.message || "")
    hasData = doc.has_data === true
    stale = doc.stale === true
    fetchedAt = String(doc.fetched_at || "")
    due = Array.isArray(doc.due) ? doc.due : []
    dueCount = Number(doc.due_count) || 0
    pipeline = Array.isArray(doc.pipeline) ? doc.pipeline : []
    jobsTotal = Number(doc.jobs_total) || 0
    streak = doc.streak && Array.isArray(doc.streak.weeks) ? doc.streak : { available: false, current_days: 0, total_actions: 0, active_days: 0, weeks: [] }
  }

  // The clipboard is read only when the person asks, shown, and saved only after a second click.
  function startSave() {
    if (clipProcess.running || saveProcess.running) return
    saveState = "reading"
    saveMessage = ""
    saveUrl = ""
    _clipOut = ""
    clipProcess.command = ["python3", helperPath(), "clipboard"]
    clipProcess.running = true
  }
  function cancelSave() {
    if (saveProcess.running) return
    saveState = "idle"
    saveUrl = ""
    saveMessage = ""
  }
  function confirmSave() {
    if (saveState !== "confirm" || saveUrl === "" || saveProcess.running) return
    saveState = "saving"
    _saveOut = ""
    saveProcess.command = ["python3", helperPath(), "save", saveUrl].concat(cliArgs())
    saveProcess.running = true
  }

  function failureText(reason) {
    if (reason === "signed_out") return "You are signed out of JobHunt."
    if (reason === "cli_missing") return "The JobHunt command is not installed."
    if (reason === "failed") return "Could not reach JobHunt. Nothing was saved."
    return "Nothing was saved."
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.settingsReady
    onTriggered: root.refresh()
  }

  Process {
    id: snapshotProcess
    running: false
    command: []
    stdout: StdioCollector { id: snapshotOutput; waitForEnd: true; onStreamFinished: root._snapshotOut = text }
    onExited: function(exitCode) {
      root.loading = false
      var out = String(snapshotOutput.text || root._snapshotOut || "")
      if (out.trim() !== "") root.apply(out)
      else { root.dataState = "error"; root.message = "The JobHunt helper did not answer." }
      if (root.refreshQueued) Qt.callLater(root.refresh)
    }
  }

  Process {
    id: clipProcess
    running: false
    command: []
    stdout: StdioCollector { id: clipOutput; waitForEnd: true; onStreamFinished: root._clipOut = text }
    onExited: function(exitCode) {
      var doc = null
      try { doc = JSON.parse(String(clipOutput.text || root._clipOut || "")) } catch (error) { doc = null }
      if (doc && doc.ok === true && typeof doc.url === "string" && doc.url !== "") {
        root.saveUrl = doc.url
        root.saveState = "confirm"
      } else {
        root.saveState = "failed"
        root.saveMessage = doc && doc.reason === "empty" ? "The clipboard is empty. Copy a job link first."
          : "The clipboard does not hold a web link. Copy a job link first."
      }
    }
  }

  Process {
    id: saveProcess
    running: false
    command: []
    stdout: StdioCollector { id: saveOutput; waitForEnd: true; onStreamFinished: root._saveOut = text }
    onExited: function(exitCode) {
      var doc = null
      try { doc = JSON.parse(String(saveOutput.text || root._saveOut || "")) } catch (error) { doc = null }
      if (doc && doc.ok === true) {
        const job = doc.job || {}
        const name = [String(job.title || ""), root.hideCompany ? "" : String(job.company || "")].filter(function(part) { return part !== "" }).join(" at ")
        root.saveState = "done"
        root.saveMessage = name !== "" ? "Saved: " + name : "Saved to JobHunt."
        root.saveUrl = ""
        root.refresh()
      } else {
        root.saveState = "failed"
        root.saveMessage = root.failureText(doc ? String(doc.reason || "") : "")
      }
    }
  }
}
