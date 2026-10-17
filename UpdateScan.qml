import QtQuick
import Quickshell.Io

// The background update scan, owned by the bar widget rather than the panel.
//
// The panel is loaded only while it is open (see BarWidget.qml), so a scan that
// lived on the panel would not exist while the popup is closed -- and the bar
// badge exists precisely to be read then. Keeping the scan here, on the widget
// that is always loaded, is what lets the badge stay live without the panel's
// editable search field being instantiated in a closed shell.
//
// Data only: this reports what each source OFFERS. The panel still confirms
// each row against its installed snapshot before offering an update, so a stale
// scan can never invent one.
//
// Item rather than QtObject: QtObject has no default property, so a Process or
// Timer child cannot be declared in one. Non-visual -- it carries no size and
// nothing to paint.
Item {
  id: scan
  visible: false

  // Which AUR helper `update_scan.sh` is handed. The panel pushes its
  // user-configured `aurHelper` setting when it loads. Auto-detection runs at
  // startup as a fallback for first-run (no settings file) or if the saved
  // helper is not installed.
  property string aurHelper: "yay"
  property var aurHelpersInstalled: ({})

  // Called by the panel when it loads to sync the user's configured helper.
  function setAurHelper(helper) {
    if (helper === "paru" || helper === "yay" || helper === "pikaur") {
      scan.aurHelper = helper
    }
  }

  readonly property string updateScanScript:
    Qt.resolvedUrl("./update_scan.sh").toString().replace("file://", "")

  property int updateCount: 0
  property var updateRows: ([])
  property var updateKeys: ({})
  property bool updatesDegraded: false
  property double updatesAt: 0

  // Emitted after each completed scan, so a listening panel can repopulate its
  // Updates tab. The panel owns that reaction; this object owns the data.
  signal updated()

  function refresh() {
    // A scan talks to three package managers, two of which may reach the
    // network (AUR RPC / Flathub). Never let two overlap.
    if (updateProc.running) return
    scan.updatesAt = Date.now()
    updateProc.running = true
  }

  function ensureFresh() {
    if (Date.now() - scan.updatesAt > 60000) scan.refresh()
  }

  // One subprocess across all three sources. The helper is passed as $1 and is
  // never interpolated into the script text. Names are read, never executed.
  Process {
    id: updateProc
    running: false
    command: ["sh", scan.updateScanScript, scan.aurHelper, "fossfetch-updates"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: scan.applyUpdateScan(text || "")
    }
  }

  // A quiet periodic re-scan so the bar badge stays honest while the panel sits
  // closed for hours. Five minutes is frequent enough that "you have updates"
  // is never stale for long, and rare enough not to be a background daemon.
  Timer {
    id: updateScanTimer
    interval: 300000
    repeat: true
    running: true
    triggeredOnStart: false
    onTriggered: scan.refresh()
  }

  // One scan shortly after launch so the badge is populated on the first bar
  // render rather than blank for five minutes.
  Timer {
    id: firstUpdateScan
    interval: 1500
    repeat: false
    running: true
    onTriggered: {
      // Let the shell finish starting before asking three package managers
      // questions; running it during login competes with everything else.
      if (scan.updateCount === 0) scan.refresh()
    }
  }

  // Short retry after a degraded scan. The common cause is a transient pacman
  // lock during startup, which clears in seconds; waiting the full five minutes
  // would leave the badge blank for most of the session.
  //
  // The interval backs off instead of staying at 25s. A source that is still
  // broken after a few retries -- a dead AUR helper, a missing binary, a
  // machine that is simply offline -- is not going to heal in 25 seconds, and
  // retrying at that rate for the life of the session re-runs the whole
  // three-source scan every 25 seconds, each pass invoking `fakeroot pacman
  // -Sy` over the network. Capped at the periodic tick so a broken source
  // costs at most one extra scan per five minutes until it comes back, and
  // reset to 25s the moment a scan comes back clean.
  property int retryInterval: 25000
  Timer {
    id: updateRetry
    interval: scan.retryInterval
    repeat: true
    running: false
    onTriggered: {
      if (!scan.updatesDegraded) { updateRetry.stop(); return }
      scan.refresh()
      scan.retryInterval = Math.min(scan.retryInterval * 2, 300000)
    }
  }

  // Which AUR helpers exist, detected once at startup as a fallback if the
  // panel's configured helper is not installed. `command -v` in a subshell so a
  // missing binary is a silent miss rather than an error line.
  Process {
    id: detectAurHelperProc
    running: false
    command: ["sh", "-c", "for h in paru yay pikaur; do command -v \"$h\" >/dev/null 2>&1 && echo \"$h\"; done"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: scan.applyAurHelpers(text || "")
    }
  }

  Component.onCompleted: detectAurHelperProc.running = true

  // Apply detected helpers. Only override the current aurHelper if it's not
  // installed and another one is. The panel will call setAurHelper() with the
  // user's saved preference when it loads, which takes precedence.
  function applyAurHelpers(text) {
    var found = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var h = lines[i].trim()
      if (h === "paru" || h === "yay" || h === "pikaur") found[h] = true
    }
    scan.aurHelpersInstalled = found
    // Only auto-switch if the current helper is not installed and another is.
    if (scan.aurHelpersInstalled[scan.aurHelper] !== true) {
      var preferred = ["paru", "yay", "pikaur"].filter(function (x) { return found[x] === true })
      if (preferred.length > 0) scan.aurHelper = preferred[0]
    }
  }

  // Force an immediate scan, bypassing the 60-second throttle in ensureFresh().
  // Used when the panel opens or the user switches to the Updates tab.
  function forceRefresh() {
    if (updateProc.running) return
    scan.updatesAt = 0  // forces refresh() to run
    scan.refresh()
  }

  // Parse the "UPD|kind|name|<available>" lines into row objects the card can
  // render. Each row carries the package key for its source so the card's
  // existing pendingUpdate() logic recognises it and offers the Update button.
  // Keyed by package name rather than carried as a model role: the row already
  // identifies itself by whichever source key it has, so this needs no extra
  // delegate property and no new ListModel role.
  function applyUpdateScan(text) {
    var rows = []
    var keys = ({})
    var degraded = false
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      // A source that could not answer is not a source with nothing to report.
      if (line.indexOf("SCANFAIL|") === 0) { degraded = true; continue }
      if (line.indexOf("UPD|") !== 0) continue
      var parts = line.split("|")
      if (parts.length < 4) continue
      var kind = parts[1]
      var name = parts[2]
      var avail = parts[3]
      if (name === "" || avail === "") continue
      var row = {
        name: name, description: "", version: avail, website: "", repo: "",
        arch: "", licenses: "", updated: "", rating: "", category: "",
        thumbnail: "", iconName: "", downloadSize: "", installedSize: "",
        dependsOn: "", optionalDeps: "", requiredBy: "", conflictsWith: "",
        provides: "", groups: "", packager: "", branch: "", collection: "",
        aurVotes: "", aurMaintainer: "", aurOutdated: "", aurPopularity: "", _pkg: "",
        pacmanPkg: "", aurPkg: "", flatpakPkg: ""
      }
      if (kind === "pacman") row.pacmanPkg = name
      else if (kind === "flatpak") row.flatpakPkg = name
      else { row.aurPkg = name; row._pkg = name }
      keys[name] = true
      rows.push(row)
    }
    // Stable, deterministic order: newest available version first is meaningless
    // without a date, so sort by name for a list a user can scan by eye.
    rows.sort(function (a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
    // A scan that could not reach a source does NOT get to say "zero updates".
    // checkupdates fails outright while anything holds the pacman lock, which
    // is what happens in the first seconds after a shell start; turning that
    // into a confident empty result would make the badge and the Updates tab
    // vanish until the next five-minute tick even though updates were waiting.
    if (degraded && rows.length === 0) {
      // A TOTAL failure keeps what we already knew: there is nothing to replace
      // it with, and zeroing it would hide the badge exactly when updates are
      // waiting.
      scan.updatesDegraded = true
      updateRetry.start()
      return
    }
    // A PARTIAL scan is degraded too. pacman answered but the AUR helper was
    // locked, say: these rows are real, but they are not the whole answer, and
    // clearing the flag stopped the retry that would have filled in the rest.
    // So take the rows it DID find, and stay degraded until a scan comes back
    // with no SCANFAIL at all.
    scan.updatesDegraded = degraded
    if (degraded) updateRetry.start()
    else {
      updateRetry.stop()
      // A clean scan means every source answered, so the next degraded one
      // starts the retry clock over -- the 25s cadence is for the startup
      // lock, and it should not be remembered across a healthy scan.
      scan.retryInterval = 25000
    }
    scan.updateRows = rows
    scan.updateKeys = keys
    scan.updateCount = rows.length
    scan.updated()
  }
}
