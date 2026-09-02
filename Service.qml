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
  // "<network> <gateway>" pairs from the root-owned allowlist. The installed
  // helper only acts on approved pairs, so silent operations are limited to
  // routes the user has explicitly approved through an authenticated prompt.
  property var approvedMap: ({})
  property var _pendingApply: []
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
  readonly property string approveDest: "/usr/local/bin/pinroutes-approve"
  readonly property string localHelperPath: Qt.resolvedUrl("helper/pinroutes-helper").toString().replace("file://", "")
  readonly property string installScriptPath: Qt.resolvedUrl("helper/pinroutes-helper-install").toString().replace("file://", "")

  // Root never executes files from this user-writable checkout. The two
  // scripts are read into memory once at plugin load; privileged runs pass
  // that captured text as an argv constant to the fixed system interpreter
  // (`pkexec /bin/bash -c <text> ...`). The first approval installs the
  // approver root-owned at /usr/local/bin/pinroutes-approve, and every later
  // approval executes that fixed trusted component instead.
  property string _helperScript: ""
  property string _installerScript: ""
  property bool approveToolInstalled: false
  readonly property string stateHelper: Qt.resolvedUrl("stateio.py").toString().replace("file://", "")
  readonly property string statePath: {
    var base = Quickshell.env("XDG_CONFIG_HOME")
    if (!base) base = Quickshell.env("HOME") + "/.config"
    return base + "/pinroutes/pinroutes.json"
  }

  readonly property int enabledCount: countWhere(function(r) { return r.enabled })
  readonly property int unapprovedCount: {
    if (!helperInstalled) return 0
    var n = 0
    for (var i = 0; i < routes.length; i++) if (!isApproved(routes[i])) n++
    return n
  }
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

  function isApproved(rule) {
    return rule && approvedMap[rule.network + " " + rule.gateway] === true
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
    tableDeadline.restart()
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

      if (autoReapply && helperInstalled && isApproved(rule)) {
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
    // With the helper installed, the allowlist gates every sudo call: rules
    // not yet approved need an authenticated approval first, after which the
    // apply is retried automatically (see installProcess/checkHelper).
    if (helperInstalled && interactive) {
      var unapproved = rules.filter(function(r) { return !isApproved(r) })
      if (unapproved.length > 0) {
        _pendingApply = rules
        approveRoutes()
        return
      }
    }
    var args = []
    for (var i = 0; i < rules.length; i++) {
      if (helperInstalled && !isApproved(rules[i])) continue // silent path: approved only
      args.push("replace", rules[i].network, rules[i].gateway)
    }
    runHelper(args, interactive)
  }

  // Route changes need root. With the helper installed, sudo -n runs it
  // silently (allowlist-enforced); otherwise pkexec pops the shell's themed
  // auth dialog — but only for user-initiated actions, never from the
  // background monitor.
  function runHelper(args, interactive) {
    if (applyProcess.running || args.length === 0) return
    var cmd
    if (helperInstalled) cmd = ["sudo", "-n", helperDest].concat(args)
    else if (interactive && _helperScript !== "") cmd = ["pkexec", "/bin/bash", "-c", _helperScript, "pinroutes-helper"].concat(args)
    else return
    lastError = ""
    _silentApply = !interactive
    applyProcess.command = cmd
    applyProcess.running = true
    applyDeadline.restart()
  }

  // ---- helper install ------------------------------------------------------

  function checkHelper() {
    if (helperCheckProcess.running) return
    helperCheckProcess.running = true
    helperCheckDeadline.restart()
  }

  // One authenticated prompt installs the helper and approves the current
  // route set: the installer embeds the helper and writes the root-owned
  // allowlist, so later silent applies can only touch these exact pairs.
  function approveRoutes() {
    if (installProcess.running) return
    var cmd
    if (approveToolInstalled) {
      cmd = ["pkexec", approveDest, "--approve"]
    } else if (_installerScript !== "") {
      cmd = ["pkexec", "/bin/bash", "-c", _installerScript, "pinroutes-approve", "--approve"]
    } else {
      flashStatus("Still loading — try again in a moment")
      return
    }
    for (var i = 0; i < routes.length; i++) {
      cmd.push(routes[i].network, routes[i].gateway)
    }
    installProcess.command = cmd
    installProcess.running = true
    installDeadline.restart()
  }

  function installHelper() {
    approveRoutes()
  }

  function uninstallHelper() {
    if (installProcess.running) return
    _pendingApply = []
    if (approveToolInstalled) installProcess.command = ["pkexec", approveDest, "--uninstall"]
    else if (_installerScript !== "") installProcess.command = ["pkexec", "/bin/bash", "-c", _installerScript, "pinroutes-approve", "--uninstall"]
    else return
    installProcess.running = true
    installDeadline.restart()
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
    // head enforces the output bound at the producer: an absurdly large
    // table SIGPIPEs ip, pipefail turns that into a nonzero exit, and the
    // truncated output is discarded instead of parsed.
    command: ["bash", "-c", "set -o pipefail; ip -j -4 route show | head -c 4194304"]
    stdout: StdioCollector { id: tableStdout; waitForEnd: true }
    onExited: function(exitCode) {
      tableDeadline.stop()
      if (exitCode !== 0) return
      var text = String(tableStdout.text || "[]")
      if (text.length >= 4 * 1024 * 1024) {
        console.warn("pinroutes: route table output unexpectedly large, skipping")
        return
      }
      var entries = []
      try {
        entries = JSON.parse(text)
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
      applyDeadline.stop()
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
    command: ["bash", "-c",
      "test -x " + root.helperDest + " && sudo -n -l " + root.helperDest + " >/dev/null 2>&1 && echo __PINROUTES_OK__; "
      + "test -x " + root.approveDest + " && echo __PINROUTES_APPROVE__; "
      + "head -c 65536 /etc/pinroutes/routes.allow 2>/dev/null; true"]
    stdout: StdioCollector { id: helperCheckStdout; waitForEnd: true }
    onExited: function(exitCode) {
      helperCheckDeadline.stop()
      var lines = String(helperCheckStdout.text || "").split("\n")
      var installed = false
      var approveTool = false
      var approved = {}
      for (var i = 0; i < lines.length && i <= 200; i++) {
        var line = lines[i].trim()
        if (line === "__PINROUTES_OK__") installed = true
        else if (line === "__PINROUTES_APPROVE__") approveTool = true
        else if (line !== "") approved[line] = true
      }
      root.helperInstalled = installed
      root.approveToolInstalled = approveTool
      root.approvedMap = installed ? approved : {}
      // An approval was waiting on this recheck: retry the apply that
      // triggered it, now allowed through the sudo path.
      if (root._pendingApply.length > 0) {
        var pending = root._pendingApply
        root._pendingApply = []
        if (installed) root.applyRules(pending, true)
      }
    }
  }

  // Script sources are captured once at plugin load; see the property block.
  Process {
    id: helperScriptReader
    command: ["cat", root.localHelperPath]
    stdout: StdioCollector { id: helperScriptOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root._helperScript = String(helperScriptOut.text || "")
    }
  }

  Process {
    id: installerScriptReader
    command: ["cat", root.installScriptPath]
    stdout: StdioCollector { id: installerScriptOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root._installerScript = String(installerScriptOut.text || "")
    }
  }

  Process {
    id: installProcess
    stderr: StdioCollector { id: installStderr; waitForEnd: true }
    onExited: function(exitCode) {
      installDeadline.stop()
      if (exitCode === 0) {
        root.flashStatus("Routes approved")
        root.lastError = ""
      } else {
        root._pendingApply = []
        if (exitCode === 126 || exitCode === 127) root.flashStatus("Authorization cancelled")
        else root.lastError = String(installStderr.text || "").trim() || "Helper install failed"
      }
      root.checkHelper()
    }
  }

  // Netlink watcher: any route table churn (VPN up/down, resume, DHCP renew)
  // schedules a debounced verify, so lost routes are caught within a second
  // instead of waiting out the periodic interval.
  Process {
    id: monitorProcess
    property int failures: 0
    command: ["ip", "-4", "monitor", "route"]
    stdout: SplitParser {
      onRead: function(line) {
        monitorProcess.failures = 0 // it's producing events, so it's healthy
        verifyDebounce.restart()
      }
    }
    onExited: {
      // Escalating backoff so a persistently failing monitor (ip missing,
      // netlink refused) cannot spin the shell in a tight restart loop.
      failures = Math.min(failures + 1, 6)
      monitorRestart.interval = 3000 * Math.pow(2, failures - 1)
      monitorRestart.restart()
    }
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

  // Deadlines: every short-lived process is reaped if it overstays, so a
  // wedged ip/sudo call can never permanently jam refreshes or applies. The
  // pkexec-backed ones get generous windows for the auth dialog.
  Timer {
    id: tableDeadline
    interval: 15000
    onTriggered: if (tableProcess.running) tableProcess.running = false
  }

  Timer {
    id: helperCheckDeadline
    interval: 15000
    onTriggered: if (helperCheckProcess.running) helperCheckProcess.running = false
  }

  Timer {
    id: applyDeadline
    interval: 300000
    onTriggered: if (applyProcess.running) applyProcess.running = false
  }

  Timer {
    id: installDeadline
    interval: 300000
    onTriggered: if (installProcess.running) installProcess.running = false
  }

  Component.onCompleted: {
    helperScriptReader.running = true
    installerScriptReader.running = true
    checkHelper()
    stateReader.running = true
  }
}
