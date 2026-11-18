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
  property var rawDue: []
  // Company names are blanked here, in the view, so the toggle applies at once without another read.
  readonly property var due: hideCompany ? rawDue.map(function(row) {
    var copy = {}
    for (var key in row) copy[key] = row[key]
    copy.company = ""
    return copy
  }) : rawDue
  property int dueCount: 0
  property var pipeline: []
  property int jobsTotal: 0
  property var momentum: ({ available: false, window_days: 0, recorded_actions: 0, active_days: 0, weeks: [] })

  // Save from clipboard: idle | reading | confirm | saving | done | failed
  property string saveState: "idle"
  property string saveUrl: ""
  property string saveMessage: ""

  // One-click sign-in: idle | waiting | failed. Sign-out: idle | confirm | working.
  property string loginState: "idle"
  property string loginMessage: ""
  property bool loginCancelled: false
  property string signOutState: "idle"
  property string signOutMessage: ""
  property string _loginOut: ""
  property string _logoutOut: ""

  readonly property bool hideCompany: boolSetting("hideCompanyNames", false)
  // Off: nothing runs in the background; data loads when the panel opens or refresh is pressed.
  readonly property bool backgroundRefresh: boolSetting("backgroundRefresh", true)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 900, 300, 3600)
  readonly property string cliPath: String(setting("cliPath", "") || "")
  readonly property string linkBehavior: String(setting("linkBehavior", "Browser tab")).toLowerCase() === "web app window" ? "Web app window" : "Browser tab"
  property string _snapshotOut: ""
  property string _clipOut: ""
  property string _saveOut: ""
  property bool refreshQueued: false
  // The contract asks for no more than one status or overview read a minute, and a rate-limit answer says when to resume.
  property double lastStartMs: 0
  property double notBeforeMs: 0
  property int retryAfterSec: 0

  onHideCompanyChanged: if (settingsReady) refresh()
  onCliPathChanged: if (settingsReady) refresh(true)

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
    if (backgroundRefresh) refresh()
  }

  function refresh(force) {
    if (!settingsReady) return
    var now = Date.now()
    if (now < notBeforeMs) return
    if (force !== true && now - lastStartMs < 60000) return
    if (snapshotProcess.running) { refreshQueued = true; return }
    refreshQueued = false
    lastStartMs = now
    loading = true
    _snapshotOut = ""
    // argv only: nothing from settings or from JobHunt is ever read by a shell.
    snapshotProcess.command = ["python3", helperPath(), "snapshot"].concat(cliArgs())
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
    retryAfterSec = Number(doc.retry_after_seconds) || 0
    notBeforeMs = dataState === "rate_limited" ? Date.now() + Math.max(retryAfterSec, 60) * 1000 : 0
    message = String(doc.message || "")
    hasData = doc.has_data === true
    stale = doc.stale === true
    fetchedAt = String(doc.fetched_at || "")
    rawDue = Array.isArray(doc.due) ? doc.due : []
    dueCount = Number(doc.due_count) || 0
    pipeline = Array.isArray(doc.pipeline) ? doc.pipeline : []
    jobsTotal = Number(doc.jobs_total) || 0
    momentum = doc.momentum && Array.isArray(doc.momentum.weeks) ? doc.momentum : { available: false, window_days: 0, recorded_actions: 0, active_days: 0, weeks: [] }
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

  // `jobhunt auth login` with no arguments: the command opens the browser itself. Its output is never read.
  function startLogin() {
    if (loginProcess.running) return
    loginState = "waiting"
    loginMessage = ""
    loginCancelled = false
    _loginOut = ""
    loginProcess.command = ["python3", helperPath(), "login"].concat(cliArgs())
    loginProcess.running = true
  }
  function cancelLogin() {
    if (!loginProcess.running) return
    loginCancelled = true
    loginProcess.signal(15)  // the helper stops the command and answers "cancelled"
  }

  function requestSignOut() { if (signOutState === "idle") { signOutState = "confirm"; signOutMessage = "" } }
  function cancelSignOut() { if (signOutState === "confirm") signOutState = "idle" }
  function confirmSignOut() {
    if (signOutState !== "confirm" || logoutProcess.running) return
    signOutState = "working"
    _logoutOut = ""
    logoutProcess.command = ["python3", helperPath(), "logout"].concat(cliArgs())
    logoutProcess.running = true
  }

  function failureText(reason, message) {
    if (reason === "signed_out") return "You are signed out of JobHunt. Nothing was saved."
    if (reason === "cli_missing") return "The JobHunt command is not installed. Nothing was saved."
    if (reason === "unreachable") return "Could not reach JobHunt. Nothing was saved."
    if (reason === "rate_limited") return "JobHunt asked for a short pause. Nothing was saved; try again in a minute."
    if (reason === "permission") return "This connection may not save jobs. Sign in again with the command in setup. Nothing was saved."
    if (reason === "refused") return "JobHunt did not save it" + (message ? ": " + message : ".")
    return "Nothing was saved."
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.settingsReady && root.backgroundRefresh
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
    id: loginProcess
    running: false
    command: []
    stdout: StdioCollector { id: loginOutput; waitForEnd: true; onStreamFinished: root._loginOut = text }
    onExited: function(exitCode) {
      var doc = null
      try { doc = JSON.parse(String(loginOutput.text || root._loginOut || "")) } catch (error) { doc = null }
      if (root.loginCancelled || (doc && doc.reason === "cancelled")) {
        root.loginState = "idle"
      } else if (doc && doc.ok === true) {
        root.loginState = "idle"
        root.refresh(true)
      } else {
        root.loginState = "failed"
        root.loginMessage = doc && doc.reason === "timeout" ? "Sign-in was not finished in time."
          : (doc && doc.reason === "cli_missing" ? "The JobHunt command is not installed." : "Sign-in did not finish.")
      }
      root.loginCancelled = false
    }
  }

  Process {
    id: logoutProcess
    running: false
    command: []
    stdout: StdioCollector { id: logoutOutput; waitForEnd: true; onStreamFinished: root._logoutOut = text }
    onExited: function(exitCode) {
      var doc = null
      try { doc = JSON.parse(String(logoutOutput.text || root._logoutOut || "")) } catch (error) { doc = null }
      root.signOutState = "idle"
      root.signOutMessage = doc && doc.ok === true ? "" : "Could not sign out. The saved data was cleared; run jobhunt auth logout in a terminal."
      root.refresh(true)
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
        var text = doc.already_saved === true ? "Already saved in JobHunt" : "Saved to " + (String(job.stage || "") || "JobHunt")
        if (name !== "") text += ": " + name
        text += "."
        if (doc.details_pending === true) text += " The title and company are still being read from the link."
        root.saveState = "done"
        root.saveMessage = text
        root.saveUrl = ""
        root.refresh(true)
      } else {
        root.saveState = "failed"
        root.saveMessage = root.failureText(doc ? String(doc.reason || "") : "", doc ? String(doc.message || "") : "")
      }
    }
  }
}
