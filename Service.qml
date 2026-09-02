pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Non-visual engine for PinRoutes: owns the route rules and settings
// (persisted in ~/.config/pinroutes/pinroutes.json), verifies them against
// the kernel's main route table, re-applies them through the privileged
// helper, and watches netlink (`ip monitor route`) so lost routes are
// noticed the moment a VPN reconnect or resume wipes them — with a periodic
// timer as fallback, mirroring the macOS app's RouteMonitor.
//
// A singleton (see qmldir): the bar instantiates one Panel per monitor, and
// per-instance state here would mean duplicate netlink monitors, duplicate
// notifications, and config writes clobbering each other.
Item {
  id: root

  // ---- persisted state -----------------------------------------------------
  property var routes: []            // [{id, name, network, gateway, enabled}]
  property bool monitorEnabled: true
  property bool autoReapply: true
  property bool notifyOnMissing: true
  property int intervalSec: 60

  // ---- runtime state -------------------------------------------------------
  property var statuses: ({})        // id -> active | missing | disabled
  property bool loaded: false
  property bool helperInstalled: false
  property string lastError: ""
  property string actionStatus: ""
  // Per-route bookkeeping for the current "missing episode" — all keyed by
  // rule id and cleared whenever a route leaves the missing state, so a route
  // that stays missing doesn't nag on every verify pass but a fresh episode
  // (after being active or in standby) gets handled again.
  property var _missingSince: ({})   // id -> ms timestamp first seen missing
  property var _autoTried: ({})      // id -> auto-reapply attempted
  property var _notified: ({})       // id -> notification sent
  property bool _silentApply: false

  // Grace before a missing-route notification: transient churn (DHCP renews,
  // NetworkManager rewriting routes) usually settles well inside this window.
  readonly property int notifyGraceMs: 10000

  readonly property bool applying: applyProcess.running
  readonly property bool busy: applyProcess.running || tableProcess.running || installProcess.running

  readonly property string helperDest: "/usr/local/bin/pinroutes-helper"
  readonly property string localHelperPath: Qt.resolvedUrl("helper/pinroutes-helper").toString().replace("file://", "")
  readonly property string installScriptPath: Qt.resolvedUrl("helper/pinroutes-helper-install").toString().replace("file://", "")
  readonly property string stateHelper: Qt.resolvedUrl("stateio.py").toString().replace("file://", "")
  readonly property string statePath: {
    var base = Quickshell.env("XDG_CONFIG_HOME")
    if (!base) base = Quickshell.env("HOME") + "/.config"
    return base + "/pinroutes/pinroutes.json"
  }
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME") || ""

  readonly property int enabledCount: countWhere(function(r) { return r.enabled })
  readonly property int missingCount: countStatus("missing")
  readonly property int activeCount: countStatus("active")
  readonly property int standbyCount: countStatus("standby")
  readonly property string statusText: {
    if (!loaded) return "Loading…"
    if (routes.length === 0) return "No routes configured"
    if (enabledCount === 0) return "All routes disabled"
    if (missingCount > 0) return missingCount + (missingCount === 1 ? " route missing" : " routes missing")
    if (activeCount > 0 && standbyCount > 0) return activeCount + " pinned · " + standbyCount + " standby"
    if (standbyCount > 0) return standbyCount + (standbyCount === 1 ? " route standby" : " routes standby")
    if (!monitorEnabled) return "Monitoring off"
    return activeCount + (activeCount === 1 ? " route pinned" : " routes pinned")
  }

  function countWhere(pred) {
    var n = 0
    for (var i = 0; i < routes.length; i++) if (pred(routes[i])) n++
    return n
  }

  function countStatus(wanted) {
    var n = 0
    for (var i = 0; i < routes.length; i++) if (statuses[routes[i].id] === wanted) n++
    return n
  }

  function statusOf(id) {
    return statuses[id] || "unknown"
  }

  function flashStatus(text) {
    actionStatus = text
    actionStatusTimer.restart()
  }

  function notify(urgency, title, body) {
    if (!notifyOnMissing) return
    Quickshell.execDetached(["notify-send", "-a", "PinRoutes", "-u", urgency, title, body])
  }

  // ---- rule CRUD (each returns "" or a validation error) -------------------

  function addRoute(name, network, gateway) {
    var v = Model.validateRule(name, network, gateway)
    if (!v.ok) return v.error
    var next = routes.slice()
    next.push({ id: Model.makeId(), name: v.name, network: v.network, gateway: v.gateway, enabled: true })
    routes = next
    saveState()
    refresh()
    return ""
  }

  function updateRoute(id, name, network, gateway) {
    var v = Model.validateRule(name, network, gateway)
    if (!v.ok) return v.error
    var next = routes.slice()
    for (var i = 0; i < next.length; i++) {
      if (next[i].id === id) {
        next[i] = { id: id, name: v.name, network: v.network, gateway: v.gateway, enabled: next[i].enabled }
        break
      }
    }
    routes = next
    saveState()
    refresh()
    return ""
  }

  function setRouteEnabled(id, enabled) {
    var next = routes.slice()
    for (var i = 0; i < next.length; i++) {
      if (next[i].id === id) {
        next[i] = Object.assign({}, next[i], { enabled: enabled === true })
        break
      }
    }
    routes = next
    saveState()
    refresh()
  }

  // Removing a rule also removes the route from the system when it is
  // currently applied, like the macOS app's removeSingleRoute.
  function removeRoute(id) {
    var wasApplied = statusOf(id) === "active"
    var removed = null
    var next = []
    for (var i = 0; i < routes.length; i++) {
      if (routes[i].id === id) removed = routes[i]
      else next.push(routes[i])
    }
    routes = next
    var nextStatuses = Object.assign({}, statuses)
    delete nextStatuses[id]
    statuses = nextStatuses
    saveState()
    if (removed && wasApplied) runHelper(["delete", removed.network], true)
    else refresh()
  }

  // ---- settings setters (UI entry points; persist on change) ---------------

  function setMonitorEnabled(v) {
    monitorEnabled = v === true
    saveState()
    syncMonitor()
    if (monitorEnabled) refresh()
  }

  function setAutoReapply(v) {
    autoReapply = v === true
    saveState()
    if (autoReapply) refresh()
  }

  function setNotifyOnMissing(v) {
    notifyOnMissing = v === true
    saveState()
  }

  function setIntervalSec(v) {
    var n = parseInt(String(v), 10)
    if (!isFinite(n)) return
    intervalSec = Math.max(15, Math.min(600, n))
    saveState()
  }

  // ---- verify --------------------------------------------------------------

  function refresh() {
    if (!loaded || tableProcess.running) return
    tableProcess.running = true
  }

  function handleTable(entries) {
    statuses = Model.verifyStatuses(routes, entries)
    var now = Date.now()
    var since = {}
    var tried = {}
    var noted = {}
    var toAutoApply = []
    var toNotify = []
    var graceRunning = false

    for (var i = 0; i < routes.length; i++) {
      var rule = routes[i]
      if (statuses[rule.id] !== "missing") continue // leaving "missing" resets the episode
      since[rule.id] = _missingSince[rule.id] || now
      tried[rule.id] = _autoTried[rule.id] === true
      noted[rule.id] = _notified[rule.id] === true

      if (autoReapply && helperInstalled) {
        if (!tried[rule.id]) {
          toAutoApply.push(rule)
          tried[rule.id] = true
        }
      } else if (!noted[rule.id]) {
        if (now - since[rule.id] >= notifyGraceMs) {
          toNotify.push(rule)
          noted[rule.id] = true
        } else {
          graceRunning = true // still inside the grace window; check again soon
        }
      }
    }

    _missingSince = since
    _autoTried = tried
    _notified = noted

    if (toAutoApply.length > 0 && !applying) applyRules(toAutoApply, false)
    if (toNotify.length > 0) {
      var names = toNotify.map(function(r) { return r.name }).join(", ")
      notify("critical", "Route missing",
             names + (autoReapply ? " — install the helper to enable silent re-apply" : " — open PinRoutes to re-apply"))
    }
    if (graceRunning) notifyGraceTimer.restart()
  }

  // ---- apply ---------------------------------------------------------------

  function applyMissing(interactive) {
    var missing = []
    for (var i = 0; i < routes.length; i++) {
      if (statusOf(routes[i].id) === "missing") missing.push(routes[i])
    }
    if (missing.length === 0) {
      if (interactive) flashStatus(standbyCount > 0 ? "Nothing to fix — standby routes' gateway is unreachable" : "All routes already pinned")
      return
    }
    applyRules(missing, interactive)
  }

  function applyRule(rule) {
    applyRules([rule], true)
  }

  function applyRules(rules, interactive) {
    var args = []
    for (var i = 0; i < rules.length; i++) {
      args.push("replace", rules[i].network, rules[i].gateway)
    }
    runHelper(args, interactive)
  }

  // Route changes need root. With the helper installed, sudo -n runs it
  // silently; otherwise pkexec pops the shell's themed auth dialog — but only
  // for user-initiated actions, never from the background monitor.
  function runHelper(args, interactive) {
    if (applyProcess.running || args.length === 0) return
    var cmd
    if (helperInstalled) cmd = ["sudo", "-n", helperDest].concat(args)
    else if (interactive) cmd = ["pkexec", localHelperPath].concat(args)
    else return
    lastError = ""
    _silentApply = !interactive
    applyProcess.command = cmd
    applyProcess.running = true
  }

  // ---- helper install ------------------------------------------------------

  function checkHelper() {
    if (helperCheckProcess.running) return
    helperCheckProcess.running = true
  }

  function installHelper() {
    if (installProcess.running || userName === "") return
    installProcess.command = ["pkexec", installScriptPath, localHelperPath, userName]
    installProcess.running = true
  }

  function uninstallHelper() {
    if (installProcess.running) return
    installProcess.command = ["pkexec", installScriptPath, "--uninstall"]
    installProcess.running = true
  }

  // ---- persistence ---------------------------------------------------------

  function restoreState(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      if (parsed && typeof parsed === "object") {
        routes = Model.sanitizeRoutes(parsed.routes)
        monitorEnabled = parsed.monitorEnabled !== false
        autoReapply = parsed.autoReapply !== false
        notifyOnMissing = parsed.notifyOnMissing !== false
        var n = parseInt(String(parsed.intervalSec), 10)
        if (isFinite(n)) intervalSec = Math.max(15, Math.min(600, n))
      }
    } catch (e) {
      if (String(content || "").trim() !== "") console.warn("pinroutes: ignoring bad state file", statePath, e)
    }
    loaded = true
    syncMonitor()
    refresh()
  }

  property string _pendingState: ""
  property bool _writeQueued: false

  function saveState() {
    if (!loaded) return
    _pendingState = JSON.stringify({
      routes: routes,
      monitorEnabled: monitorEnabled,
      autoReapply: autoReapply,
      notifyOnMissing: notifyOnMissing,
      intervalSec: intervalSec
    }, null, 2) + "\n"
    if (stateWriter.running) _writeQueued = true
    else stateWriter.running = true
  }

  Process {
    id: stateReader
    command: ["python3", root.stateHelper, "read", root.statePath]
    stdout: StdioCollector { id: stateReaderOut }
    onExited: function(exitCode) {
      root.restoreState(exitCode === 0 ? stateReaderOut.text : "")
    }
  }

  Process {
    id: stateWriter
    command: ["python3", root.stateHelper, "write", root.statePath]
    stdinEnabled: true
    onStarted: {
      stateWriter.write(root._pendingState)
      stateWriter.stdinEnabled = false // close the pipe so the helper sees EOF
    }
    onExited: {
      stateWriter.stdinEnabled = true
      if (root._writeQueued) {
        root._writeQueued = false
        stateWriter.running = true
      }
    }
  }

  // ---- processes -----------------------------------------------------------

  Process {
    id: tableProcess
    command: ["ip", "-j", "-4", "route", "show"]
    stdout: StdioCollector { id: tableStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var entries = []
      try {
        entries = JSON.parse(String(tableStdout.text || "[]"))
      } catch (e) {
        console.warn("pinroutes: could not parse route table:", e)
        return
      }
      root.handleTable(entries)
    }
  }

  Process {
    id: applyProcess
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: applyStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.flashStatus(root._silentApply ? "" : "Routes applied")
        if (root._silentApply) root.notify("normal", "Routes re-applied", "PinRoutes restored missing routes")
      } else {
        var err = String(applyStderr.text || "").trim()
        // pkexec exits 126/127 when the auth dialog is dismissed — not an error.
        if (exitCode === 126 || exitCode === 127) root.flashStatus("Authorization cancelled")
        else if (err.indexOf("invalid gateway") !== -1) {
          // The gateway went off-net between verify and apply (wifi drop, VPN
          // down). Not a failure worth alerting on: the re-verify below will
          // classify the route as standby, and the netlink monitor retries
          // the moment the gateway's subnet comes back.
          root.flashStatus("Gateway unreachable — route on standby")
        } else {
          root.lastError = err !== "" ? err : "Failed to apply routes (exit " + exitCode + ")"
          if (root._silentApply) root.notify("critical", "Route re-apply failed", root.lastError)
        }
      }
      root.refresh()
    }
  }

  Process {
    id: helperCheckProcess
    command: ["bash", "-c", "test -x " + root.helperDest + " && sudo -n -l " + root.helperDest + " >/dev/null 2>&1"]
    onExited: function(exitCode) {
      root.helperInstalled = exitCode === 0
    }
  }

  Process {
    id: installProcess
    stderr: StdioCollector { id: installStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.flashStatus("Done")
        root.lastError = ""
      } else if (exitCode === 126 || exitCode === 127) {
        root.flashStatus("Authorization cancelled")
      } else {
        root.lastError = String(installStderr.text || "").trim() || "Helper install failed"
      }
      root.checkHelper()
    }
  }

  // Netlink watcher: any route table churn (VPN up/down, resume, DHCP renew)
  // schedules a debounced verify, so lost routes are caught within a second
  // instead of waiting out the periodic interval.
  Process {
    id: monitorProcess
    command: ["ip", "-4", "monitor", "route"]
    stdout: SplitParser {
      onRead: function(line) { verifyDebounce.restart() }
    }
    onExited: monitorRestart.restart()
  }

  function syncMonitor() {
    var want = loaded && monitorEnabled
    if (want && !monitorProcess.running) monitorProcess.running = true
    else if (!want && monitorProcess.running) monitorProcess.running = false
  }

  Timer {
    id: verifyDebounce
    interval: 800
    onTriggered: root.refresh()
  }

  Timer {
    id: monitorRestart
    interval: 3000
    onTriggered: root.syncMonitor()
  }

  // Periodic fallback, like the macOS app's RouteMonitor interval.
  Timer {
    interval: root.intervalSec * 1000
    repeat: true
    running: root.loaded && root.monitorEnabled
    onTriggered: root.refresh()
  }

  Timer {
    // Re-verify shortly after the notification grace window ends, so a route
    // that stays missing gets its alert even with no netlink event to force
    // another pass.
    id: notifyGraceTimer
    interval: root.notifyGraceMs + 500
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2500
    onTriggered: root.actionStatus = ""
  }

  Component.onCompleted: {
    checkHelper()
    stateReader.running = true
  }
}
