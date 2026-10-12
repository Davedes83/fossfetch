import QtQuick
import QtQuick.Layouts
// Aliased, not a plain import: an unaliased `import QtQuick.Controls` would
// shadow the search box's TextField with Controls' own (different default
// padding, background and metrics) and silently restyle it.
import QtQuick.Controls as QC
import Quickshell

// SPACING: every gap, margin and padding below uses a `Style.spacing.*` token so
// a theme can override it by name. Sizes (card height, panel width, button
// width) and the negative `anchors.margins` used for hover bleed stay as
// `Style.space(N)` — the spacing token set has no names for those, and they
// still scale with the user's font size via Style.effectiveSpacingScale. Use a
// token for new spacing; use Style.space() only for a component's own size.
import Quickshell.Io
import qs.Commons
import qs.Ui
// Model.js is imported as a namespace with a plain `import "..." as`, which is
// the only form QML accepts for a JS resource (`.import "..." as` is a syntax
// error, and it fails the WHOLE file — the panel then silently never opens).
import "Model.js" as Model

// FossFetch browse panel. Three search-driven tabs list FOSS apps — Pacman
// (Arch repos), Flatpak (Flathub) and AUR (Yay/Paru) — each with one-click
// install. Results come straight from live `pacman -Ss` / `flatpak search` /
// the AUR RPC; metadata (repo, version, arch, license) and a website/GitHub
// link are enriched via `pacman -Si` / Flatpak appstream info.
Panel {
  id: root
  moduleName: "davedes.fossfetch"
  ipcTarget: "fossfetch"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // Injected by the BarWidget loader
  property int panelWidth: 560
  property int debounceMs: 150

  readonly property var barIdentity: hostWidget || root

  // ------------------------------------------------------------ theme palette
  // The shell only exposes foreground/background/accent/urgent/muted via the
  // Color singleton, but every theme ships a full extended palette in
  // colors.toml (green, cyan, blue, yellow, red, accent…). Read it from the
  // active theme copy so buttons, the confirm state and highlights blend with
  // whatever theme is running instead of being locked to Catppuccin pastels.
  property var themeColors: ({})
  function themeColor(name, fallback) {
    var v = root.themeColors[name]
    return (typeof v === "string" && v.length > 0) ? v : fallback
  }
  readonly property color pacmanColor:    root.themeColor("green",  "#a6e3a1")
  readonly property color aurColor:       root.themeColor("cyan",   "#94e2d5")
  readonly property color flatpakColor:   root.themeColor("blue",   "#89b4fa")
  readonly property color confirmColor:   root.themeColor("yellow", "#f9e2af")
  // Highlight colour for the matched run in a card title.
  readonly property string matchColor: String(Color.accent)

  // --------------------------------------------------------------- icon set
  // One glyph per concept, one place. Every codepoint below was read out of the
  // font this machine actually resolves `monospace` to (JetBrainsMono Nerd
  // Font), not copied off the Nerd Fonts website — the glyphs are the
  // Material Design (`md-*`) set, which is what the shell's own menu draws, so
  // FossFetch and the launcher it sits next to share one icon language.
  //
  // Written as explicit surrogate pairs on purpose. JavaScript's `\uXXXX`
  // escape is exactly four hex digits, so `\uF0349` silently parses as `\uF034`
  // followed by a literal "9" — the classic way a Nerd Font icon turns into
  // tofu without anything reporting an error.
  //
  // Previously these were raw Font Awesome codepoints, which is how the search
  // field came to be drawing a BOOKMARK.
  readonly property var icons: ({
    // name        glyph  (Material Design set, read out of the installed font)
    search     : "\uDB80\uDF49",  // U+F0349 magnify
    settings   : "\uDB82\uDCBB",  // U+F08BB cog-outline
    close      : "\uDB80\uDD56",  // U+F0156 close
    check      : "\uDB80\uDD2C",  // U+F012C check
    checkCircle: "\uDB81\uDDE1",  // U+F05E1 check-circle-outline
    box        : "\uDB80\uDFD7",  // U+F03D7 package-variant-closed
    info       : "\uDB80\uDEFD",  // U+F02FD information-outline
    external   : "\uDB80\uDFCC",  // U+F03CC open-in-new
    download   : "\uDB80\uDDDA",  // U+F01DA download
    trash      : "\uDB82\uDE7A",  // U+F0A7A trash-can-outline
    history    : "\uDB80\uDEDA",  // U+F02DA history
    warning    : "\uDB81\uDDD6",  // U+F05D6 alert-circle-outline
    shield     : "\uDB83\uDCC8",  // U+F0CC8 shield-check-outline
    clock      : "\uDB80\uDD50",  // U+F0150 clock-outline
    cube       : "\uDB80\uDDA7",  // U+F01A7 cube-outline
    branch     : "\uDB81\uDE2C",  // U+F062C source-branch
  })

  // Every icon in the panel goes through this component so family, optical
  // size and tint cannot drift per call-site. Sizes come from the shell's
  // font scale, so icons track the user's text size like everything else does.
  component Icon: Text {
    property real iconSize: Style.font.body
    property real tint: 1.0
    font.family: Style.font.resolvedFamily
    font.pixelSize: iconSize
    textFormat: Text.PlainText
    // PUA glyphs have no meaningful advance width; centring on the layout box
    // (not the glyph) is what keeps a row of icons optically aligned instead
    // of each one drifting on its own side bearing.
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    color: Util.alpha(Color.popups.text, tint)
  }

  FileView {
    path: Color.home + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadThemeColors(text())
    onLoadFailed: root.themeColors = ({})
  }

  function loadThemeColors(raw) {
    var parsed = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*"?(#[0-9A-Fa-f]{6})/)
      if (m) parsed[m[1]] = m[2]
    }
    root.themeColors = parsed
  }



  // --------------------------------------------------------------- tabs
  property int activeTab: 0
  readonly property bool isPacman: activeTab === 0
  readonly property bool isFlatpak: activeTab === 1
  readonly property bool isAur: activeTab === 2
  // "All" runs the three live backends at once into one list. The three
  // handlers already append into a shared model and de-duplicate by key, so
  // this is a launcher change rather than a second code path. It is opt-in
  // (see allEnabled) because merging three backends is slower per keystroke
  // than searching one, which is the wrong default for a launcher.
  readonly property bool isAll: activeTab === 3
  // The Updates tab is offered only when there is something to show. A launcher
  // that offers an "Updates" tab with nothing in it teaches users to ignore it.
  readonly property bool isUpdates: activeTab === 4
  readonly property bool isLive: root.isPacman || root.isFlatpak || root.isAur || root.isAll
  property string query: ""

  // --------------------------------------------------- options (persisted)
  // User-facing switches: whether the AUR / Flatpak tabs are shown, and which
  // AUR helper the install buttons use. Persisted to the shared omarchy
  // settings dir so the choices stick across shell restarts.
  property bool flatpakEnabled: true
  property bool aurEnabled: true
  property bool allEnabled: false
  property string aurHelper: "yay"
  property bool showCoffeeButton: true

  // The supporter prompt is re-shown once per RELEASE, not once per launch.
  //
  // Bump this on any user-visible update and the box comes back ticked; the
  // user can untick it again and that choice holds until the NEXT bump. The
  // alternative -- a plain `true` default -- would mean a user who unticks it
  // never sees it again, and the project gets no way to ask after a release
  // that actually changed things.
  //
  // It is a checkbox, not a modal: nothing is blocked, nothing is decided for
  // the user, and one click turns it off again.
  readonly property string supportPromptEpoch: "2026-10-12a"
  property bool showOptions: false

  // ------------------------------------------------------------ result view
  // How the result list is ordered, and whether packages you already have are
  // hidden. Both are persisted with the other options so a user who sorts by
  // popularity gets that back after a shell restart rather than silently
  // reverting to relevance.
  //
  // "relevance" is the default and is deliberately NOT re-applied by sorting:
  // the backends append results in relevance order already, and that ranking
  // knows the query in a way no stored key here can reproduce.
  readonly property var sortModes: Model.sortModes()
  property string sortMode: "relevance"
  property bool hideInstalled: false

  // Monotonic counter behind each row's insertion order. Relevance sorting is
  // "put them back the way the backend ranked them", which needs the original
  // sequence preserved — the backend's ranking is not re-derivable from any
  // field on the row. Reset per search in buildModel().
  property int orderSeq: 0

  function sortLabel(m) {
    if (m === "installed") return "Installed first"
    if (m === "popularity") return "Popularity"
    if (m === "updated") return "Updated"
    if (m === "name") return "Name"
    return "Relevance"
  }

  function sortLabelFor() { return root.sortLabel(root.effectiveSortMode()) }

  // The modes this result set can actually order by.
  //
  // A mode whose field is absent everywhere is worse than no mode at all:
  // sorting Pacman results by "Popularity" finds no popularity on any row, so
  // every pair ties and it falls through to the name tiebreak — alphabetical
  // order wearing a popularity label. Offering it there makes Relevance and
  // Popularity produce identical output, and both look broken. So the cycle
  // only contains modes that will visibly do something here: popularity on
  // AUR/Flathub results, Updated once build dates have arrived.
  property var availableSortModes: Model.sortModes()

  function computeSortModes() {
    var hasPop = false
    var hasDate = false
    var hasInstalled = false
    var hasMissing = false
    for (var i = 0; i < filteredModel.count; i++) {
      var r = filteredModel.get(i)
      if (!r) continue
      if (!hasPop && Model.popularityKey(r.aurPopularity) >= 0) hasPop = true
      if (!hasDate && Model.updatedKey(r.updated) >= 0) hasDate = true
      // Partition flags, tracked apart: a row already accounted for must not
      // fall through to the other branch and claim to be the opposite.
      if (Model.isInstalledRow(r)) { if (!hasInstalled) hasInstalled = true }
      else if (!hasMissing) hasMissing = true
    }
    var out = ["relevance"]
    // "Installed first" partitions the rows, so it only means anything when
    // both groups are present -- and never while "Hide installed" is on, which
    // has already removed one of them. Offering it in those states is the
    // silent no-op this list exists to avoid.
    if (hasInstalled && hasMissing && !root.hideInstalled) out.push("installed")
    if (hasPop) out.push("popularity")
    if (hasDate) out.push("updated")
    out.push("name")
    return out
  }

  // A stored mode that the current results cannot sort by (Popularity carried
  // over from an AUR search, say) is shown and applied as Relevance rather than
  // pretending to honour a preference it cannot.
  function effectiveSortMode() {
    return root.availableSortModes.indexOf(root.sortMode) >= 0
      ? root.sortMode : "relevance"
  }

  // Ctrl+S walks the cycle. Anything unrecognised (a hand-edited settings
  // file, a mode from a newer version) is normalised back to relevance rather
  // than left in a state the UI cannot label.
  function normalizeSort(m) {
    return root.sortModes.indexOf(String(m === undefined || m === null ? "" : m)) >= 0
      ? String(m) : "relevance"
  }

  function cycleSort() {
    var modes = root.availableSortModes
    var i = modes.indexOf(root.effectiveSortMode())
    if (i < 0) i = 0
    root.setSortMode(modes[(i + 1) % modes.length])
  }

  function setSortMode(m) {
    var next = root.normalizeSort(m)
    if (next === root.sortMode) return
    root.sortMode = next
    root.applyView(true)
    root.persistOptions()
  }

  function setHideInstalled(v) {
    if (root.hideInstalled === v) return
    root.hideInstalled = v
    // The rows already in the model have to be re-gated: this filter is applied
    // when a row is added, so rows admitted under the old setting are still
    // sitting there until the list is rebuilt.
    root.applyView(true)
    root.persistOptions()
  }

  // ------------------------------------------------------- multi-selection

  // Selected rows, keyed by rowKey so the selection survives a re-sort, a
  // filter, or the results arriving from another backend -- all of which
  // renumber every index. An object used as a set rather than an array of
  // indexes, because the indexes are the one thing that changes underneath it.
  property var selectedKeys: ({})
  // Where a Shift-range started. Kept as a key for the same reason; losing it
  // on a rebuild would silently restart the range somewhere else.
  property string selectionAnchor: ""

  readonly property int selectedCount: Object.keys(root.selectedKeys).length

  function isSelected(r) {
    if (!r) return false
    return root.selectedKeys[root.rowKey(r)] === true
  }

  // The delegate asks by index rather than carrying its own copy of the key.
  // The key is built from _pkg, which cannot be declared as a QML property
  // (leading underscore is reserved), so a delegate could only ever rebuild
  // an approximation of it -- and a key that silently differs from the one the
  // model uses marks the wrong row.
  function isSelectedRowAt(i) {
    if (root.selectedCount === 0) return false
    var r = filteredModel.get(i)
    return r ? root.isSelected(r) : false
  }

  // ------------------------------------------------------- batch execution

  // One command per SOURCE, not one per package.
  //
  // `actionProc` is a single Process and pacman holds a global database lock
  // for the whole of an install. Launching a terminal per selected package
  // would either deadlock on that lock or open a dozen windows for a dozen
  // packages, and each would independently re-resolve the shared dependency
  // set. Grouping by source lets pacman resolve the whole set once.
  //
  // What comes back is one group per (mode, kind): the pacman installs in one
  // list, the AUR ones in another, flatpak's separately, because each needs a
  // different command.
  function batchGroups(mode) {
    var rows = root.selectedRows()
    var byKey = {}
    var order = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var kind = null, pkg = ""
      if (mode === "update") {
        var u = root.pendingUpdate(row)
        if (u) { kind = u.kind; pkg = u.pkg }
      } else {
        var spec = root.cardInstallSpec(row)
        // A batch "install" must not install something that is already there
        // and turn into a re-install; that is the card's own decision, and it
        // says remove. Skipping keeps Enter's meaning honest.
        if (spec && ((mode === "install" && spec.mode === "install")
          || (mode === "remove" && spec.mode === "remove"))) {
          kind = spec.kind
          pkg = spec.pkg
        }
      }
      if (!kind || !pkg) continue
      var key = mode + ":" + kind
      if (!byKey[key]) {
        byKey[key] = { mode: mode, kind: kind, pkgs: [], names: [] }
        order.push(byKey[key])
      }
      if (byKey[key].pkgs.indexOf(pkg) < 0) {
        byKey[key].pkgs.push(pkg)
        byKey[key].names.push(row.name || pkg)
      }
    }
    // Deduplicated by package id: the same package offered by both a repo and
    // the AUR must not be handed to the installer twice.
    return order.filter(function (g) { return g.pkgs.length > 0 })
  }

  property var batchQueue: []
  // True from the moment a batch is confirmed until its LAST group exits --
  // NOT "is the queue non-empty". A batch with a single group empties the queue
  // the instant it starts, and keying the chain off queue length would stop
  // that batch dead: the exit would find nothing left and report the whole
  // thing finished before it had finished.
  property bool batchActive: false
  // Exit status of the most recent command. Quickshell's Process exposes it
  // via the exited() signal; captured because onExited arrives after the
  // queue has already been drained.
  property int lastBatchExitCode: 0
  readonly property bool batchRunning: root.batchActive

  // Armed but not yet running: the confirmation (or the arm-then-run second
// click) is still outstanding. Distinct from batchRunning, because "Working…"
// over a batch that has not launched anything is simply untrue.
readonly property bool batchArmed: root.pendingAction !== null && root.batchQueue.length > 0

  // Runs the next queued group, or reports the whole batch finished.
  // BARE ids, deliberately: `root.actionProc` and `root.confirmResetTimer`
  // resolve to undefined in this scope and throw, while the identical
  // single-action code below writes the bare id and works. The failure is
  // silent from the user's side -- batchActive has already been set by the
  // time the throw happens, so the bar reads "Working…" forever over a
  // process that was never launched.
  function runNextBatchGroup() {
    if (root.batchQueue.length === 0) {
      root.batchActive = false
      root.clearSelection()
      root.refreshInstalled(true)
      root.updatesAt = 0
      root.refreshUpdates()
      // The outcome is whatever the last command returned, not "done". A batch
      // containing one package that no longer exists makes pacman refuse the
      // WHOLE command before doing anything, and the terminal is gone in under
      // a second -- so an unconditional "Batch finished" is how a batch that
      // installed nothing ends up reported as a success.
      if (root.lastBatchExitCode !== 0)
        root.notify("FossFetch", "Batch failed (exit " + root.lastBatchExitCode
          + "). Nothing was installed -- re-run it to see why.")
      else
        root.notify("FossFetch", "Batch finished. See the terminals for the results.")
      return
    }
    var g = root.batchQueue[0]
    root.batchQueue = root.batchQueue.slice(1)
    // Only now is a batch actually running. Setting this at ARM time made
    // "Working…" appear over a batch that had launched nothing yet, and
    // hid the very buttons needed to confirm or cancel it.
    root.batchActive = true
    root.lastActionLabel = g.names.length === 1
      ? g.names[0] : (g.names.length + " packages")
    root.lastActionKind = g.kind
    root.lastActionVerb = g.mode
    actionProc.command = root.terminalArgv(root.batchCommand(g))
    actionProc.running = true
    installFinishedTimer.restart()
  }

  // The literal argument list for one group. Kept separate from the launch so
  // the command can be asserted directly in tests instead of inferred from a
  // terminal window that has already closed.
  function batchCommand(g) {
    var pkgs = g.pkgs
    if (g.mode === "install") {
      if (g.kind === "pacman") return ["sudo", "pacman", "-S", "--needed"].concat(pkgs)
      if (g.kind === "yay") return ["yay", "-S", "--needed"].concat(pkgs)
      if (g.kind === "paru") return ["paru", "-S", "--needed"].concat(pkgs)
      return ["flatpak", "install", "--assumeyes", "flathub"].concat(pkgs)
    }
    if (g.mode === "update") {
      if (g.kind === "pacman") return ["sudo", "pacman", "-S", "-y"].concat(pkgs)
      if (g.kind === "yay") return ["yay", "-S"].concat(pkgs)
      if (g.kind === "paru") return ["paru", "-S"].concat(pkgs)
      return ["flatpak", "update", "-y"].concat(pkgs)
    }
    // Removal stays non-cascading for every source, exactly as the single-row
    // path is: no -s, no --assumeyes for removal, so nothing the user did not
    // name is taken away with it.
    if (g.kind === "pacman") return ["sudo", "pacman", "-R"].concat(pkgs)
    if (g.kind === "yay") return ["yay", "-R"].concat(pkgs)
    if (g.kind === "paru") return ["paru", "-R"].concat(pkgs)
    return ["flatpak", "uninstall"].concat(pkgs)
  }

  // How many PACKAGES a mode covers, as opposed to how many groups it produced.
// batchGroups returns one entry per source, so a five-package pacman batch is
// a length-1 array; comparing that against a row count is how "every selected
// package is installed" silently became "never".
function batchPkgCount(mode) {
    var groups = root.batchGroups(mode)
    var n = 0
    for (var i = 0; i < groups.length; i++) n += groups[i].pkgs.length
    return n
  }

  // Start a batch. Removal still goes through the confirmation path; install
  // and update keep the same arm-then-run second click the single-row buttons
  // use, so a batch is never more destructive than the action it stands for.
  function startBatch(mode) {
    if (root.selectedCount === 0 || !root.isLive) return
    var groups = root.batchGroups(mode)
    if (groups.length === 0) {
      // The selection held nothing this mode applies to (all already
      // installed, say). Say so rather than appearing to do nothing.
      root.notify("FossFetch", "None of the selected packages can be " + mode + "d.")
      return
    }
    var total = 0
    for (var i = 0; i < groups.length; i++) total += groups[i].pkgs.length
    if (mode === "remove") {
      root.pendingAction = { mode: "remove", kind: groups[0].kind,
                             pkg: total + " packages", name: total + " packages" }
      root.batchQueue = groups
      return
    }
    if (root.actionPending(mode, groups[0].kind, total + " packages")) {
      root.pendingAction = null
      root.batchQueue = groups
      root.runNextBatchGroup()
      return
    }
    root.pendingAction = { mode: mode, kind: groups[0].kind,
                           pkg: total + " packages", name: total + " packages" }
    root.batchQueue = groups
    confirmResetTimer.restart()
  }

  // Rebuild the key set after a sort/filter/rebuild. Rows that are no longer on
  // screen are dropped rather than carried: selecting something and then
  // hiding it should not leave it queued for an action the user cannot see.
  function pruneSelection() {
    var live = {}
    var kept = 0
    for (var i = 0; i < filteredModel.count; i++) {
      var r = filteredModel.get(i)
      if (!r) continue
      var k = root.rowKey(r)
      if (root.selectedKeys[k] === true) { live[k] = true; kept++ }
    }
    root.selectedKeys = live
    if (root.selectionAnchor !== "" && live[root.selectionAnchor] !== true)
      root.selectionAnchor = ""
    return kept
  }

  function clearSelection() {
    if (root.selectedCount === 0) return
    root.selectedKeys = ({})
    root.selectionAnchor = ""
  }

  function toggleSelect(r) {
    var k = root.rowKey(r)
    var next = {}
    for (var key in root.selectedKeys) next[key] = root.selectedKeys[key]
    if (next[k] === true) delete next[k]
    else next[k] = true
    root.selectedKeys = next
    root.selectionAnchor = k
  }

  // Shift+arrows extend a contiguous range from the anchor. Re-clicking after
  // moving the cursor re-seeds the anchor, so the range never silently spans
  // back to a row the user has long since scrolled past.
  function selectRange(toRow) {
    if (root.selectionAnchor === "") { toggleSelect(toRow); return }
    var ai = -1, ti = -1
    for (var i = 0; i < filteredModel.count; i++) {
      var r = filteredModel.get(i)
      if (!r) continue
      var k = root.rowKey(r)
      if (k === root.selectionAnchor) ai = i
      if (k === root.rowKey(toRow)) ti = i
    }
    if (ai < 0) ai = ti
    if (ti < 0 || ai < 0) return
    var lo = Math.min(ai, ti), hi = Math.max(ai, ti)
    var next = {}
    for (var key in root.selectedKeys) next[key] = root.selectedKeys[key]
    for (var j = lo; j <= hi; j++) {
      var rr = filteredModel.get(j)
      if (rr) next[root.rowKey(rr)] = true
    }
    root.selectedKeys = next
  }

  function selectAll() {
    var next = {}
    for (var i = 0; i < filteredModel.count; i++) {
      var r = filteredModel.get(i)
      if (r) next[root.rowKey(r)] = true
    }
    root.selectedKeys = next
    if (root.selectionAnchor === "" && filteredModel.count > 0)
      root.selectionAnchor = root.rowKey(filteredModel.get(0))
  }

  // Selected rows as a plain array, in the order they appear on screen.
  function selectedRows() {
    var out = []
    for (var i = 0; i < filteredModel.count; i++) {
      var r = filteredModel.get(i)
      if (r && root.isSelected(r)) out.push(r)
    }
    return out
  }

  // AUR helpers actually present on this machine, detected once at panel open.
  // Previously the default was hard-coded to `yay`, so a paru-only user got an
  // install button that opened a terminal running a command that does not
  // exist — with no indication that anything was wrong.
  property var aurHelpersInstalled: ({})
  readonly property bool aurHelperInstalled: root.aurHelpersInstalled[root.aurHelper] === true

  function detectAurHelpers(text) {
    var found = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var h = lines[i].trim()
      if (h === "yay" || h === "paru" || h === "pikaur") found[h] = true
    }
    root.aurHelpersInstalled = found
    // Follow the machine: if the saved helper is not installed but another one
    // is, switch to it rather than leaving a dead button selected.
    if (Object.keys(found).length > 0 && found[root.aurHelper] !== true) {
      var preferred = ["paru", "yay", "pikaur"].filter(function (h) { return found[h] === true })
      if (preferred.length > 0) root.setAurHelper(preferred[0])
    }
  }

  function setFlatpakEnabled(v) {
    root.flatpakEnabled = !!v
    if (!root.flatpakEnabled && root.activeTab === 1) root.switchTab(0)
    root.persistOptions()
  }

  function setAurEnabled(v) {
    root.aurEnabled = !!v
    if (!root.aurEnabled && root.activeTab === 2) root.switchTab(0)
    root.persistOptions()
  }

  function setAllEnabled(v) {
    root.allEnabled = !!v
    if (!root.allEnabled && root.activeTab === 3) root.switchTab(0)
    root.persistOptions()
  }

  function setAurHelper(v) {
    root.aurHelper = v === "paru" ? "paru" : "yay"
    root.persistOptions()
  }

  function setShowCoffeeButton(v) {
    root.showCoffeeButton = !!v
    root.persistOptions()
  }

  // ---------------------------------------------------- toolbar icon design
  // Visual style applied to the "Find App" pill in the top bar. One of:
  // current | outline | soft | bold | minimal | icon. The panel itself keeps
  // its stock look; this setting is pushed to the BarWidget so the button in
  // the bar restyles itself live.
  // See BarWidget.qml: "pill" (default) or "icon". The six-way picker that
  // used to live in Settings is gone; those styles are normalised onto "pill"
  // on load so an existing settings file can't leave the bar unstyled.
  readonly property var designs: ["pill", "icon", "circle", "text", "brand"]
  // "icon" for a first install, and "pill" for an install that already has a
  // settings file without a stored choice. The two are different situations:
  // a fresh install has nobody's bar to restyle, while an existing user whose
  // file predates this setting is on whatever they have been looking at, and
  // silently switching them is not a default, it is a change.
  property string panelDesign: "icon"

  function normalizeDesign(d) {
    return root.designs.indexOf(d) !== -1 ? d : "pill"
  }

  readonly property string appstreamStateScript: Qt.resolvedUrl("./appstream_state.py").toString().replace("file://", "")
  readonly property string updateScanScript: Qt.resolvedUrl("./update_scan.sh").toString().replace("file://", "")
  readonly property string optionsFilePath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/davedes.fossfetch.json"

  // Hardened options write: pushes the JSON to appstream_state.py write-options,
  // which verifies ownership + no-follow for the whole path and swaps atomically.
  Process {
    id: optionsWriter
    running: false
    stdinEnabled: true
    property string pending: ""
    onStarted: {
      if (optionsWriter.pending === "") return
      optionsWriter.write(optionsWriter.pending)
      // appstream_state.py reads stdin to EOF before it writes anything, and
      // Quickshell keeps the child's write channel open until stdinEnabled goes
      // false. Without this close the helper blocks in read() forever, the
      // options file is never updated, and every setting silently reverts to
      // its last persisted value on shell reset.
      optionsWriter.stdinEnabled = false
    }
  }

  function setPanelDesign(d) {
    root.panelDesign = root.normalizeDesign(d)
    root.persistOptions()
    if (root.hostWidget && root.hostWidget.setToolbarDesign)
      root.hostWidget.setToolbarDesign(d)
  }

  // ------------------------------------------------------- recent searches
  // Most recent first, de-duplicated case-insensitively, capped. Kept in the
  // same settings file as the toggles so there is exactly one persisted path
  // and one hardened writer.
  property var recentSearches: []
  readonly property int recentLimit: 8

  // A query is only remembered once the typing STOPS.
  //
  // Live search fires on every debounced keystroke, so recording a recent from
  // there filed every intermediate prefix of a word as a separate entry —
  // typing "vivaldi" filled the list with via, vial, vival, vivald and vivaldi.
  // Those were never searches anyone ran; they are the innards of one search.
  //
  // So the pending query is held here and flushed after a settle window with
  // no further typing, or immediately on an explicit commit (Enter, Tab, close).
  // A genuine pause longer than the window still records both halves, which is
  // the honest reading: those really were two separate searches.
  property string recentPending: ""
  readonly property int recentSettleMs: 1200

  // Set while the field is filled programmatically, so a suggestion is not
  // mistaken for typing. See applyClipboard().
  property bool suppressRecentSettle: false

  function noteSearch(q, armTimer) {
    var term = String(q === undefined || q === null ? "" : q).trim().toLowerCase()
    // Below the minimum length: drop it now rather than arming a timer that
    // would go on to record it.
    if (term.length < 3 || term.length > 60) {
      root.recentPending = ""
      recentSettle.stop()
      return
    }
    root.recentPending = term
    if (armTimer === false) {
      // Still armed as a pending commit — so acting on the suggestion with
      // Enter/Tab/close DOES remember it — but the settle timer stays stopped,
      // so simply ignoring a clipboard suggestion never records it.
      recentSettle.stop()
      return
    }
    recentSettle.start()
  }

  function flushRecent() {
    recentSettle.stop()
    var term = root.recentPending
    root.recentPending = ""
    if (term === "") return
    root.rememberSearch(term)
  }

  Timer {
    id: recentSettle
    interval: root.recentSettleMs
    repeat: false
    onTriggered: root.flushRecent()
  }

  function rememberSearch(q) {
    var term = String(q || "").trim().toLowerCase()
    // One or two characters produce a flood of useless recents.
    if (term.length < 3 || term.length > 60) return
    var next = []
    next.push(term)
    for (var i = 0; i < root.recentSearches.length && next.length < root.recentLimit; i++) {
      if (root.recentSearches[i] !== term) next.push(root.recentSearches[i])
    }
    root.recentSearches = next
    root.persistOptions()
  }

  function clearRecents() {
    if (root.recentSearches.length === 0) return
    root.recentSearches = []
    root.persistOptions()
  }

  function persistOptions() {
    // Persisted through appstream_state.py's owner-checked, no-follow dirfd
    // transaction (never through an unchecked HOME path).
    optionsWriter.pending = JSON.stringify({
      flatpak: root.flatpakEnabled,
      aur: root.aurEnabled,
      all: root.allEnabled,
      aurHelper: root.aurHelper,
      design: root.panelDesign,
      showCoffee: root.showCoffeeButton,
      supportEpoch: root.supportPromptEpoch,
      hotkeyInstalled: root.hotkeyInstalled,
      sortMode: root.sortMode,
      hideInstalled: root.hideInstalled,
      recentSearches: root.recentSearches
    }, null, 2) + "\n"
    optionsWriter.command = ["python3", root.appstreamStateScript, "write-options", root.optionsFilePath]
    // Reopen the write channel for this run: onStarted closes it again to hand
    // the helper its EOF. Set before the restart so a still-terminating
    // previous run cannot race the new one.
    optionsWriter.stdinEnabled = true
    optionsWriter.running = false
    optionsWriter.running = true
  }

  FileView {
    id: optionsFile
    path: root.optionsFilePath
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var raw = text()
        // No settings file at all: this is a first install, so the declared
        // default ("icon") stands and nothing is written yet. Writing an
        // options file on a mere load would create one for a user who has not
        // touched anything.
        if (raw === undefined || raw === null || String(raw).trim() === "") return
        var data = JSON.parse(raw)
        if (typeof data.flatpak === "boolean") root.flatpakEnabled = data.flatpak
        if (typeof data.aur === "boolean") root.aurEnabled = data.aur
        if (typeof data.all === "boolean") root.allEnabled = data.all
        if (data.aurHelper === "yay" || data.aurHelper === "paru") root.aurHelper = data.aurHelper
        // The supporter prompt is re-armed once per release. A stored epoch
        // from an older release -- or none at all, which is every existing
        // install -- means this is an update, so the box defaults to ticked.
        //
        // The epoch is written back straight away: without that the stored
        // value would still be stale on the next launch, re-arming the prompt
        // every time and making the untick impossible to keep.
        var storedEpoch = (typeof data.supportEpoch === "string") ? data.supportEpoch : ""
        if (storedEpoch !== root.supportPromptEpoch) {
          root.showCoffeeButton = true
          root.persistOptions()
        } else if (typeof data.showCoffee === "boolean") {
          root.showCoffeeButton = data.showCoffee
        }
        // The settings file is user-writable, so the sort mode is validated
        // against the known list rather than trusted: an unknown value would
        // leave the cycle index at -1 and Ctrl+S would step from nowhere.
        root.sortMode = root.normalizeSort(data.sortMode)
        if (typeof data.hotkeyInstalled === "boolean") root.hotkeyInstalled = data.hotkeyInstalled
        if (typeof data.hideInstalled === "boolean") root.hideInstalled = data.hideInstalled
        root.panelDesign = root.normalizeDesign(data.design)
        if (Array.isArray(data.recentSearches)) {
          // Defensive: the file is user-writable, so treat every entry as
          // untrusted input and keep only short plain strings.
          var clean = []
          for (var i = 0; i < data.recentSearches.length && clean.length < root.recentLimit; i++) {
            var e = data.recentSearches[i]
            if (typeof e !== "string") continue
            var t = e.trim().toLowerCase()
            if (t.length < 3 || t.length > 60 || clean.indexOf(t) !== -1) continue
            clean.push(t)
          }
          root.recentSearches = clean
        }
        if (root.hostWidget && root.hostWidget.setToolbarDesign)
          root.hostWidget.setToolbarDesign(root.panelDesign)
      } catch (e) { console.warn("[fossfetch] options load failed:", e) }
    }
  }

  // Enabled tab ids in their on-screen order (Pacman -> AUR -> Flatpak).
  function visibleTabs() {
    var list = [0]
    if (root.aurEnabled) list.push(2)
    if (root.flatpakEnabled) list.push(1)
    // The Updates tab is offered only when there is something to show — an
    // "Updates" tab that opens to an empty list teaches users to ignore it.
    if (root.updateCount > 0) list.push(4)
    // Only worth a tab once there is something to merge, and only if the
    // user opted in.
    if (root.allEnabled && list.length > 2) list.push(3)
    return list
  }

  function switchTab(t) {
    // Tab is a commit: the user has decided what they searched for.
    root.flushRecent()
    if (activeTab === t) return
    // Retire any search still in flight BEFORE switching.
    //
    // rebuildResults() correctly repopulates the Updates tab from the scan's
    // own rows, but a Flatpak or AUR search launched a moment earlier was
    // still running, and its results handler only compares its own sequence
    // against searchSeq. With nothing changing that sequence, the late rows
    // passed the check and were appended to a list they had nothing to do
    // with -- so a search for "firefox" left Datcord and Deckr sitting in
    // Updates next to the one package that actually had an update.
    searchSeq++
    activeTab = t
    resultsList.currentIndex = -1
    rebuildResults()
    // Re-assert focus WITHOUT selecting the text: the query carries across tabs,
    // and selectAll() here would wipe the search the moment you pressed Tab.
    refocus()
  }

  // The hero subtitle spells the source out in full; a 180px-wide segment
  // cannot. "Pacman / AUR / Flatpak" reads fine, "Arch repos (Pacman)" does not.
  function shortTabLabel(t) {
    if (t === 0) return "Pacman"
    if (t === 1) return "Flatpak"
    if (t === 2) return "AUR"
    if (t === 4) return "Updates"
    return "All"
  }

  function tabLabel() {
    if (isAll) return "All"
    if (isUpdates) return "Updates (" + root.updateCount + ")"
    if (isPacman) return "Arch repos (Pacman)"
    if (isFlatpak) return "Flathub (Flatpak)"
    return "AUR (Yay / Paru)"
  }
  function tabCaption() {
    if (isAll) return "Search pacman, Flathub and the AUR at once"
    if (isUpdates) return "Packages with a newer version available"
    if (isPacman) return "Search pacman packages"
    if (isFlatpak) return "Search Flatpak apps"
    return "Search AUR packages"
  }
  function tabPlaceholder() {
    if (isAll) return "Search everywhere… (gimp, spotify, libreoffice)"
    if (isUpdates) return "Updates available"
    if (isPacman) return "Search Arch package… (gimp, obs, audacity)"
    if (isFlatpak) return "Search a Flatpak app… (gimp, obs, libreoffice)"
    return "Search AUR package… (spotify, google-chrome, vscode-bin)"
  }

  // Only plain http(s) links may be handed to the external browser. AUR,
  // pacman and Flatpak metadata may contain arbitrary URLs, so everything is
  // allowlisted before opening.
  function isSafeWebUrl(u) { return Model.isSafeWebUrl(u) }

  function resolveThumb(remote, iconName) {
    if (remote !== "") {
      // Bare local paths (e.g. AppStream-catalog or icon-theme hits) must be
      // wrapped in a file:// URL — Image.source won't load a raw path,
      // matching how omarchy's own iconSource() resolves local files. Only
      // files under the plugin's verified catalog cache are accepted; remote
      // metadata must resolve to an http(s) URL, never an arbitrary file path.
      var s = String(remote)
      if (s.indexOf("https://") === 0 || s.indexOf("http://") === 0) return s
      if (s.indexOf("file://") === 0) {
        var p = s.substring(7)
        if (root.isInsideIconCache(p)) return s
        return ""
      }
      if (root.isInsideIconCache(s)) return Util.fileUrl(s)
      return ""
    }
    var local = iconName !== "" ? Quickshell.iconPath(iconName, true) : ""
    return local !== "" ? local : ""
  }

  // True only for paths genuinely inside the plugin's cache directory. A bare
  // startsWith() would also accept a sibling like ~/.cache/fossfetch-evil or
  // ~/.cache/fossfetchX, since those share the prefix — which would let remote
  // metadata point Image.source at an arbitrary file the user owns.
  function isInsideIconCache(path) { return Model.isInsideCache(path, root.iconCacheDir) }

  // How tall the results list may be. Grows with the number of matches but
  // never past what fits between the bar and the screen edge, so the card
  // can't overlap the bottom of the bar / off-screen. The ListView scrolls
  // internally when there are more matches than fit.
  // Fixed card height so exactly 3 result cards are on screen at a time.
  readonly property real cardHeight: Style.space(150)
  function fitResultsHeight(count) {
    if (count <= 0) return Style.space(120)
    var spacing = Style.space(8)
    // Show at most 3 on-screen rows; the ListView scrolls internally beyond that.
    var maxRows = 3
    var shownRows = Math.min(count, maxRows)
    var desired = shownRows * root.cardHeight + (shownRows - 1) * spacing + Style.space(8)
    var available = (panel && panel.availableCardHeight > 0)
      ? panel.availableCardHeight - Style.space(210)
      : Screen.desktopAvailableHeight > 0 ? Screen.desktopAvailableHeight - 300 : 620
    return Math.max(Style.space(120), Math.min(available, desired))
  }

  // Bullet-point detail lines shown below the card description: version,
  // repository, architecture and license. Excludes empty fields.
  // Compact labeled metadata lines (each array entry is one rendered line).
  // Stays to at most two short lines so it fits within the fixed card height:
  //   Version: 154.0-1 · Repo: extra
  //   Arch: x86_64 · License: MPL-2.0
  // Human-readable date for a card's "Updated" line. Accepts an AUR epoch,
  // a pacman "Fri 05 Sep 2026 …" build-date string, or an ISO-8601 date.
  //
  // Rendering is in LOCAL time, and the calendar components are taken from a
  // locally-constructed Date. pacman prints Build Date in the machine's own
  // timezone; reading those fields back as UTC shifted the date by a day for
  // every user west of Greenwich.
  function fmtUpdated(raw) { return Model.fmtUpdated(raw) }


  // Escape for a rich-text sink. Package and app names come from remote
  // metadata, and the card deliberately renders everything as PlainText so a
  // crafted name can never become markup. Highlighting the match is the one
  // place markup is genuinely useful, so the text is escaped FIRST and the only
  // tags in the result are the ones this function emits. The query itself is
  // never interpolated — only its length and offset are used.
  function escapeRich(s) { return Model.escapeRich(s) }

  function highlightName(name) {
    return Model.highlightName(name, root.query, root.matchColor)
  }

  // AUR trust signals. Shown as a single chip, worst-first: being flagged
  // out of date by the maintainer matters more than a low vote count, and a
  // crowd-maintained package with hundreds of votes needs no chip at all.
  function trustLabel(e) { return Model.trustLabel(e) }

  function trustColor(e) {
    if (!e) return Color.popups.text
    if (String(e.aurOutdated || "") !== "") return root.confirmColor
    var v = parseInt(e.aurVotes, 10)
    if (isNaN(v) || v <= 0 || v < 10) return root.confirmColor
    return Util.alpha(Color.popups.text, 0.55)
  }

  // The row's primary source. Drives the card's colour rail and its fallback
  // icon tint, so a list is scannable by colour before a single word is read.
  function rowSource(e) {
    if (!e) return "none"
    if (root.isPacman && e.pacmanPkg !== "") return "pacman"
    if (root.isAur && e.aurPkg !== "") return "aur"
    if (root.isFlatpak && e.flatpakPkg !== "") return "flatpak"
    if (root.isAll) {
      if (e.pacmanPkg !== "") return "pacman"
      if (e.aurPkg !== "") return "aur"
      if (e.flatpakPkg !== "") return "flatpak"
    }
    return "none"
  }

  function rowSourceColor(e) {
    var s = root.rowSource(e)
    if (s === "pacman") return root.pacmanColor
    if (s === "aur") return root.aurColor
    if (s === "flatpak") return root.flatpakColor
    return "transparent"
  }

  // One chip list for the whole card. The bottom row used to hold "Updated",
  // the download size and the trust signal side by side with the install
  // buttons, and "Updated" was always the one that lost - it got squeezed to
  // "Updated: 28 …".
  function cardChips(e) {
    var chips = root.detailPoints(e)
    // An update is stated with both versions — "1.0 → 2.0" — so the card never
    // claims an update without saying what it is an update TO. It sits ahead of
    // the static metadata because it is the one chip that changes what the card
    // is for.
    var upd = root.updateSpecFor(e)
    if (upd) chips.unshift({ label: "Update", value: root.updateLabel(upd) })
    var pop = root.popularityChip(e)
    if (pop) chips.push(pop)
    var when = root.fmtUpdated((e && e.updated) || "")
    if (when !== "") chips.push({ label: "Updated", value: when })
    return chips
  }

  // The AUR's Popularity is the fraction of AUR users running the package —
  // the closest thing the RPC offers to "is this actually used?". It is only
  // meaningful for AUR rows, and a package nobody installs reads better as an
  // honest "0.0%" than as no chip at all.
  function popularityChip(e) {
    if (!e || e.aurPkg === "") return null
    var raw = String(e.aurPopularity || "")
    if (raw === "") return null
    var pct = parseFloat(raw) * 100
    if (isNaN(pct) || pct < 0) return null
    return { label: "Popularity",
             value: pct >= 1 ? pct.toFixed(1) + "%" : pct.toFixed(2) + "%" }
  }

  function detailPoints(e) {
    var v = String((e && e.version) || "").trim()
    var r = String((e && e.repo) || "").trim()
    var a = String((e && e.arch) || "").trim()
    var l = String((e && e.licenses) || "").trim()

    var pts = []
    if (v !== "") pts.push({ label: "Version", value: v })
    if (r !== "") pts.push({ label: "Repo", value: r })
    if (a !== "") pts.push({ label: "Arch", value: a })
    if (l !== "") pts.push({ label: "License", value: l })
    return pts
  }

  // ------------------------------------------------------- details sheet
  // Why did this row show up? The ranker already knows the answer, so the sheet
  // explains the match in the same terms the ranking used rather than inventing
  // a second, possibly-contradictory explanation.
  function matchReason(name) {
    // pendingGroup is keyed by the exact package name (the same key the ranker
    // uses), so the group test must use the raw name, not the folded one.
    var inGroup = !!(root.pendingGroup && root.pendingGroup[String(name || "")] === true)
    return Model.matchReasonFor(name, root.query, inGroup)
  }


  function depNames(field) { return Model.depNames(field) }


  // The ordered fact list rendered by the sheet. Built as data (not markup)
  // so the view stays dumb and the labels/ordering live in one place.
  // How a long package list is rendered. A package like mpv has 67
  // dependencies; laid out as one wrapped string they take over the whole sheet
  // and push Conflicts/Required by off the bottom entirely, so the facts that
  // actually change a decision become unreachable.
  readonly property int sheetDepLimit: 8

  function joinDeps(field) {
    var names = root.depNames(field)
    if (names.length === 0) return ""
    var shown = names.slice(0, root.sheetDepLimit)
    var out = shown.join(", ")
    if (names.length > shown.length)
      out += "\n\n+" + (names.length - shown.length) + " more (open the AUR or `pacman -Qi` for the full list)"
    return out
  }

  function sheetFacts(r) {
    if (!r) return []
    var depList = root.depNames(r.dependsOn)
    var out = [
      { label: "Source",   value: r.pacmanPkg !== "" ? "Arch repos \u2014 " + (r.repo || "pacman")
                            : (r.aurPkg !== "" ? "AUR"
                            : (r.flatpakPkg !== ""
                               ? "Flathub \u2014 " + (r.branch !== "" ? r.branch : "stable")
                               : "")) },
      { label: "Version",  value: String(r.version || "") },
      { label: "Architecture", value: String(r.arch || "") },
      { label: "Branch",  value: String(r.branch || "") },
      { label: "Release", value: String(r.collection || "") },
      { label: "Licence",  value: String(r.licenses || "") },
      { label: "Groups",   value: String(r.groups || "") },
      { label: "Provides", value: String(r.provides || "") },
      { label: "Download size",  value: String(r.downloadSize || "") },
      { label: "Installed size", value: String(r.installedSize || "") },
      { label: "Depends on (" + depList.length + ")", value: root.joinDeps(r.dependsOn) },
      { label: "Optional deps",  value: root.joinDeps(r.optionalDeps) },
      { label: "Conflicts with", value: root.joinDeps(r.conflictsWith) }
    ]
    // When a package is already installed and the offered version differs,
    // show the installed version too. This is the "what do I have vs what's
    // available" line that makes the update chip above verifiable at a glance.
var upd = root.updateSpecFor(r)
    if (upd) {
      out.splice(1, 0,
        { label: "Installed", value: upd.from },
        { label: "Update",    value: root.updateLabel(upd) })
    }
    // Only for an installed pacman/AUR row, and only once `pacman -Qi` has
    // answered \u2014 this is the warning that removal would break another package.
    var req = root.depNames(r.requiredBy)
    if (req.length > 0) {
      out.push({ label: "Required by (" + req.length + ")",
                 value: req.join(", ")
                       + "\n\nRemoving this will break the packages above." })
    }
    return out
  }


  property var detailRow: null

  function openDetails(row) {
    if (!row) return
    root.detailRow = row
    detailsSheet.open = true
    root.fetchDepGraph(row)
    // Pacman rows are filled by the shared `pacman -Si` batch. AUR and Flathub
    // rows get NOTHING from it -- that batch only collects rows carrying a
    // pacmanPkg -- so their sheets were an almost-empty list of headings until
    // these two were added. Both are on-demand, one request, for the single
    // package the user opened.
    if (row.pacmanPkg === "") {
      if (row.aurPkg !== "") root.fetchAurInfo(row.aurPkg)
      if (row.flatpakPkg !== "") root.fetchFlatpakInfo(row.flatpakPkg)
    }
  }

  // Open the details sheet for whichever row the keyboard cursor is on. The
  // search field owns focus, so a printable key cannot be used — it would type
  // into the query. F2 is the standard "properties/details" key and never
  // reaches the field as text. Enter already installs; this is the way to look
  // BEFORE committing.
  function openDetailsCursor() {
    if (filteredModel.count === 0) return
    var idx = resultsList.currentIndex
    if (idx < 0 || idx >= filteredModel.count) idx = 0
    root.openDetails(filteredModel.get(idx))
  }

  // ---- AUR: the RPC's search interface does not return Depends/Conflicts/
  // Provides/Groups/License at all (only NameSearch does), so the full record
  // is fetched here, once, when the sheet opens.
  function fetchAurInfo(pkg) {
    if (pkg === "") return
    root.aurInfoTarget = pkg
    aurInfoProc.command = ["python3", root.aurSearchScript, "info", pkg]
    aurInfoProc.running = false
    aurInfoProc.running = true
  }

  Process {
    id: aurInfoProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAurInfo(text || "")
    }
  }

  function applyAurInfo(text) {
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf("I|") !== 0) continue
      var parts = lines[i].split("|")
      if (parts.length < 3) continue
      var field = parts[1]
      var value = parts.slice(2).join("|")
      if (value === "") continue
      var idx = root.rowIndexForPkg(root.aurInfoTarget)
      if (idx < 0) continue
      filteredModel.setProperty(idx, field, value)
    }
  }

  property string aurInfoTarget: ""

  // ---- Flathub: pacman knows nothing about a flatpak app id.
  function fetchFlatpakInfo(id) {
    if (id === "") return
    root.flatpakInfoTarget = id
    flatpakInfoProc.command = ["flatpak", "remote-info", "flathub", id]
    flatpakInfoProc.running = false
    flatpakInfoProc.running = true
  }

  Process {
    id: flatpakInfoProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyFlatpakInfo(text || "")
    }
  }

  function applyFlatpakInfo(text) {
    var s = String(text || "")
    var field = function(label) {
      var m = s.match(new RegExp("^\\s*" + label + ":\\s*(.+)$", "mi"))
      return m ? m[1].trim() : ""
    }
    var idx = root.rowIndexForFlatpak(root.flatpakInfoTarget)
    if (idx < 0) return
    var pairs = [
      ["version", field("Version")],
      ["arch", field("Arch")],
      ["licenses", field("License")],
      ["downloadSize", field("Download Size")],
      ["installedSize", field("Installed Size")],
      ["branch", field("Branch")],
      ["collection", field("Collection")]
    ]
    for (var i = 0; i < pairs.length; i++) {
      if (pairs[i][1] !== "") filteredModel.setProperty(idx, pairs[i][0], pairs[i][1])
    }
  }

  property string flatpakInfoTarget: ""

  function closeDetails() {
    detailsSheet.open = false
    root.detailRow = null
  }

  // `Required By` — which other installed packages depend on this one — is the
  // field that decides whether removing it is safe, and it only exists in
  // `pacman -Qi` (the installed DB), never in the -Si batch used for the card
  // grid. It is fetched lazily, for installed rows only, when the sheet opens:
  // one cheap call that answers "will removing this break something?".
  function fetchDepGraph(row) {
    var pkg = row && row.pacmanPkg ? row.pacmanPkg : (row && row.aurPkg ? row.aurPkg : "")
    if (pkg === "" || root.isPacmanInstalled(pkg) !== true) return
    if (root.rowIndexForPkg(pkg) < 0) return
    qiProc.command = ["pacman", "-Qi", pkg]
    qiProc.running = false
    qiProc.running = true
  }

  Process {
    id: qiProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDepGraph(text || "")
    }
  }

  function applyDepGraph(text) {
    var s = String(text || "")
    var name = (s.match(/^Name\s*:\s*(.+)$/m) || [])[1]
    if (!name) return
    var idx = root.rowIndexForPkg(name.trim())
    if (idx < 0) return
    var field = function(label) {
      var m = s.match(new RegExp("^" + label + "\\s*:\\s*(.+)$", "mi"))
      return m ? m[1].trim() : ""
    }
    var rb = field("Required By")
    if (rb !== "") filteredModel.setProperty(idx, "requiredBy", rb)
  }

  // ------------------------------------------------------- result building
  ListModel { id: filteredModel }

  // key -> row index, maintained by addRow()/reindexModel(). These replace
  // linear scans of the model that ran per row from four different
  // onStreamFinished handlers — O(n^2) work that only stayed cheap because the
  // row cap was 60.
  property var pkgIndex: ({})
  property var flatpakIndex: ({})
  property int searchSeq: 0

  // rebuild the visible list for the active tab + query.
  // The model is populated purely by live search results (pacman -Ss /
  // flatpak search); there is no curated app list. Every appended row carries
  // the FULL role set (including empty version, repo, arch, licenses, _pkg) so
  // ListModel knows about those roles from the start — otherwise
  // `filteredModel.set()` later can't add new roles and any live-scraped
  // metadata would be silently dropped.
  function buildModel() {
    filteredModel.clear()
    root.pkgIndex = ({})
    root.flatpakIndex = ({})
    root.hiddenInstalled = 0
    root.orderSeq = 0
    root.availableSortModes = root.sortModes
    resultsList.currentIndex = -1
  }

  // How many results the hide-installed filter is currently suppressing. Counted
  // rather than inferred so the empty state can say "12 already installed" — a
  // bare "No packages found" when the search actually matched plenty would read
  // as the search having failed.
  property int hiddenInstalled: 0

  // Identity of a row, independent of its position. Used to put the keyboard
  // cursor back on the SAME package after a re-sort: without this, changing the
  // sort would silently move the selection and Enter would then act on whatever
  // happened to land at the old index.
  function rowKey(r) {
    if (!r) return ""
    return String(r._pkg || "") + "|" + String(r.flatpakPkg || "")
      + "|" + String(r.pacmanPkg || "") + "|" + String(r.name || "")
  }

  // Snapshot a model row into a PLAIN object.
  //
  // QQmlListModel.get() hands back an object tied to the live row. Clearing the
  // model therefore empties every one of those objects, so re-appending them
  // after a re-sort produced blank cards — no name, no chips, no icon. Copying
  // the roles out first is what makes the rebuild survive.
  //
  // Enumerated rather than written out role by role, so a role added to addRow
  // later is carried through automatically instead of being silently dropped
  // here (which would reintroduce exactly the missing-role failure that
  // addRow's defaults guard against).
  function copyRow(r) {
    var out = {}
    for (var k in r) {
      var v = r[k]
      if (typeof v === "function") continue
      out[k] = v
    }
    return out
  }

  // Hide-installed applies to search results only. Every row on the Updates tab
  // IS installed by definition, so the filter there would empty the tab the user
  // opened precisely to see what needed updating.
  readonly property bool hideInstalledActive: root.hideInstalled && !root.isUpdates

  // Reorder and re-gate the rows already in the model.
  //
  // Rebuilding the ListModel in place is the only way to reorder it: QQmlListModel
  // has no move operation. That is safe here because every asynchronous
  // write-back (metadata, icons, licences, AUR/Flathub details) re-resolves its
  // row by key at apply time rather than holding onto a captured index, so
  // reindexModel() below keeps those writes landing on the right package.
  //
  // Nothing is touched when the new order matches the old one — a rebuild
  // destroys and recreates every delegate, and doing that on a no-op click would
  // flicker the list and reset scroll position for no reason.
  // Recompute which sorts this result set can offer. Separate from applyView()
  // because the data that unlocks a mode arrives ASYNCHRONOUSLY: build dates
  // come from the batched `pacman -Si` pass, AUR popularity from the RPC. A
  // cycle computed at search time therefore omits "Updated" for as long as the
  // cards are still showing no date, and the mode only appears after whatever
  // unrelated action happens to re-run the sort.
  function refreshSortModes() {
    root.availableSortModes = root.computeSortModes()
  }

  // resetView: true when the USER changed the view (a new sort, or the filter).
  // A new sort means a new top — show the first card of the new order rather
  // than leaving the viewport wherever the previous order happened to leave it,
  // which lands the user on an unrelated set of rows halfway down the list.
  //
  // False when the list is merely settling: backends append asynchronously, so
  // applyView() also runs each time a slow source lands. Re-selecting the top
  // card on every one of those would yank the user away from wherever they had
  // scrolled to while waiting, so those calls keep their place.
  function applyView(resetView) {
    root.refreshSortModes()
    if (filteredModel.count === 0) return
    var rows = []
    var before = []
    var hidden = 0
    for (var i = 0; i < filteredModel.count; i++) {
      var r = filteredModel.get(i)
      if (!Model.passesFilter(r, { hideInstalled: root.hideInstalledActive })) { hidden++; continue }
      // Snapshot, not the live row object — see copyRow().
      rows.push(root.copyRow(r))
      before.push(root.rowKey(r))
    }
    // Counted even when nothing moved, so turning the filter back off has an
    // accurate number to restore rather than a stale one.
    root.hiddenInstalled = hidden
    var after = Model.sortRows(rows, root.effectiveSortMode())
    var moved = after.length !== before.length
    if (!moved) {
      for (var j = 0; j < after.length; j++) {
        if (root.rowKey(after[j]) !== before[j]) { moved = true; break }
      }
    }
    if (!moved) return

    // Keep the highlighted package highlighted across the rebuild.
    var prev = resultsList.currentIndex
    var keepKey = ""
    if (prev >= 0 && prev < filteredModel.count) keepKey = root.rowKey(filteredModel.get(prev))
    // Must be read before the clear for the same reason as the rows above.

    filteredModel.clear()
    for (var k = 0; k < after.length; k++) filteredModel.append(after[k])
    // Row positions changed, so every key -> index map has to be rebuilt or
    // later metadata writes land on whichever package now sits at the old index.
    root.reindexModel()
    // Keys survive the rebuild, but rows that no longer survive it must not:
    // a selection carried through a filter would queue actions on packages
    // the user cannot see.
    root.pruneSelection()

    if (resetView) {
      resultsList.currentIndex = after.length > 0 ? 0 : -1
      if (after.length > 0) resultsList.positionViewAtBeginning()
      return
    }

    // Settling, not a deliberate change: keep the same package highlighted
    // wherever the reordering put it, so rows arriving from a slow backend do
    // not move the target out from under the cursor.
    var at = -1
    if (keepKey !== "") {
      for (var m = 0; m < after.length; m++) {
        if (root.rowKey(after[m]) === keepKey) { at = m; break }
      }
    }
    if (at >= 0) {
      resultsList.currentIndex = at
      resultsList.positionViewAtIndex(at, ListView.Contain)
    } else {
      resultsList.currentIndex = after.length > 0 ? 0 : -1
      if (after.length > 0) resultsList.positionViewAtBeginning()
    }
  }

  function rebuildResults() {
    var q = root.query.toLowerCase().trim()
    buildModel()
    // The Updates tab is not a search — it is the background scan's result set.
    // Repopulating it from updateRows keeps it live as the scan refreshes, and
    // ignores the query entirely.
    if (root.isUpdates) {
      var rows = root.updateRows
      for (var i = 0; i < rows.length; i++) addRow(rows[i])
      resultsList.currentIndex = rows.length > 0 ? 0 : -1
      return
    }
    if (q === "") return
    launchLiveSearch(q)
  }

  // -------------------------------------------------------- live scraping
  property bool pacmanDone: false
  property bool flatpakDone: false

  // ---------------------------------------------- per-tab backend status
  // Set by the STATUS|frame scanning in each backend's result handler: a
  // successful-but-empty search stays "", a failed lookup carries a short
  // reason. Lets the empty state say "lookup failed" instead of implying
  // there are simply no matching packages.
  property var pacmanError: ""
  property string flatpakError: ""
  property string aurError: ""

  // --------------------------------------------------- installed packages
  // One `pacman -Qq` and one `flatpak list` answer "is this already on the
  // machine?" for every row. Without it the panel happily offers to install
  // packages that are already installed, and re-installs are easy to trigger by
  // accident. Refreshed at most once a minute — both commands are cheap but not
  // free, and they sit on the search path.
  property var installedPacman: ({})
  property var installedFlatpak: ({})
  // name -> installed version, for the update check. `pacman -Q` prints
  // "name version" on one line; flatpak supplies its own version column. Both
  // are compared against the card's available version to decide whether an
  // update is actually pending (see Model.needsUpdate).
  property var installedVersions: ({})
  property double installedAt: 0

  // ---- updates tab ----------------------------------------------------------
  // The count is the single number the toolbar badge, the tab's visibility and
  // the Updates list all read, so they can never disagree. It is filled by the
  // background scan (update_scan.sh), which reports what each source OFFERS;
  // the panel still confirms against the installed snapshot before offering an
  // update, so a stale scan can never invent one.
  property int updateCount: 0
  property var updateRows: ([])
  property double updatesAt: 0

  function refreshUpdates() {
    // A scan talks to three package managers, two of which may reach the
    // network (AUR RPC / Flathub). Never let two overlap.
    if (updateProc.running) return
    root.updatesAt = Date.now()
    updateProc.running = true
  }

  // One subprocess across all three sources. The helper is passed as $1 and is
  // never interpolated into the script text. Names are read, never executed.
  Process {
    id: updateProc
    running: false
    command: ["sh", root.updateScanScript, root.aurHelper, "fossfetch-updates"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyUpdateScan(text || "")
    }
  }

  // A quiet periodic re-scan so the bar badge stays honest while the panel sits
  // closed for hours. Five minutes is frequent enough that "you have updates"
  // is never stale for long, and rare enough not to be a background daemon.
  Timer {
    id: updateScanTimer
    interval: 300000
    repeat: true
    // Start one shortly after launch so the badge is populated on the first
    // bar render, rather than being blank for five minutes. The panel loads at
    // shell startup, so this is the badge's first (and only) eager scan.
    running: true
    triggeredOnStart: false
    onTriggered: root.refreshUpdates()
  }

  Timer {
    id: firstUpdateScan
    interval: 1500
    repeat: false
    running: true
    onTriggered: {
      // Let the shell finish starting before asking three package managers
      // questions; running it during login competes with everything else.
      if (root.updateCount === 0) root.refreshUpdates()
    }
  }

  // Parse the "UPD|kind|name|<available>" lines into row objects the card can
  // render. Each row carries the package key for its source so the card's
  // existing pendingUpdate() logic recognises it and offers the Update button.
  // Keyed by package name rather than carried as a model role: the row already
  // identifies itself by whichever source key it has, so this needs no extra
  // delegate property and no new ListModel role.
  property var updateKeys: ({})

  function isUpdateRow(e) {
    if (!e) return false
    var k = e.pacmanPkg !== "" ? e.pacmanPkg
        : (e.aurPkg !== "" ? e.aurPkg : e.flatpakPkg)
    return k !== "" && root.updateKeys[k] === true
  }

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
    // is what happens in the first seconds after a shell start; the old code
    // turned that into a confident empty result, so the badge and the Updates
    // tab vanished until the next five-minute tick even though updates were
    // waiting. Keep whatever we already knew and come back shortly.
    if (degraded && rows.length === 0) {
      root.updatesDegraded = true
      updateRetry.start()
      return
    }
    root.updatesDegraded = false
    updateRetry.stop()
    root.updateRows = rows
    root.updateKeys = keys
    root.updateCount = rows.length
    // If the user is looking at the Updates tab, it is now stale — repopulate.
    // If everything got updated out from under them, fall back to Pacman rather
    // than leaving them on an empty tab.
    if (root.updateCount === 0 && root.isUpdates) root.switchTab(0)
    else if (root.isUpdates) root.rebuildResults()
  }

  function isPacmanInstalled(pkg) {
    return !!pkg && pkg !== "" && root.installedPacman[pkg] === true
  }
  // A helper-managed AUR package is a real pacman package — `pacman -Qq` lists
  // it — so it is answered from the pacman snapshot, not a separate AUR query.
  function isAurInstalled(pkg) {
    return !!pkg && pkg !== "" && root.installedPacman[pkg] === true
  }
  function isFlatpakInstalled(id) {
    return !!id && id !== "" && root.installedFlatpak[id] === true
  }
  function installedVersion(pkg) {
    return (pkg && root.installedVersions[pkg]) ? String(root.installedVersions[pkg]) : ""
  }

  function refreshInstalled(force) {
    if (!force && Date.now() - root.installedAt < 60000) return
    root.installedAt = Date.now()
    installedProc.running = false
    installedProc.running = true
  }

  function applyInstalled(text) {
    var pkgs = {}
    var flats = {}
    var vers = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("|")
      if (parts.length < 2) continue
      // After the P|/F| tag the payload is "<name><sep><version>", where the
      // separator is a SPACE for `pacman -Q` and a TAB for flatpak's column
      // output. Package names never contain whitespace, so the first whitespace
      // is always the name/version boundary — splitting on "|" here would leave
      // the version glued to the name and silently break every lookup.
      var rest = parts.slice(1).join("|")
      var sp = rest.search(/\s/)
      var name = sp === -1 ? rest : rest.slice(0, sp)
      var ver = sp === -1 ? "" : rest.slice(sp + 1).trim()
      name = name.trim()
      if (name === "") continue
      if (parts[0] === "P") pkgs[name] = true
      else if (parts[0] === "F") flats[name] = true
      if (ver !== "") vers[name] = ver
    }
    root.installedPacman = pkgs
    root.installedFlatpak = flats
    root.installedVersions = vers
    applyInstalledToRows()
    // The installed snapshot is what "hide installed" filters on, and it often
    // lands AFTER the search rows were appended — every row was admitted while
    // it still looked uninstalled. Re-gate now that the answer is known, or the
    // packages you asked to hide stay on screen for the rest of the session.
    if (root.hideInstalledActive) root.applyView()
  }

  function applyInstalledToRows() {
    for (var i = 0; i < filteredModel.count; i++) {
      var r = filteredModel.get(i)
      if (!r) continue
      var p = root.isPacmanInstalled(r.pacmanPkg) ? "1" : ""
      var f = root.isFlatpakInstalled(r.flatpakPkg) ? "1" : ""
      var a = root.isAurInstalled(r.aurPkg) ? "1" : ""
      if (r.installedPacman !== p) filteredModel.setProperty(i, "installedPacman", p)
      if (r.installedAur !== a) filteredModel.setProperty(i, "installedAur", a)
      if (r.installedFlatpak !== f) filteredModel.setProperty(i, "installedFlatpak", f)
    }
  }

  // One subprocess for both package managers. Names are read, never executed —
  // they only become keys in the lookup objects below. `pacman -Q` prints
  // "name version" per line (as opposed to -Qq's bare names) and flatpak is
  // asked for its version column, so the same single call answers both
  // "is it installed?" and "which version is installed?" for the update check.
  Process {
    id: installedProc
    running: false
    command: ["sh", "-c",
      "pacman -Q 2>/dev/null | sed 's/^/P|/'\n"
      + "flatpak list --app --columns=application,version 2>/dev/null | sed 's/^/F|/'",
      "fossfetch-installed"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyInstalled(text || "")
    }
  }

  function tabError() {
    if (root.isPacman) return root.pacmanError
    if (root.isFlatpak) return root.flatpakError
    if (root.isAur) return root.aurError
    // In "All" only report a failure when EVERY source failed; one working
    // source is a successful search, and an error banner over real results
    // would be a lie.
    if (root.isAll) {
      var failed = [root.pacmanError, root.flatpakError, root.aurError]
        .filter(function (e) { return e !== "" })
      return failed.length === 3 ? failed[0] : ""
    }
    return ""
  }

  // Pull the trailing "STATUS|ok|..." / "STATUS|error|..." frame out of a
  // backend's stdout and return the detail ("" for ok, or the failure reason).
  // The frame is always the LAST line, so only the tail is considered: scanning
  // every line for a "STATUS|" prefix would let a package description or
  // result row that happens to start with that text masquerade as a frame.
  function statusDetail(lines) { return Model.statusDetail(lines) }

  // Best-effort canonical Flathub icon URL for a flatpak app id.
  function flathubIcon(id) {
    return "https://dl.flathub.org/repo/appstream/x86_64/icons/128x128/" + id + ".png"
  }

  // Package names that the current query's AppStream category mapping returned
  // (populated from the "G|pkg1|pkg2|..." marker line in the group search
  // output). These are boosted in the result ranking so a category query like
  // "browser" surfaces every browser near the top.
  property var pendingGroup: ({})

  function launchLiveSearch(q) {
    // NOT recorded here. This runs on every debounced keystroke, so recording
    // from it filed each intermediate prefix as its own recent: typing
    // "vivaldi" left five entries behind (via, vial, vival, vivald, vivaldi)
    // for what the user considers one search. Recording waits for the typing to
    // settle instead — see noteSearch()/flushRecent().
    var seq = ++searchSeq
    root.pendingGroup = ({})
    root.pacmanError = ""
    root.flatpakError = ""
    root.aurError = ""
    if (isAll) {
      // Fan out. Each backend keeps its own process and sequence stamp, so a
      // slow source cannot block or corrupt a fast one, and each appends into
      // the shared model as it lands.
      if (root.aurEnabled || root.flatpakEnabled) {
        pacmanProc.mySeq = seq
        pacmanProc.running = false
        pacmanProc.command = ["sh", root.pacmanBackendScript, q, root.iconCacheDir, root.appstreamGroupsScript]
        pacmanProc.running = true
      }
      if (root.flatpakEnabled) {
        flatpakProc.mySeq = seq
        flatpakProc.running = false
        flatpakProc.command = ["sh", root.flatpakBackendScript, q, root.iconCacheDir, root.flathubGroupsScript]
        flatpakProc.running = true
      }
      if (root.aurEnabled) {
        aurProc.mySeq = seq
        aurProc.running = false
        aurProc.command = ["python3", root.aurSearchScript, q]
        aurProc.running = true
      }
      return
    }
    if (isPacman) {
      pacmanProc.mySeq = seq
      pacmanProc.running = false
      // One shot, in the bundled backend script (not an inline sh string, so
      // it is directly regression-testable): resolve the category -> packages
      // mapping for <q> as a "G|pkg1|pkg2|..." marker line, then the normal
      // `pacman -Ss` output, then a single trailing STATUS|frame distinguishing
      // "ran, no matches" from "pacman missing/broken". pkg names only come
      // from the local groups index (never from user input), and the query is
      // passed as argv, never interpolated into shell text.
      pacmanProc.command = ["sh", root.pacmanBackendScript, q, root.iconCacheDir, root.appstreamGroupsScript]
      pacmanProc.running = true
    } else if (isFlatpak) {
      flatpakProc.mySeq = seq
      flatpakProc.running = false
      // Group rows (name, desc, appid, version, released) come first, tagged
      // G|; then normal search output; then one trailing STATUS|frame. The
      // frame is what keeps a legitimate miss ("no apps found") from being
      // reported as a failed lookup — `flatpak search` exits 1 for both.
      flatpakProc.command = ["sh", root.flatpakBackendScript, q, root.iconCacheDir, root.flathubGroupsScript]
      flatpakProc.running = true
    } else {
      aurProc.mySeq = seq
      aurProc.running = false
      // AUR has no AppStream categories, so there are no group rows ("G|"
      // marker) — the RPC `name-desc` search already matches natural phrases
      // against descriptions. One network call via python3 stdlib.
      aurProc.command = ["python3", root.aurSearchScript, q]
      aurProc.running = true
    }
  }

  // Single entry point for result rows. Every row MUST carry the same role set:
  // ListModel cannot introduce a role after the first append, so a row appended
  // without (say) installedPacman would turn every later setProperty() on that
  // role into a silent no-op and the Installed chip would never appear for that
  // tab. Defaults are filled in here rather than at each of the three call
  // sites, and the installed flags are stamped from the current snapshot so a
  // row is correct the instant it appears.
  function addRow(obj) {
    if (!obj) return
    var row = obj
    var strDefaults = {
      name: "", description: "", rating: "", website: "", license: "",
      category: "", repo: "", version: "", arch: "", licenses: "", updated: "",
      thumbnail: "", iconName: "", pacmanPkg: "", aurPkg: "", flatpakPkg: "", _pkg: "",
      aurVotes: "", aurMaintainer: "", aurOutdated: "", aurPopularity: "", downloadSize: "",
      installedSize: "", dependsOn: "", optionalDeps: "", requiredBy: "",
      conflictsWith: "", provides: "", groups: "", packager: "",
      branch: "", collection: ""
    }
    // Insertion order. A NUMBER, so the role has one consistent type from the
    // very first append — ListModel cannot change a role's type later, and a
    // row without it would silently break every sort.
    row._order = 0
    for (var key in strDefaults) {
      if (row[key] === undefined || row[key] === null) row[key] = strDefaults[key]
    }
    row.installedPacman = root.isPacmanInstalled(row.pacmanPkg) ? "1" : ""
    row.installedAur = root.isAurInstalled(row.aurPkg) ? "1" : ""
    row.installedFlatpak = root.isFlatpakInstalled(row.flatpakPkg) ? "1" : ""
    // Gate at the door rather than filtering the finished list. Results arrive
    // one batch at a time, so a filter applied after the fact would show a
    // package and then yank the card out from under the user mid-search.
    if (!Model.passesFilter(row, { hideInstalled: root.hideInstalledActive })) {
      root.hiddenInstalled++
      return
    }
    row._order = root.orderSeq++
    filteredModel.append(row)
    var at = filteredModel.count - 1
    // First writer wins, matching the previous linear-scan behaviour.
    var pk = row._pkg !== "" ? row._pkg : row.pacmanPkg
    if (pk !== "" && root.pkgIndex[pk] === undefined) root.pkgIndex[pk] = at
    if (row.flatpakPkg !== "" && root.flatpakIndex[row.flatpakPkg] === undefined)
      root.flatpakIndex[row.flatpakPkg] = at
  }

  // parses `pacman -Ss <q>`: alternating "repo/name version" header lines and
  // indented description lines, so each result carries its real description.
  function onPacmanResults(text) {
    if (pacmanProc.mySeq !== searchSeq) return
    // Belt and braces: the Updates tab is the scan's result set, not a
    // search. A late row must never land in it, whatever the sequence says.
    if (root.isUpdates) return
    var q = root.query.toLowerCase().trim()
    if (q === "") return
    var lines = String(text || "").split("\n")
    // STATUS|frame: distinguish "ran, no matches" from a failed backend.
    root.pacmanError = root.statusDetail(lines)

    // Parse every "repo/name version [arch]" header + description pair into a
    // list, then append each as a new live row (deduped against rows already
    // in the model).
    var parsed = []
    var pendingName = ""
    var pendingDesc = ""
    var pendingRepo = ""
    var pendingVersion = ""
    var pendingArch = ""
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      // "G|pkg1|pkg2|..." marker line: category members for this query.
      if (line.indexOf("G|") === 0) {
        var members = line.substring(2).split("|")
        for (var m = 0; m < members.length; m++) {
          var nm = members[m].trim()
          if (nm) root.pendingGroup[nm] = true
        }
        continue
      }
      // Indented line: the description of the current package.
      if (line.charAt(0) === " " || line.charAt(0) === "\t") {
        if (pendingName !== "" && pendingDesc === "") pendingDesc = line.trim()
        continue
      }
      // Header line: "repo/name version [arch] ..." — commit the previous.
      if (pendingName !== "") {
        parsed.push({ name: pendingName, desc: pendingDesc, repo: pendingRepo, version: pendingVersion, arch: pendingArch })
        pendingName = ""
        pendingDesc = ""
        pendingRepo = ""
        pendingVersion = ""
        pendingArch = ""
      }
      var slash = line.indexOf("/")
      if (slash <= 0) continue
      pendingRepo = line.substring(0, slash).trim()
      var rest = line.substring(slash + 1)
      var sp = rest.indexOf(" ")
      pendingName = (sp > 0 ? rest.substring(0, sp) : rest).trim()
      if (sp > 0) {
        pendingVersion = rest.substring(sp + 1).trim()
        // Arch repos may add per-arch build tags (e.g. "... [any]" /
        // "... [i686]"); those are real architecture markers. Anything else in
        // brackets ([installed], [firefox-addons], ...) is a version flag and
        // must stay in the version string.
        var archMatch = pendingVersion.match(/\[([^\]]+)\]\s*$/)
        if (archMatch) {
          var archTag = archMatch[1]
          if (archTag === "any" || archTag === "x86_64" || archTag === "i686"
              || archTag === "aarch64" || archTag === "arm" || archTag === "armv6h"
              || archTag === "armv7h" || archTag === "pentium4") {
            pendingArch = archTag
            pendingVersion = pendingVersion.substring(0, archMatch.index).trim()
          }
        }
      }
    }
    if (pendingName !== "") {
      parsed.push({ name: pendingName, desc: pendingDesc, repo: pendingRepo, version: pendingVersion, arch: pendingArch })
    }

    // Rank results so exact / prefix name matches surface before description
    // only hits (firefox sorts above browserpass-firefox, curl-impersonate, ...).
    // AppStream category members (pendingGroup) get boosted to rank 1 so a
    // query like "browser" surfaces every browser, above plain prefix/substring
    // matches but still below an exact package-name hit.
    parsed.sort(function(a, b) {
      var ra = root.pacmanRank(a.name, q)
      var rb = root.pacmanRank(b.name, q)
      if (root.pendingGroup[a.name] && ra > 1) ra = 1
      if (root.pendingGroup[b.name] && rb > 1) rb = 1
      if (ra !== rb) return ra - rb
      return a.name.localeCompare(b.name)
    })

    // Append every parsed package as a live row, skipping any that are already
    // present (guards against duplicate pacman -Ss lines for the same package).
    var added = 0
    for (var j = 0; j < parsed.length && added < 60; j++) {
      var info = parsed[j]
      if (root.modelRowIndex(info.name) >= 0) continue
      root.addRow({
        name: info.name, description: info.desc,
        rating: "", website: "", license: "", category: "Pacman",
        repo: info.repo, version: info.version, arch: info.arch, licenses: "",
        updated: "",
        thumbnail: "", iconName: "", pacmanPkg: info.name, aurPkg: "", flatpakPkg: "",
        _pkg: info.name
      })
      added++
    }
    // Enrich the newly-added rows in a few batched subprocesses (fixes slow
    // per-row spawning): full metadata + website + licenses via one `pacman
    // -Si`, icons via one batched local lookup + one flathub search.
    enqueueMeta()
    requestEnrich()
    refreshInstalled(false)
    // Rows arrive in the backend's relevance order; re-sort for the active
    // mode now that this source has finished landing.
    root.applyView()
  }

  // Rank a result by how well its package name matches the query:
  //   exact (0) > prefix (1) > substring (2) > base-name (3)
  //   > fuzzy subsequence (4) > description only (5)
  // The fuzzy tier is what lets "librofice" find "libreoffice", "obsstudio"
  // find "obs-studio" and "kdenl" find "kdenlive": the query's characters must
  // appear in the name in order, not necessarily adjacently. It is about
  // abbreviations and dropped characters, not transpositions — "froffox" still
  // misses "firefox", because the query is longer than any window that ordering
  // alone can recover.
  function pacmanRank(name, q) { return Model.rank(String(name).toLowerCase(), String(q).toLowerCase()) }

  function isFuzzySubsequence(q, n) { return Model.fuzzySubsequence(q, n) }

  // Index of an existing model row whose pacman package id matches `name`, or
  // -1 if it isn't shown yet. Backed by pkgIndex rather than a linear scan.
  function modelRowIndex(name) {
    var i = root.pkgIndex[name]
    return i === undefined ? -1 : i
  }

  function onFlatpakResults(text) {
    if (flatpakProc.mySeq !== searchSeq) return
    // Belt and braces: the Updates tab is the scan's result set, not a
    // search. A late row must never land in it, whatever the sequence says.
    if (root.isUpdates) return
    var q = root.query.toLowerCase().trim()
    if (q === "") return
    var lines = String(text || "").split("\n")
    // STATUS|frame: distinguish "ran, no matches" from a failed search.
    root.flatpakError = root.statusDetail(lines)
    var added = 0
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      // Group rows carry a "G|" tag (same tab layout as flatpak search output).
      if (line.indexOf("G|") === 0) line = line.substring(2)
      var parts = line.split("\t")
      if (parts.length < 3) continue
      var appId = parts[2].trim()
      if (!appId) continue
      // Skip SDK/Platform/runtime extension bundles — not standalone apps.
      if (appId.indexOf(".Sdk.") !== -1 || appId.indexOf(".Platform.") !== -1
          || appId.indexOf("Extension") !== -1 || appId.indexOf(".Locale") !== -1) continue
      if (modelHasFlatpak(appId)) continue
      if (added >= 60) break
      root.addRow({
        name: parts[0].trim(),
        description: (parts[1] || "").trim(),
        rating: "", website: "https://flathub.org/apps/" + appId, license: "", category: "Flatpak",
        repo: "flathub", version: (parts[3] || "").trim(), arch: "", licenses: "",
        updated: parts.length > 4 ? parts[4].trim() : "",
        thumbnail: flathubIcon(appId), iconName: "", pacmanPkg: "", aurPkg: "", flatpakPkg: appId,
        _pkg: appId
      })
      added++
    }
    licenseDebounce.restart()
    requestEnrich()
    refreshInstalled(false)
    root.applyView()
  }

  // True if a live row with this flatpak app id is already in the model.
  // Guards against duplicate search-result lines for the same app (multiple
  // remotes/arches/versions).
  function modelHasFlatpak(id) {
    return root.flatpakIndex[id] !== undefined
  }

  // Parse `aur_search.py` output: one row per candidate, tab-separated
  // name\tdesc\tversion\twebsite\tlicense\tpackagebase\tvotes\tlastmodified.
  // Ranked by the same name-match scoring as the other tabs so an
  // exact/prefix package-name hit sorts above description-only matches.
  function onAurResults(text) {
    if (aurProc.mySeq !== searchSeq) return
    // Belt and braces: the Updates tab is the scan's result set, not a
    // search. A late row must never land in it, whatever the sequence says.
    if (root.isUpdates) return
    var q = root.query.toLowerCase().trim()
    if (q === "") return
    var lines = String(text || "").split("\n")
    // STATUS|frame: distinguish "ran, no matches" from a failed AUR lookup.
    root.aurError = root.statusDetail(lines)
    var parsed = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("\t")
      if (parts.length < 6) continue
      var name = parts[0].trim()
      if (!name) continue
      parsed.push({
        name: name,
        desc: parts[1].trim(),
        version: parts[2].trim(),
        website: parts[3].trim(),
        license: parts[4].trim(),
        pkgbase: parts[5].trim(),
        votes: parts[6] !== undefined ? parts[6].trim() : "",
        lastModified: parts[7] !== undefined ? parts[7].trim() : "",
        maintainer: parts[8] !== undefined ? parts[8].trim() : "",
        outOfDate: parts[9] !== undefined ? parts[9].trim() : "",
        popularity: parts[10] !== undefined ? parts[10].trim() : ""
      })
    }
    parsed.sort(function(a, b) {
      var ra = root.pacmanRank(a.name, q)
      var rb = root.pacmanRank(b.name, q)
      if (ra !== rb) return ra - rb
      // Tie-break secondary matches by votes so popular AUR packages float up.
      var va = parseInt(a.votes, 10) || 0
      var vb = parseInt(b.votes, 10) || 0
      if (vb !== va) return vb - va
      return a.name.localeCompare(b.name)
    })

    var added = 0
    for (var j = 0; j < parsed.length && added < 60; j++) {
      var info = parsed[j]
      if (root.modelRowIndex(info.name) >= 0) continue
      root.addRow({
        name: info.name, description: info.desc,
        rating: "", website: info.website, license: "", category: "AUR",
        repo: "aur", version: info.version, arch: "", licenses: info.license,
        updated: info.lastModified,
        thumbnail: "", iconName: "", pacmanPkg: "", aurPkg: info.name, flatpakPkg: "",
        _pkg: info.name,
        aurVotes: info.votes, aurMaintainer: info.maintainer, aurOutdated: info.outOfDate,
        aurPopularity: info.popularity
      })
      added++
    }
    // Enrich icons for the newly-added rows (AUR packs usually have no icon;
    // the batched local/appstream/flathub lookups resolve one by name).
    requestEnrich()
    refreshInstalled(false)
    root.applyView()
  }

  Process {
    id: aurProc
    property int mySeq: -1
    running: false
    stdout: StdioCollector {
      onStreamFinished: root.onAurResults(text || "")
    }
  }

  Process {
    id: pacmanProc
    property int mySeq: -1
    running: false
    stdout: StdioCollector {
      onStreamFinished: root.onPacmanResults(text || "")
    }
  }

  Process {
    id: flatpakProc
    property int mySeq: -1
    running: false
    stdout: StdioCollector {
      onStreamFinished: root.onFlatpakResults(text || "")
    }
  }

  // ---------------------------------------------- icon enrichment (pacman)
  // Best-effort: give icon-less pacman rows an icon. Installed packages get a
  // locally-installed icon (fast, via per-row filesystem lookup); others are
  // resolved against Arch's published AppStream catalog (one small batched
  // download of all repo icons, then instant local lookups); the rest get a
  // Flathub icon via a SINGLE batched `flatpak search` per query (mapped by
  // name), avoiding one slow serialized search per row.
  Timer {
    id: enrichDebounce
    interval: 120
    repeat: false
    onTriggered: root.enqueueEnrich()
  }
  property var enrichQueue: []
  property var localQueue: []
  property var flatpakQueue: []
  property bool enrichBusy: false

  function requestEnrich() {
    // In "All" the three handlers land within a few hundred ms of each other,
    // and each called enqueueEnrich() directly — which resets the queues and
    // kills whatever enrich was in flight. Coalesce into one pass per burst.
    enrichDebounce.restart()
  }

  function enqueueEnrich() {
    // A prior enrich whose onStreamFinished never fired (e.g. a process that
    // failed to start) would leave enrichBusy latched and silently disable all
    // future enrichment, so always reset it when (re)queueing.
    enrichBusy = false
    enrichQueue = []
    flatpakQueue = []
    localQueue = []
    for (var i = 0; i < filteredModel.count; i++) {
      var e = filteredModel.get(i)
      if (!e || e._pkg === undefined || e._pkg === "") continue
      if (e.thumbnail === "" && e.iconName === "") {
        enrichQueue.push({ index: i, name: e.name, pkg: e._pkg })
        continue
      }
      // This row already has an icon, but a pacman / AUR package can still have
      // a Flathub equivalent worth offering. Resolving that app id is not an
      // icon concern: it unlocks a second INSTALL SOURCE on the card, so those
      // rows are queued for the Flathub pass too (otherwise only the icon-less
      // packages would ever get a "flatpak (...)" button).
      if (e.flatpakPkg === "" || e.flatpakPkg === undefined) {
        flatpakQueue.push({ index: i, name: e.name, pkg: e._pkg })
      }
    }
    pumpEnrich()
  }

  // Resolve icons cheapest-first: the batched AppStream-catalog lookup (a ~MB
  // catalog already cached on disk → one fast local scan), then the installed
  // icon-theme lookup (a `pacman -Ql` + /usr/share/icons scan) for rows the
  // catalog missed, then one batched flathub search for the leftovers.
  function pumpEnrich() {
    if (enrichBusy) return
    if (enrichQueue.length > 0) {
      enrichBusy = true
      lookupAppstreamIcons()
      return
    }
    if (localQueue.length > 0) {
      enrichBusy = true
      lookupLocalIcons()
      return
    }
    if (flatpakQueue.length > 0) {
      enrichBusy = true
      launchBatchFlatpak()
    }
  }

  // Find locally-installed icons for all pending pacman packages in one pass.
  // Reads each package's desktop file (Icon= field) and resolves it against
  // the installed icon themes (all of /usr/share/icons/*/apps + scalable/apps,
  // plus pixmaps and user icons), handling absolute paths and names with dots
  // or extensions. Emits "I|<pkg>|<path>" per row, "" when none is found (those
  // rows fall through to the AppStream-catalog lookup).
  function lookupLocalIcons() {
    var names = []
    for (var i = 0; i < localQueue.length; i++)
      if (names.indexOf(localQueue[i].pkg) === -1) names.push(localQueue[i].pkg)
    var script = "DIRS=$(find /usr/share/icons -type d -path '*/apps' -o -type d -path '*/scalable/apps' 2>/dev/null | sort -u)\n"
    script += "resolve(){ p=\"$1\"; icon=$(pacman -Ql \"$p\" 2>/dev/null | grep -m1 '\\.desktop$' | awk '{print $2}'); [ -z \"$icon\" ] && return 1\n"
    script += "nm=$(grep -m1 -oP '^Icon=(.+)$' \"$icon\" 2>/dev/null | cut -d= -f2- | tr -d '\\r' | xargs); [ -z \"$nm\" ] && return 1\n"
    script += "[ -f \"$nm\" ] && { echo \"I|$p|$nm\"; return 0; }\n"
    script += "case \"$nm\" in /*.*) for d in /usr/share/icons /usr/share/pixmaps \"$HOME/.local/share/icons\"; do [ -f \"$d/$nm\" ] && { echo \"I|$p|$d/$nm\"; return 0; }; done;; esac\n"
    script += "clean=${nm##*/}; for ext in png svg svgz xpm; do case \"$clean\" in *\".$ext\") clean=${clean%.$ext}; break;; esac; done\n"
    script += "for d in $DIRS; do for ext in png svg svgz xpm; do [ -f \"$d/$clean.$ext\" ] && { echo \"I|$p|$d/$clean.$ext\"; return 0; }; done; done\n"
    script += "for d in /usr/share/pixmaps \"$HOME/.local/share/icons\"; do for ext in png svg svgz xpm; do [ -f \"$d/$clean.$ext\" ] && { echo \"I|$p|$d/$clean.$ext\"; return 0; }; done; done\n"
    script += "hit=$(pacman -Ql \"$p\" 2>/dev/null | awk '{print $2}' | grep -iE '\\.(png|svg|svgz|xpm)$' | grep -iE '/apps/|pixmaps/|/icons/' | grep -iE \"/${p##*/}[^/]*$\" | head -1); [ -n \"$hit\" ] && [ -f \"$hit\" ] && { echo \"I|$p|$hit\"; return 0; }; return 1; }\n"
    // Package names arrive as ARGV ("$@"), never spliced into the script text.
    // They come from pacman -Ss / remote package metadata, so interpolating
    // them would hand a crafted name straight to the shell.
    script += "for p in \"$@\"; do resolve \"$p\" || echo \"I|$p|\"; done"
    localIconProc.command = ["sh", "-c", script, "fossfetch-icons"].concat(names)
    localIconProc.running = false
    localIconProc.running = true
  }

  Process {
    id: localIconProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || "").split("\n")
        for (var i = 0; i < out.length; i++) {
          var line = out[i]
          if (!line || line.indexOf("I|") !== 0) continue
          var parts = line.split("|")
          if (parts.length < 3) continue
          var idx = root.rowIndexForPkg(parts[1])
          if (idx < 0) continue
          if (parts[2] !== "") {
            filteredModel.setProperty(idx, "thumbnail", parts[2])
          } else {
            for (var k = 0; k < root.localQueue.length; k++)
              if (root.localQueue[k].pkg === parts[1]) { root.flatpakQueue.push(root.localQueue[k]); break }
          }
        }
        root.localQueue = []
        root.enrichBusy = false
        root.pumpEnrich()
      }
    }
  }

  // Absolute path to the bundled search backends. Kept as files (not inline
  // `sh -c` strings) so their STATUS|-frame logic is directly regression-tested.
  readonly property string pacmanBackendScript: Qt.resolvedUrl("./backend_pacman.sh").toString().replace("file://", "")
  readonly property string flatpakBackendScript: Qt.resolvedUrl("./backend_flatpak.sh").toString().replace("file://", "")
  // Absolute path to the bundled AppStream-catalog icon resolver.
  readonly property string appstreamIconScript: Qt.resolvedUrl("./appstream_icons.sh").toString().replace("file://", "")
  readonly property string appstreamGroupsScript: Qt.resolvedUrl("./appstream_groups.sh").toString().replace("file://", "")
  readonly property string installHotkeyScript: Qt.resolvedUrl("./install_hotkey.sh").toString().replace("file://", "")
  readonly property string hotkeyCombo: "SUPER + CTRL + SHIFT + F"
  readonly property string iconCacheDir: Quickshell.env("HOME") + "/.cache/fossfetch"

  // Resolve every icon-less row against Arch's published AppStream catalog in
  // one subprocess. The helper downloads the (few-MB) per-repo icon set into
  // ~/.cache/fossfetch/catalog the first time it runs — then resolves each pkg
  // by its "<pkg>_<appid>.png" naming convention locally, emitting "I|<pkg>|<path>".
  function lookupAppstreamIcons() {
    var names = []
    for (var i = 0; i < root.enrichQueue.length; i++)
      if (names.indexOf(root.enrichQueue[i].pkg) === -1) names.push(root.enrichQueue[i].pkg)
    if (names.length === 0) { root.enrichBusy = false; root.pumpEnrich(); return }
    appstreamIconProc.command = [appstreamIconScript, "resolve", iconCacheDir].concat(names)
    appstreamIconProc.running = false
    appstreamIconProc.running = true
  }

  Process {
    id: appstreamIconProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || "").split("\n")
        for (var i = 0; i < out.length; i++) {
          var line = out[i]
          if (!line || line.indexOf("I|") !== 0) continue
          var parts = line.split("|")
          if (parts.length < 3) continue
          var idx = root.rowIndexForPkg(parts[1])
          if (idx < 0) continue
          if (parts[2] !== "" && filteredModel.get(idx).thumbnail === "") {
            filteredModel.setProperty(idx, "thumbnail", parts[2])
          } else {
            for (var k = 0; k < root.enrichQueue.length; k++)
              if (root.enrichQueue[k].pkg === parts[1]) { root.localQueue.push(root.enrichQueue[k]); break }
          }
        }
        root.enrichQueue = []
        root.enrichBusy = false
        root.pumpEnrich()
      }
    }
  }

  // Absolute path to the bundled Flathub-app-id resolver.
  readonly property string flatpakIconScript: Qt.resolvedUrl("./flatpak_icon.py").toString().replace("file://", "")
  readonly property string flathubGroupsScript: Qt.resolvedUrl("./flathub_groups.py").toString().replace("file://", "")
  // Absolute path to the bundled AUR search helper (RPC v5, no Auth).
  readonly property string aurSearchScript: Qt.resolvedUrl("./aur_search.py").toString().replace("file://", "")

  // Resolve every icon-less row to its Flathub app id (→ CDN icon) in one
  // subprocess. The helper runs a few candidate `flatpak search` spellings per
  // name and picks the main app (never Manual/Plugin/Sdk variants), emitting
  // "N|<pkg>|<appid>" per row.
  function launchBatchFlatpak() {
    var names = []
    for (var i = 0; i < root.flatpakQueue.length && names.length < 60; i++)
      if (names.indexOf(root.flatpakQueue[i].pkg) === -1) names.push(root.flatpakQueue[i].pkg)
    if (names.length === 0) { root.enrichBusy = false; return }
    enrichQuery.command = ["python3", flatpakIconScript, "--cache", root.iconCacheDir, "--"].concat(names)
    enrichQuery.running = false
    enrichQuery.running = true
  }

  Process {
    id: enrichQuery
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.applyBatchFlatpak(text || "")
        root.enrichBusy = false
        root.flatpakQueue = []
      }
    }
  }

  // Batched best-effort license scraping. For the visible rows still missing a
  // license, run one `pacman -Si` / `flatpak info --show-metadata` script and
  // attach each license to the matching row by package id.
  property int licenseSeq: 0
  Timer {
    id: licenseDebounce
    interval: 450
    repeat: false
    onTriggered: root.enqueueLicenses()
  }
  Process {
    id: licenseProc
    property int mySeq: -1
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        if (licenseProc.mySeq === root.licenseSeq)
          root.applyLicenseResults(text || "")
      }
    }
  }

  function enqueueLicenses() {
    var pkgs = []
    var flats = []
    for (var i = 0; i < filteredModel.count; i++) {
      var r = filteredModel.get(i)
      if (!r) continue
      if (String((r.licenses) || "").trim() !== "") continue
      if (r._pkg && r._pkg !== "" && r.repo !== "flathub") {
        if (pkgs.indexOf(r._pkg) === -1) pkgs.push(r._pkg)
      } else if (r.flatpakPkg && r.flatpakPkg !== "") {
        if (flats.indexOf(r.flatpakPkg) === -1) flats.push(r.flatpakPkg)
      }
      if (pkgs.length + flats.length >= 20) break
    }
    if (pkgs.length === 0 && flats.length === 0) return
    // One shell loop driven by ARGV instead of a generated line per package.
    // Package names and Flathub app ids are remote metadata; splicing them into
    // script text would hand a crafted name straight to the shell. Entries are
    // tagged ("F:<appid>") so a single process can serve both backends.
    var script = "for e in \"$@\"; do\n"
    script += "case \"$e\" in\n"
    script += "F:*) lic=$(flatpak info --show-metadata \"${e#F:}\" 2>/dev/null | sed -n 's/^license=//p' | head -1); echo \"F|${e#F:}|$lic\" ;;\n"
    script += "*) o=$(pacman -Si \"$e\" 2>/dev/null); lic=$(printf '%s\\n' \"$o\" | sed -n -e 's/^Licenses[[:space:]]*: *//p' -e 's/^License[[:space:]]*: *//p' | head -1); echo \"P|$e|$lic\" ;;\n"
    script += "esac\n"
    script += "done"
    var args = []
    for (var k = 0; k < pkgs.length; k++) args.push(pkgs[k])
    for (var m = 0; m < flats.length; m++) args.push("F:" + flats[m])
    root.licenseSeq++
    licenseProc.mySeq = root.licenseSeq
    licenseProc.command = ["sh", "-c", script, "fossfetch-licenses"].concat(args)
    licenseProc.running = false
    licenseProc.running = true
  }

  function applyLicenseResults(text) {
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("|")
      if (parts.length < 3) continue
      var lic = (parts[2] || "").trim()
      if (lic === "") continue
      var idx = parts[0] === "P" ? root.rowIndexForPkg(parts[1]) : root.rowIndexForFlatpak(parts[1])
      if (idx >= 0) filteredModel.setProperty(idx, "licenses", lic)
    }
  }


  // Apply Flathub icons to every deferred icon-less row resolved by the helper.
  function applyBatchFlatpak(txt) {
    if (root.flatpakQueue.length === 0) return
    var lines = String(txt || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line || line.indexOf("N|") !== 0) continue
      var parts = line.split("|")
      if (parts.length < 3) continue
      var pkg = parts[1]
      var appId = parts[2].trim()
      if (!appId) continue
      var idx = root.rowIndexForPkg(pkg)
      if (idx < 0) continue
      // The resolved Flathub app id is more than an icon: it is a real install
      // source. Attach it to the row so the card can offer "pacman (firefox)"
      // and "flatpak (org.mozilla.firefox)" side by side.
      filteredModel.setProperty(idx, "flatpakPkg", appId)
      filteredModel.setProperty(idx, "category", "Pacman · Flathub")
      // Only fall back to the CDN icon when the row has none of its own.
      if (filteredModel.get(idx).thumbnail === "")
        filteredModel.setProperty(idx, "thumbnail", flathubIcon(appId))
    }
  }

  // ------------------------------------------------------- metadata scrape
  // Pull the real project homepage (the URL: field — often a GitHub repo),
  // plus repo/version/arch/license, from `pacman -Si`. Batched into ONE
  // subprocess over all results instead of one spawn per package — the -Ss
  // search never carries URLs, and per-row spawning is what made the panel
  // feel slow. `pacman -Si` accepts many packages and prints one block each.
  function enqueueMeta() {
    var pkgs = []
    for (var i = 0; i < filteredModel.count; i++) {
      var e = filteredModel.get(i)
      if (e.pacmanPkg && e.pacmanPkg !== "" && pkgs.indexOf(e.pacmanPkg) === -1) {
        pkgs.push(e.pacmanPkg)
      }
      if (pkgs.length >= 50) break
    }
    if (pkgs.length === 0) return
    // Restart the batched scrape with the current rows even if a previous one
    // is still in flight — results are resolved by package name, so a stale
    // run is harmless. Without this, a rapid new search would never fetch its
    // websites/metadata (the old boolean guard dropped them permanently).
    metaProc.command = ["pacman", "-Si"].concat(pkgs)
    metaProc.running = false
    metaProc.running = true
  }

  Process {
    id: metaProc
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.applyMeta(text || "")
      }
    }
  }

  // Resolve the current model index for a row by its package name. Used by
  // async writers so their results always land on the correct card even if
  // the model shifted while a subprocess was in flight.
  function rowIndexForPkg(pkg) {
    var i = root.pkgIndex[pkg]
    return i === undefined ? -1 : i
  }

  function rowIndexForFlatpak(id) {
    var i = root.flatpakIndex[id]
    return i === undefined ? -1 : i
  }

  // Drop and rebuild the key -> row index maps. Rows are only ever appended or
  // cleared wholesale (never reordered or removed), so the maps stay valid
  // between rebuilds; clearing the model is the one event that invalidates them.
  function reindexModel() {
    root.pkgIndex = ({})
    root.flatpakIndex = ({})
    for (var i = 0; i < filteredModel.count; i++) {
      var r = filteredModel.get(i)
      if (!r) continue
      var pk = r._pkg !== undefined && r._pkg !== "" ? r._pkg
             : (r.pacmanPkg !== undefined && r.pacmanPkg !== "" ? r.pacmanPkg : "")
      // Empty keys are never indexed: some rows are filled with
      // an empty _pkg, and storing "" would make every lookup hit row 0.
      if (pk !== "" && root.pkgIndex[pk] === undefined) root.pkgIndex[pk] = i
      var fp = r.flatpakPkg
      if (fp !== undefined && fp !== "" && root.flatpakIndex[fp] === undefined)
        root.flatpakIndex[fp] = i
    }
  }

  // Distribute the batched `pacman -Si` output (one block per package, each
  // starting with a "Name :" line) onto the matching rows.
  function applyMeta(text) {
    var s = String(text || "")
    var blocks = s.split(/\n(?=Name\s*:)/)
    for (var b = 0; b < blocks.length; b++) {
      var block = blocks[b]
      // Each block starts with a padded "Name" field (e.g. "Name   : gimp").
      if (!/^Name\s*:/.test(block)) continue
      var field = function(label) {
        var m = block.match(new RegExp("^" + label + "\\s*:\\s*(.+)$", "mi"))
        return m ? m[1].trim() : ""
      }
      var name = field("Name")
      if (!name) continue
      var idx = root.rowIndexForPkg(name)
      if (idx < 0) continue
      var repo = field("Repository")
      var version = field("Version")
      var arch = field("Architecture")
      var desc = field("Description")
      var url = field("URL")
      var licenses = field("Licenses")
      var buildDate = field("Build Date")
      var size = field("Download Size")
      if (size !== "") filteredModel.setProperty(idx, "downloadSize", size)
      // Dependency graph + installed footprint, read from the SAME `pacman -Si`
      // batch rather than a second lookup per card.
      //
      // Field names are the sync-DB labels, which differ from the installed-DB
      // ones: -Si says "Depends On" / "Optional Deps" and has no "Required By"
      // at all (that only exists in -Qi, and is fetched lazily when the details
      // sheet opens for an installed row — see fetchDepGraph).
      var instSize = field("Installed Size")
      if (instSize !== "") filteredModel.setProperty(idx, "installedSize", instSize)
      var depends = field("Depends On")
      if (depends !== "") filteredModel.setProperty(idx, "dependsOn", depends)
      var optional = field("Optional Deps")
      if (optional !== "") filteredModel.setProperty(idx, "optionalDeps", optional)
      var conflicts = field("Conflicts With")
      if (conflicts !== "") filteredModel.setProperty(idx, "conflictsWith", conflicts)
      var provides = field("Provides")
      if (provides !== "") filteredModel.setProperty(idx, "provides", provides)
      var groups = field("Groups")
      if (groups !== "") filteredModel.setProperty(idx, "groups", groups)
      var packager = field("Packager")
      if (packager !== "") filteredModel.setProperty(idx, "packager", packager)
      if (repo !== "") filteredModel.setProperty(idx, "repo", repo)
      if (version !== "") filteredModel.setProperty(idx, "version", version)
      if (arch !== "") filteredModel.setProperty(idx, "arch", arch)
      if (desc !== "") filteredModel.setProperty(idx, "description", desc)
      if (url !== "") filteredModel.setProperty(idx, "website", url)
      if (licenses !== "") filteredModel.setProperty(idx, "licenses", licenses)
      if (buildDate !== "") filteredModel.setProperty(idx, "updated", buildDate)
    }
    // Build Date is what makes "Updated" available at all, and it only exists
    // once this batch has run.
    root.refreshSortModes()
  }

  // ---------------------------------------------------------------- install
  // One-click install with a confirm step. First click arms the button
  // (shows "Confirm?"), a second click within the timeout runs the install
  // in the user's terminal. Independent per-branch/per-package so pacman and
  // flatpak buttons on the same card don't fight.
  // One pending-action slot shared by install and remove, backed by the shell's
  // ConfirmDialog rather than the old "click once, then click again within 3
  // seconds" arm button. The arm button had two problems: the timeout silently
  // reverted with no feedback, and a destructive removal was confirmed by
  // exactly the same gesture as an install. A real dialog names the action,
  // cancels with Escape, and marks the destructive choice.
  property var pendingAction: null
  // Only an install or an update uses the timed arm. A removal goes straight to
  // the dialog, which stays up until you answer it — a destructive action should
  // never expire out from under the cursor.
  Timer {
    id: confirmResetTimer
    interval: 3000
    repeat: false
    onTriggered: {
      var m = root.pendingAction ? root.pendingAction.mode : ""
      if (m === "install" || m === "update") { root.cancelPendingAction() }
    }
  }

  function pendingMessage() {
    var a = root.pendingAction
    if (!a) return ""
    var verb = a.mode === "remove" ? "Remove" : (a.mode === "update" ? "Update" : "Install")
    var count = parseInt(String(a.pkg || ""), 10)
    // A batch's `pkg` is the placeholder "N packages", not an id, so printing
    // it the way a single package is printed would read "Remove 3 packages
    // (3 packages)?" -- the same fact twice, in a dialog about something
    // irreversible.
    if (!isNaN(count) && /\s/.test(String(a.pkg))) return verb + " " + count + " packages?"
    return verb + " " + (a.name || a.pkg) + " (" + a.pkg + ")?"
  }

  function confirmPendingAction() {
    var a = root.pendingAction
    if (!a) return
    root.pendingAction = null
    // A batch was armed with a human-readable "N packages" placeholder rather
    // than a package id, so the single-action path below would hand the
    // installer the literal string "3 packages". Anything with a queue behind
    // it is the batch runner's instead.
    if (root.batchQueue.length > 0) { root.runNextBatchGroup(); return }
    if (a.mode === "remove") root.runRemove(a.kind, a.pkg, a.name)
    else if (a.mode === "update") root.runUpdate(a.kind, a.pkg, a.name, a.from, a.to)
    else root.runInstall(a.kind, a.pkg, a.name)
  }

  function cancelPendingAction() {
    root.pendingAction = null
    // Dropping the confirmation must drop the queue it was standing in front
    // of, and the in-flight flag with it -- otherwise the next unrelated
    // action's exit would find batchActive set and try to run a batch that
    // was never confirmed.
    root.batchQueue = []
    root.batchActive = false
  }

  function actionPending(mode, kind, pkg) {
    return root.pendingAction !== null
      && root.pendingAction.mode === mode
      && root.pendingAction.kind === kind
      && root.pendingAction.pkg === pkg
  }

  function installPending(kind, pkg) { return root.actionPending("install", kind, pkg) }
  function removePending(kind, pkg) { return root.actionPending("remove", kind, pkg) }
  function updatePending(kind, pkg) { return root.actionPending("update", kind, pkg) }

  function startInstall(kind, pkg, name) {
    // Second click on the armed button runs it, as before. Installing is not
    // destructive, and a modal dialog for every install is friction in a
    // launcher you open all day.
    if (root.installPending(kind, pkg)) {
      root.pendingAction = null
      root.runInstall(kind, pkg, name)
      return
    }
    root.pendingAction = { mode: "install", kind: kind, pkg: pkg, name: name }
    confirmResetTimer.restart()
  }

  function startRemove(kind, pkg, name) {
    root.pendingAction = { mode: "remove", kind: kind, pkg: pkg, name: name }
  }

  // Updating is NOT destructive — it moves a package forward, never away — so
  // it uses the same non-modal arm-then-run path as an install rather than the
  // Remove dialog. Two clicks: first arms, second runs.
  function startUpdate(kind, pkg, name, from, to) {
    if (root.actionPending("update", kind, pkg)) {
      root.pendingAction = null
      root.runUpdate(kind, pkg, name, from, to)
      return
    }
    root.pendingAction = { mode: "update", kind: kind, pkg: pkg, name: name,
                           from: from, to: to }
    confirmResetTimer.restart()
  }

  // What the panel last launched, so the exit toast can name it. Captured at
  // launch time rather than read off pendingAction, which startInstall clears
  // the moment the command is dispatched.
  property string lastActionLabel: ""
  property string lastActionKind: ""
  property string lastActionVerb: "install"

  function notify(title, body) {
    // Fire-and-forget. The shell runs a notification server, so this surfaces as
    // a normal desktop toast; failures are ignored because a missing notifier
    // must never break an install.
    notifyProc.command = ["notify-send", "-a", "FossFetch", "-t", "6000", title, body]
    notifyProc.running = false
    notifyProc.running = true
  }

  Process {
    id: notifyProc
    running: false
  }

  function sourceLabel(kind) {
    if (kind === "pacman") return "Pacman"
    if (kind === "yay" || kind === "paru") return kind
    return "Flatpak"
  }

  function runInstall(kind, pkg, name) {
    var args
    if (kind === "pacman") args = ["sudo", "pacman", "-S", "--needed", pkg]
    else if (kind === "yay") args = ["yay", "-S", "--needed", pkg]
    else if (kind === "paru") args = ["paru", "-S", "--needed", pkg]
    else args = ["flatpak", "install", "--assumeyes", "flathub", pkg]
    root.lastActionLabel = name || pkg
    root.lastActionKind = kind
    root.lastActionVerb = "install"

    actionProc.command = root.terminalArgv(args)
    actionProc.running = true
    // The package will be installed by the time the user comes back to this
    // panel; re-read the snapshot so the row shows as Installed, not stale.
    installFinishedTimer.restart()
  }

  // Update an already-installed package. For pacman the refresh of the sync
  // database (-Sy) is required before the bump, otherwise pacman refuses with
  // "target is up to date" against a stale cache. AUR helpers rebuild anyway
  // and take the plain -S form; flatpak's own update path is `update <appid>`.
  function runUpdate(kind, pkg, name, from, to) {
    var args
    if (kind === "pacman") args = ["sudo", "pacman", "-S", "-y", pkg]
    else if (kind === "yay") args = ["yay", "-S", pkg]
    else if (kind === "paru") args = ["paru", "-S", pkg]
    else args = ["flatpak", "update", "-y", pkg]
    root.lastActionLabel = name || pkg
    root.lastActionKind = kind
    root.lastActionVerb = "update"

    actionProc.command = root.terminalArgv(args)
    actionProc.running = true
    // Updates resolve and download; give the terminal room before re-reading
    // the installed snapshot (matches the remove settle time).
    removeFinishedTimer.restart()
  }

  // Undo an install. Removal is more destructive than install (it can take
  // away a working app, and removes dependencies the user may not realise are
  // going), so the commands deliberately avoid cascading flags — nothing the
  // user did not explicitly name is removed:
  //   pacman -R removes exactly the named package and leaves everything else
  //           alone. -s (recursive) is deliberately NEVER passed: a package's
  //           dependencies are usually still wanted by other installed
  //           software, and taking them silently breaks unrelated apps.
  //           -n (no-save) is skipped so a .pacsave of the config is kept as a
  //           way back.
  //   yay/paru -R removes just the named package too — an AUR package is not a
  //           dependency of other things, so plain -R is the honest default.
  function runRemove(kind, pkg, name) {
    var args
    if (kind === "pacman") args = ["sudo", "pacman", "-R", pkg]
    else if (kind === "yay") args = ["yay", "-R", pkg]
    else if (kind === "paru") args = ["paru", "-R", pkg]
    else args = ["flatpak", "uninstall", pkg]
    root.lastActionLabel = name || pkg
    root.lastActionKind = kind
    root.lastActionVerb = "remove"

    actionProc.command = root.terminalArgv(args)
    actionProc.running = true
    removeFinishedTimer.restart()
  }

  // Give the terminal a moment to actually do the work before re-reading.
  Timer {
    id: installFinishedTimer
    interval: 8000
    repeat: false
    onTriggered: root.refreshInstalled(true)
  }

  // Removal is slower than a reinstall (pacman resolves the dependency graph
  // before touching anything), so it gets a longer settle before the installed
  // snapshot is re-read.
  Timer {
    id: removeFinishedTimer
    interval: 12000
    repeat: false
    onTriggered: root.refreshInstalled(true)
  }

  Process {
    id: actionProc
    // The terminal stays alive for the whole command, so its exit is a decent
    // proxy for "the action finished". The exit code itself belongs to the
    // terminal, not pacman, so the toast states the outcome neutrally and points
    // at the terminal rather than claiming success.
    onExited: function(exitCode) {
      // The terminal propagates its child's status, so this is pacman/flatpak's
      // own exit code and not kitty's.
      root.lastBatchExitCode = exitCode === undefined || exitCode === null ? 0 : exitCode
      // A batch runs its groups one after another through this same Process, so
      // its exit is the cue for the next group rather than the end of the
      // whole thing. Handled before the single-action toast, which would
      // otherwise announce "finished" after the first of several.
      if (root.batchRunning) { root.runNextBatchGroup(); return }
      var what = root.lastActionLabel
      if (what === "") return
      root.notify("FossFetch",
        root.sourceLabel(root.lastActionKind) + " " + root.lastActionVerb
        + " finished for " + what + ". See the terminal for the result.")
      root.refreshInstalled(true)
      // An install or an update both change how many updates are pending, and
      // the badge is on screen whether or not the panel is open.
      root.updatesAt = 0
      root.refreshUpdates()
      root.clipboardSuggestion()
      // Updates only, and only from here.
      //
      // An update replaces an app in place, and the bar and dock keep serving
      // the old one's cached state until the shell is told to re-read it --
      // the update appears to do nothing until the desktop flashes. A fresh
      // install has no such problem: its .desktop file is new, and the launchers
      // pick that up on their next read. And a removal takes an entry away, so
      // restarting for one would be pure disruption.
      //
      // The cost is real and deliberate: this tears down the bar, the dock and
      // every other plugin. Scheduled rather than immediate so the toast above
      // is readable first, and guarded so a batch does not restart the shell
      // once per package.
      if (root.lastActionVerb === "update") root.scheduleShellRestart()
    }
  }

  // ------------------------------------------------------------- lifecycle
  // Unwind one layer at a time, least destructive first: a batch that has been
  // armed but not yet confirmed is the most recent and most expensive mistake
  // available, so it goes before the selection that armed it.
  function unwindOnce() {
    if (root.pendingAction !== null && root.batchQueue.length > 0) {
      root.cancelPendingAction()
      return true
    }
    if (root.selectedCount > 0) { root.clearSelection(); return true }
    if (detailsSheet.open) { root.closeDetails(); return true }
    return false
  }

  // A launcher with no shortcut is not a launcher. Installed once, on the
  // first open, and only if the user has not already bound it themselves --
  // install_hotkey.sh checks every file in the hypr config dir first, so this
  // never adds a second binding on top of one they wrote by hand.
  //
  // Guarded by a persisted flag as well as the script's own check: if a user
  // deletes the line, that is a decision, and it must not be undone by the
  // plugin re-adding it on every launch.
  property bool hotkeyInstalled: false

  function ensureHotkey() {
    if (root.hotkeyInstalled) return
    root.hotkeyInstalled = true
    root.persistOptions()
    hotkeyProc.command = ["sh", root.installHotkeyScript,
                          Quickshell.env("HOME") + "/.config/hypr", root.hotkeyCombo]
    hotkeyProc.running = false
    hotkeyProc.running = true
  }

  Process {
    id: hotkeyProc
    stdout: StdioCollector { waitForEnd: true }
  }

  function open() {
    root.controller.show()
    root.ensureFreshScan()
    root.detectTerminal()
    root.ensureHotkey()
    root.focusWhenShown()
  }

  function openFromHotkey() {
    root.controller.show()
    // The hotkey/IPC path does NOT go through open(), so the scan has to be
    // requested here too — otherwise the badge and the Updates tab stay empty
    // until the first periodic tick, however many times the panel is opened.
    root.ensureFreshScan()
    root.focusWhenShown()
  }

  // Take focus only once the panel is actually up.
  //
  // controller.show() flips `opened`, and a panel that is not yet visible has
  // no focusable window, so an immediate forceActiveFocus() is silently
  // dropped: the panel appears, the field is not focused, and every keystroke
  // goes to whatever was behind it. This is why the search box could need two
  // opens before it took a character. Deferred to the next event-loop turn,
  // and retried while `opened` is still false, because the transition is not
  // guaranteed to have landed by the first one.
  function focusWhenShown() {
    Qt.callLater(function() {
      if (root.opened) { root.refreshFocus(); return }
      Qt.callLater(root.focusWhenShown)
    })
  }

  // Re-scan on demand, throttled so opening the panel in a tight loop does not
  // spawn a checkupdates subprocess every time. The scan talks to three package
  // managers, two of which can reach the network, so it is never run on top of
  // itself.
  // True when the last scan could not reach at least one source. Kept separate
  // from updateCount so "unknown" is never collapsed into "none".
  property bool updatesDegraded: false

  // Short retry after a degraded scan. The common cause is a transient pacman
  // lock during startup, which clears in seconds; waiting the full five minutes
  // would leave the badge blank for most of the session.
  Timer {
    id: updateRetry
    interval: 25000
    repeat: true
    running: false
    onTriggered: {
      if (!root.updatesDegraded) { updateRetry.stop(); return }
      root.refreshUpdates()
    }
  }

  function ensureFreshScan() {
    if (Date.now() - root.updatesAt > 60000) root.refreshUpdates()
  }

  function close() {
    // The panel can be dismissed faster than the settle window, and a search
    // that was run and then closed on is still a search worth remembering.
    root.flushRecent()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function refreshFocus() {
    searchField.forceActiveFocus()
    searchField.selectAll()
  }

  // Focus-only variant: keeps the caret where it is and leaves the query
  // untouched, so a Tab between Pacman / AUR / Flatpak does not destroy what
  // the user typed.
  function refocus() {
    searchField.forceActiveFocus()
  }

  // Offer the clipboard as the query when it looks like something worth
  // searching for: a package error, an app name someone pasted. Long or
  // multi-line clipboard contents are ignored — dropping a paragraph into the
  // box is never what anyone wants.
  // Restart the shell once, shortly after an update lands.
  property bool shellRestartPending: false

  function scheduleShellRestart() {
    if (root.shellRestartPending) return
    root.shellRestartPending = true
    shellRestartTimer.restart()
  }

  Timer {
    id: shellRestartTimer
    interval: 1800
    repeat: false
    onTriggered: root.restartShellNow()
  }

  // Detached, so the restart cannot be killed by the very shell it replaces,
  // and so a failing restart command cannot take the panel down with it.
  function restartShellNow() {
    shellRestartProc.command = ["setsid", "omarchy", "restart", "shell"]
    shellRestartProc.running = false
    shellRestartProc.running = true
  }

  Process {
    id: shellRestartProc
    running: false
  }

  function clipboardSuggestion() {
    clipProc.running = false
    clipProc.running = true
  }

  function applyClipboard(text) {
    var t = String(text || "").trim()
    if (t === "" || t.indexOf("\n") !== -1 || t.length > 80) return
    if (searchField.text !== "") return
    // Filling the field is not typing. Arm the pending query so committing it
    // still remembers it, but do not start the settle timer: the clipboard is
    // offered speculatively, and a suggestion the user ignored should never
    // turn up in their recents.
    root.suppressRecentSettle = true
    searchField.text = t
    root.suppressRecentSettle = false
    root.refocus()
  }

  Process {
    id: clipProc
    running: false
    // -t text: without it an image sitting on the clipboard would be dumped
    // into the collector as raw bytes and then offered as a "search term".
    // wl-clipboard is optional — a missing binary just yields nothing.
    command: ["sh", "-c", "wl-paste -t text --no-newline 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyClipboard(text || "")
    }
  }

  onOpenedChanged: if (opened) {
    refreshFocus()
    root.warmGroupIndexes()
    root.refreshInstalled(true)
    detectAurHelperProc.running = false
    detectAurHelperProc.running = true
  }

  // Which AUR helpers exist. `command -v` in a subshell so a missing binary is
  // a silent miss rather than an error line on the panel's stderr.
  Process {
    id: detectAurHelperProc
    running: false
    command: ["sh", "-c", "for h in paru yay pikaur; do command -v \"$h\" >/dev/null 2>&1 && echo \"$h\"; done"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.detectAurHelpers(text || "")
    }
  }

  // Builds the AppStream category indexes (pacman + flatpak) once in the
  // background when the panel first opens, so the first group search doesn't
  // stall on a download. The scripts' own staleness checks make this a fast
  // no-op after the first successful build.
  property bool groupsWarmed: false
  property bool archWarming: false
  property bool flathubWarming: false
  readonly property bool catalogWarming: root.archWarming || root.flathubWarming

  function warmGroupIndexes() {
    if (root.groupsWarmed) return
    root.groupsWarmed = true
    // One process per catalogue, tracked separately, so the panel can say which
    // one it is waiting on rather than going quiet for the whole build.
    archWarmProc.command = [root.appstreamGroupsScript, "ensure", root.iconCacheDir]
    archWarmProc.running = true
    root.archWarming = true
    // The Flathub index is a ~10 MB download and is only consulted by the
    // Flatpak (and All) tabs — never start it for a user who has switched the
    // Flatpak search off and not enabled All.
    if (root.flatpakEnabled || root.allEnabled) {
      flathubWarmProc.command = ["python3", root.flathubGroupsScript, "ensure", root.iconCacheDir]
      flathubWarmProc.running = true
      root.flathubWarming = true
    }
  }

  Process {
    id: archWarmProc
    running: false
    stdout: StdioCollector { waitForEnd: true }
    onExited: root.archWarming = false
  }

  Process {
    id: flathubWarmProc
    running: false
    stdout: StdioCollector { waitForEnd: true }
    onExited: root.flathubWarming = false
  }

  // Which catalogue the current tab is still waiting on, or "" when nothing is.
  function warmingLabel() {
    if (root.isFlatpak || root.isAll) {
      if (root.flathubWarming) return "Building the Flathub index — category matches appear once it finishes."
      if (root.archWarming) return "Building the AppStream index — category matches appear once it finishes."
    } else if (root.archWarming) {
      return "Building the AppStream index — category matches appear once it finishes."
    }
    return ""
  }

  // --------------------------------------------------------------- keyboard
  function moveCursor(dx, dy) {
    if (filteredModel.count === 0) return
    var idx = resultsList.currentIndex
    var n = filteredModel.count
    if (dy !== 0) idx = Math.max(0, Math.min(n - 1, idx + dy))
    resultsList.currentIndex = idx
    resultsList.positionViewAtIndex(idx, ListView.Center)
  }

  // The primary install action for a row — mirrors the per-branch InstallButton
  // visibility rules, so Enter arms exactly the button that is shown on the
  // active tab. Returns null when the row has no installable source.
  function cardInstallSpec(e) {
    if (!e) return null
    if ((root.isPacman || root.isAll) && e.pacmanPkg && e.pacmanPkg !== "") {
      // Report which way this source would act, so Enter drives the same
      // button the user can see rather than always re-installing.
      return { mode: root.isPacmanInstalled(e.pacmanPkg) ? "remove" : "install",
               kind: "pacman", pkg: e.pacmanPkg }
    }
    if ((root.isPacman || root.isAur || root.isAll) && e.aurPkg && e.aurPkg !== "") {
      return { mode: root.isAurInstalled(e.aurPkg) ? "remove" : "install",
               kind: root.aurHelper, pkg: e.aurPkg }
    }
    return null
  }

  // The newest update this row can offer across its sources, or null. A source
  // only counts when the package is installed AND the version on offer is
  // strictly newer (Model.needsUpdate), so a card never shows an "Update"
  // for something already current. `to` is the offered version, `from` the
  // installed one — both are shown so the update is never a mystery.
  function pendingUpdate(e) {
    if (!e) return null
    var best = null
    var consider = function(kind, pkg) {
      if (!pkg || pkg === "") return
      if (kind === "flatpak") { if (!root.isFlatpakInstalled(pkg)) return }
      else if (!root.isPacmanInstalled(pkg)) return
      var from = root.installedVersion(pkg)
      var to = String(e.version || "")
      if (!Model.needsUpdate(to, from)) return
      if (!best || Model.compareVersions(to, best.to) === 1)
        best = { kind: kind, pkg: pkg, from: from, to: to, name: e.name }
    }
    if (root.isPacman || root.isAll) consider("pacman", e.pacmanPkg)
    if (root.isAur || root.isPacman || root.isAll) consider(root.aurHelper, e.aurPkg)
    if (root.isFlatpak || root.isAll) consider("flatpak", e.flatpakPkg)
    return best
  }

  // A short "old → new" string for the details sheet and the update chip.
  function updateLabel(u) {
    if (!u) return ""
    // The installed version is absent when the scan landed before the pacman
    // snapshot did; "→ 8.3.0" is still a true statement about the update.
    return u.from !== "" ? u.from + " → " + u.to : "→ " + u.to
  }

  // The update action for a row, preferring what the panel can prove and
  // falling back to what the scan asserted. On the Updates tab the install and
  // remove controls are hidden, so a row that resolved to no action at all
  // would be a dead card with nothing to click — the scan is the source's own
  // verdict and is good enough to act on.
  function updateSpecFor(e) {
    if (!e) return null
    var proven = root.pendingUpdate(e)
    if (proven) return proven
    if (!root.isUpdateRow(e)) return null
    var kind = e.pacmanPkg !== "" ? "pacman" : (e.flatpakPkg !== "" ? "flatpak" : root.aurHelper)
    var pkg = e.pacmanPkg !== "" ? e.pacmanPkg : (e.flatpakPkg !== "" ? e.flatpakPkg : e.aurPkg)
    if (pkg === "") return null
    return { kind: kind, pkg: pkg, from: root.installedVersion(pkg),
             to: String(e.version || ""), name: e.name }
  }

  // Enter on the highlighted card arms its action (first press shows the
  // button's "Confirm?" state); a second press runs the command. An
  // already-installed row arms the removal instead.
  function activateCursor() {
    // Enter is the other explicit commit: the user acted on this query, so it
    // is a real search regardless of whether the settle window has elapsed.
    root.flushRecent()
    if (filteredModel.count === 0) return
    // A live selection means Enter acts on what is MARKED, not on whatever the
    // cursor happens to be sitting on. With several rows queued, acting on the
    // highlighted one alone would be the least useful reading of the key.
    if (root.selectedCount > 0) {
      // Same precedence the single-row path below uses, applied to the whole
      // selection: an available update outranks everything, and when every
      // selected package is already installed and current the obvious thing is
      // to remove them -- not to report that there is nothing to install.
      if (root.batchGroups("update").length > 0) root.startBatch("update")
      else if (root.batchPkgCount("remove") === root.selectedCount) root.startBatch("remove")
      else root.startBatch("install")
      return
    }
    var idx = resultsList.currentIndex
    if (idx < 0 || idx >= filteredModel.count) return
    var row = filteredModel.get(idx)
    // An available update outranks install/remove: if the user is looking at an
    // installed package and newer exists, Enter should do the obvious thing.
    var upd = root.pendingUpdate(row)
    if (upd) {
      root.startUpdate(upd.kind, upd.pkg, upd.name, upd.from, upd.to)
      return
    }
    var spec = root.cardInstallSpec(row)
    if (!spec) return
    if (spec.mode === "remove") root.startRemove(spec.kind, spec.pkg, row.name)
    else root.startInstall(spec.kind, spec.pkg, row.name)
  }

  // Tab cycles through the enabled tabs only (skips ones toggled off).
  function switchPanel(direction) {
    var tabs = root.visibleTabs()
    if (tabs.length < 2) return
    var idx = tabs.indexOf(root.activeTab)
    if (idx < 0) idx = 0
    var next = tabs[(idx + (direction > 0 ? 1 : tabs.length - 1)) % tabs.length]
    root.switchTab(next)
  }

  // ------------------------------------------------------------- the terminal

// The user's own terminal, never a hard-coded one.
//
// The fallback used to be "kitty", which silently worked for the author and
// did nothing for everyone else: `TERMINAL` is unset in the Omarchy shell's
// environment, so every user who is not a kitty user got a terminal that could
// not start -- a window that flashed and vanished, or no window at all.
//
// Order of preference:
//   1. xdg-terminal-exec. It reads ~/.config/xdg-terminals.list, which is
//      exactly where `omarchy default terminal <x>` writes the user's choice,
//      so this follows their setting with no Omarchy-specific coupling.
//   2. `omarchy-default-terminal`, the script that reads that same list.
//   3. TERMINAL / TERMINAL_CMD from the environment.
//   4. kitty, purely as a last resort.
property string terminalRunner: ""   // "" | "xdg" | "<name>"

  function detectTerminal() {
    // Re-running is harmless and cheap; a user who changes their default
    // terminal gets it picked up on the next open.
    if (terminalProc.running) return
    terminalProc.running = true
  }

  function applyTerminalProbe(text) {
    var t = String(text || "").trim()
    if (t === "xdg") { root.terminalRunner = "xdg"; return }
    // The script can echo several lines; the first non-empty one is the name.
    var lines = t.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      if (name !== "" && name !== "xdg") { root.terminalRunner = name; return }
    }
    // Nothing resolved. terminalArgv() falls back to kitty, which at worst
    // reproduces the old behaviour instead of silently doing nothing.
    root.terminalRunner = ""
  }

  Process {
    id: terminalProc
    command: ["sh", "-c",
      "if command -v xdg-terminal-exec >/dev/null 2>&1; then echo xdg; "
      + "elif command -v omarchy-default-terminal >/dev/null 2>&1; then omarchy-default-terminal 2>/dev/null; "
      + "else printf '%s' \"${TERMINAL:-${TERMINAL_CMD:-kitty}}\"; fi"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyTerminalProbe(text || "")
    }
  }

  // argv prefix for running `args` in a terminal window.
  function terminalArgv(args) {
    var run = root.terminalRunner
    if (run === "xdg") return ["xdg-terminal-exec"].concat(args)
    if (run !== "") return [run, "-e"].concat(args)
    return ["kitty", "-e"].concat(args)
  }

  // ------------------------------------------------------------- the panel
  // Popup-surface conventions shared with the system dropdowns. The panel
  // itself already renders the frosted popups surface + popups border via
  // KeyboardPanel; the selected-row treatment mirrors the menu's.
  readonly property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", Color.menu.selectedBorder, 0)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)
    padding: Style.spacing.popupPadding

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      // Escape unwinds one layer at a time: the details sheet first, then the
      // panel. Closing the whole panel with the sheet open would look like the
      // sheet swallowed the key.
      onCloseRequested: {
        // Same one-layer-at-a-time unwind the Escape key uses, so losing
        // focus closes the panel exactly the way pressing Escape would.
        if (!root.unwindOnce()) root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onTextKey: function(t) {
        if (t === "/") root.refreshFocus()
      }

      // Confirmation for install/remove. Sits above the panel content and takes
      // the keys that matter (Escape / Tab / Enter) from the search field,
      // which is where focus lives.
      ConfirmDialog {
        id: actionConfirm
        anchors.fill: parent
        z: 10
        // Destructive only. ConfirmDialog hardcodes `destructive: index === 1`,
        // so its second button is always styled as the dangerous choice —
        // correct for "Remove", wrong for an install.
        opened: root.pendingAction !== null && root.pendingAction.mode === "remove"
        message: root.pendingMessage()
        confirmText: root.pendingAction && root.pendingAction.mode === "remove" ? "Remove" : "Install"
        cancelText: "Cancel"
        selectedIndex: 1
        onConfirmed: root.confirmPendingAction()
        onCanceled: root.cancelPendingAction()
      }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.spacing.xxl

        // ------------------------------------------------------------ header
        // PanelHero is the shell's own header: it owns the icon/title/subtitle
        // typography and reserves trailing-control geometry, so this panel stops
        // hand-rolling a layout that had to track the theme by hand.
        PanelHero {
          id: panelHero
          width: parent.width
          foreground: Color.popups.text
          title: "FossFetch"
          meta: root.tabCaption()
          fontFamily: Style.font.family
          iconComponent: Component {
            Icon {
              text: root.icons.search
              color: Color.accent
              // PanelHero declares `iconSize: Style.font.display` but never
              // applies it to the loader, so the mark takes its size from here.
              // 24px against a 14px title — a confident hero, not a caption
              // that happens to sit next to a wordmark.
              iconSize: Style.font.display
            }
          }
          trailingControl: Component {
            PanelActionButton {
              iconText: root.showOptions ? root.icons.close : root.icons.settings
              tooltipText: root.showOptions ? "Close settings" : "Settings"
              foreground: Color.popups.text
              fontFamily: Style.font.resolvedFamily
              fontSize: Style.font.body
              focusable: false
              onClicked: root.showOptions = !root.showOptions
            }
          }
        }

        // -------------------------------------------------------------- tabs
        // One segmented control, not three bordered pills. The old layout drew
        // an outline around every tab, which put the same weight on "Pacman",
        // "AUR" and "Flatpak" and left the active one reading as "also
        // selected" rather than "selected". A single track with hairline
        // dividers and one filled segment puts the hierarchy back.
        Item {
          id: tabBar
          width: parent.width
          implicitHeight: Style.space(32)

          readonly property int tabs: root.visibleTabs().length

          Rectangle {
            id: tabTrack
            anchors.fill: parent
            radius: Style.cornerRadius
            color: Util.alpha(Color.popups.text, 0.05)
            border.width: Style.spacing.hairline
            border.color: Util.alpha(Color.popups.text, 0.12)

            Row {
              id: tabRow
              anchors.fill: parent
              anchors.margins: Style.spacing.hairline

              Repeater {
                model: root.visibleTabs()

                delegate: Item {
                  id: segment
                  required property int modelData
                  readonly property bool active: root.activeTab === modelData
                  readonly property bool last: segment.index === tabBar.tabs - 1

                  width: tabRow.width / Math.max(1, tabBar.tabs)
                  height: tabRow.height

                  Rectangle {
                    anchors.fill: parent
                    radius: Math.max(0, Style.cornerRadius - Style.spacing.hairline)
                    color: segment.active
                      ? Util.alpha(Color.accent, 0.20)
                      : (segmentMouse.containsMouse ? Util.alpha(Color.popups.text, 0.07) : "transparent")

                    Behavior on color { ColorAnimation { duration: 120 } }
                  }

                  // Hairline between segments, but never at either end - an
                  // internal divider is what makes the track read as one
                  // control rather than a row of buttons.
                  Rectangle {
                    visible: !segment.last
                    anchors.right: parent.right
                    width: Style.spacing.hairline
                    height: parent.height - Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    color: Util.alpha(Color.popups.text, 0.12)
                  }

                  Text {
                    anchors.centerIn: parent
                    text: root.shortTabLabel(modelData)
                    color: segment.active ? Color.accent : Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: segment.active
                    textFormat: Text.PlainText
                  }

                  MouseArea {
                    id: segmentMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.switchTab(modelData)
                  }
                }
              }
            }
          }
        }

        PanelSeparator {
          foreground: Color.popups.text
        }

        // ------------------------------------------------------ options panel
        Item {
          width: parent.width
          visible: root.showOptions
          implicitHeight: root.showOptions ? optionsCol.implicitHeight : 0

          Column {
            id: optionsCol
            width: parent.width
            spacing: Style.spacing.sm

            Toggle {
              width: parent.width
              label: "Flatpak search"
              description: "Show the Flathub tab and its search results"
              checked: root.flatpakEnabled
              onClicked: root.setFlatpakEnabled(!root.flatpakEnabled)
            }

            Toggle {
              width: parent.width
              label: "AUR search"
              description: "Show the AUR tab and its search results"
              checked: root.aurEnabled
              onClicked: root.setAurEnabled(!root.aurEnabled)
            }

            Toggle {
              width: parent.width
              label: "All results"
              description: "Add an \"All\" tab that searches Arch, Flathub and the AUR together"
              checked: root.allEnabled
              onClicked: root.setAllEnabled(!root.allEnabled)
            }

            // AUR install helper picker.
            Item {
              width: parent.width
              implicitHeight: Style.space(30)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "AUR install uses"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.md

                HelperPill {
                  label: "yay"
                  selected: root.aurHelper === "yay"
                  onClicked: root.setAurHelper("yay")
                }
                HelperPill {
                  label: "paru"
                  selected: root.aurHelper === "paru"
                  onClicked: root.setAurHelper("paru")
                }
              }
            }

            // Says plainly that the chosen helper is not on this machine,
            // instead of letting an install button fail silently later.
            Text {
              width: parent.width
              visible: root.aurEnabled && Object.keys(root.aurHelpersInstalled).length > 0
                       && !root.aurHelperInstalled
              text: root.aurHelper + " is not installed — AUR installs will fail. Pick a helper you have, or install one."
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption - 1
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
            }

            // Design preset picker — restyles the "Find App" pill in the top
            // bar; the panel itself always uses the shell's stock look.
            Item {
              width: parent.width
              implicitHeight: Style.space(30)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Design"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.sm

                HelperPill {
                  glyph: root.icons.search
                  label: "Icon"
                  selected: root.panelDesign === "icon"
                  onClicked: root.setPanelDesign("icon")
                }
                // No glyph: the icon set has no plain circle, and inventing a
                // codepoint that may not be in the installed font renders as
                // tofu. HelperPill hides an empty glyph, so the label stands
                // on its own.
                HelperPill {
                  label: "Circle"
                  selected: root.panelDesign === "circle"
                  onClicked: root.setPanelDesign("circle")
                }
                HelperPill {
                  glyph: root.icons.box
                  label: "Text"
                  selected: root.panelDesign === "text"
                  onClicked: root.setPanelDesign("text")
                }
                HelperPill {
                  glyph: root.icons.box
                  label: "Brand"
                  selected: root.panelDesign === "brand"
                  onClicked: root.setPanelDesign("brand")
                }
                HelperPill {
                  glyph: root.icons.box
                  label: "Pill"
                  selected: root.panelDesign === "pill"
                  onClicked: root.setPanelDesign("pill")
                }
              }
            }

            // Compact tick for hiding the coffee button — no big switch, just a
            // small checkbox row.
            Item {
              width: parent.width
              implicitHeight: Style.space(22)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Buy Me a Coffee"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Rectangle {
                id: coffeeBox
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(18)
                height: Style.space(18)
                radius: Math.max(2, Style.cornerRadius - 2)
                color: root.showCoffeeButton
                  ? Style.selectedFillFor(Color.popups.text, Color.accent)
                  : (coffeeBoxMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent")
                border.width: Style.controlBorderWidth(root.showCoffeeButton, coffeeBoxMouse.containsMouse)
                border.color: Style.controlBorder(root.showCoffeeButton, coffeeBoxMouse.containsMouse, Color.popups.text, Color.accent)
                Behavior on border.color { ColorAnimation { duration: 150 } }

Icon {
                    anchors.centerIn: parent
                    text: root.icons.check
                    color: root.showCoffeeButton ? Color.accent : "transparent"
                    iconSize: Style.font.bodySmall
                  }

                MouseArea {
                  id: coffeeBoxMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setShowCoffeeButton(!root.showCoffeeButton)
                }
              }
            }

            // Buy Me a Coffee — ko-fi flavored; same button used in the mouse & keybind app.
            BorderSurface {
              id: buyButton
              visible: root.showCoffeeButton
              x: (parent.width - width) / 2
              implicitWidth: koFiImg.sourceSize.width + Style.space(10)
              implicitHeight: koFiImg.sourceSize.height + Style.space(6)
              radius: Style.cornerRadius
              color: "transparent"
              Behavior on color { ColorAnimation { duration: 150 } }

              Image {
                id: koFiImg
                anchors.centerIn: parent
                source: "https://storage.ko-fi.com/cdn/kofi5.png?v=6"
                sourceSize.width: 138
                sourceSize.height: 30
                fillMode: Image.PreserveAspectFit
                mipmap: true
                smooth: true
              }

              MouseArea {
                id: buyHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Qt.openUrlExternally("https://ko-fi.com/davedes")
              }
            }

            Text {
              width: parent.width
              visible: root.showCoffeeButton
              text: "If you find FossFetch helpful, a coffee keeps it brewing."
              color: Util.alpha(Color.popups.text, 0.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption - 1
              horizontalAlignment: Text.AlignHCenter
            }

          }
        }

        // --------------------------------------------------------- search bar
        Item {
          width: parent.width
          implicitHeight: Style.space(46)

          Rectangle {
            id: searchBox
            anchors.fill: parent
            radius: Style.cornerRadius
            color: Style.controlFill(searchField.activeFocus, searchField.hovered, Color.popups.text, Color.accent)
            border.width: Style.controlBorderWidth(searchField.activeFocus, searchField.hovered)
            border.color: Style.controlBorder(searchField.activeFocus, searchField.hovered, Color.popups.text, Color.accent)
            smooth: true

            // Soft outer glow that fades in on hover/focus, matching the
            // toolbar icon's and tabs' hover ring.
            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: "transparent"
              border.color: Util.alpha(Color.accent, 0.6)
              border.width: 2
              opacity: (searchField.hovered || searchField.activeFocus) ? 0.7 : 0
              Behavior on opacity { NumberAnimation { duration: 180 } }
            }

            Icon {
              id: icon
              text: root.icons.search
              color: Util.alpha(Color.popups.text, 0.45)
              iconSize: Style.font.title
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.xxl
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22)
            }

            TextField {
              id: searchField
              color: Color.popups.text
              placeholderText: root.tabPlaceholder()
              placeholderTextColor: Util.alpha(Color.popups.text, 0.45)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: icon.right
              anchors.leftMargin: Style.spacing.xxs
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.md
              background: null
              selectByMouse: true
              onTextChanged: root.scheduleFilter()

              // One Keys.onPressed rather than per-key handlers: Qt skips the
              // generic `pressed` signal whenever a specific key signal is
              // connected, so mixing onUpPressed with onPressed would silently
              // starve the generic branch.
              //
              // Left/Right are deliberately NOT handled — they are the text caret.
              // (They used to be hijacked for tab switching, which made it
              // impossible to edit a query in the middle.)
              //
              // Tab/Backtab/Escape are handled here because PanelKeyCatcher is
              // `blocked` whenever this field has focus, so the panel-level
              // handlers never see them.
              Keys.onPressed: function(event) {
                // The confirm dialog owns Escape / Tab / Enter while it is up.
                // It exposes handleKey() rather than grabbing focus itself, so
                // it has to be fed the event from whatever currently holds it.
                if (actionConfirm.opened) {
                  if (actionConfirm.handleKey(event)) {
                    event.accepted = true
                    return
                  }
                }
                if (event.key === Qt.Key_Escape) {
                  // Unwind one layer at a time: a live selection, then the
                  // details sheet, then the panel. Escape is the way out of
                  // everything you can be in, so it clears the least
                  // destructive thing first and only closes the panel once
                  // there is nothing left to unwind.
                  if (!root.unwindOnce()) root.close()
                  event.accepted = true
                } else if (event.key === Qt.Key_Tab) {
                  root.switchPanel(1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Backtab) {
                  root.switchPanel(-1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  // Shift extends the selection instead of just moving the
                  // cursor, the same shape as every file manager.
                  if (event.modifiers & Qt.ShiftModifier) {
                    if (filteredModel.count > 0) {
                      var ti = Math.min(resultsList.currentIndex + 1, filteredModel.count - 1)
                      resultsList.currentIndex = ti
                      root.selectRange(filteredModel.get(ti))
                    }
                  } else {
                    root.moveCursor(0, 1)
                  }
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  if (event.modifiers & Qt.ShiftModifier) {
                    if (filteredModel.count > 0) {
                      var tu = Math.max(resultsList.currentIndex - 1, 0)
                      resultsList.currentIndex = tu
                      root.selectRange(filteredModel.get(tu))
                    }
                  } else {
                    root.moveCursor(0, -1)
                  }
                  event.accepted = true
                } else if (event.key === Qt.Key_Space) {
                  // Toggle the highlighted row and step down, so a run of
                  // packages can be marked without leaving the home row --
                  // otherwise reaching the tenth row to select it is nine
                  // extra presses of down-arrow.
                  var ci = resultsList.currentIndex
                  if (ci >= 0 && ci < filteredModel.count) {
                    root.toggleSelect(filteredModel.get(ci))
                    if (ci < filteredModel.count - 1) {
                      resultsList.currentIndex = ci + 1
                      root.selectionAnchor = ""
                    }
                  }
                  event.accepted = true
                } else if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier)) {
                  root.selectAll()
                  event.accepted = true
                } else if (event.key === Qt.Key_F2) {
                  // Look before you commit. Enter installs; F2 opens the details
                  // sheet for the highlighted row.
                  //
                  // F2 only, deliberately. SUPER+CTRL+SHIFT+F also opens this
                  // panel, and Hyprland consumes a bound combo before the
                  // focused client ever sees it -- so binding it here too would
                  // have been dead code that still read as a working shortcut,
                  // and pressing it inside the panel would toggle the panel
                  // shut instead of opening anything.
                  root.openDetailsCursor()
                  event.accepted = true
                } else if (event.key === Qt.Key_S && (event.modifiers & Qt.ControlModifier)) {
                  // Cycle the result sort. Ctrl rather than a bare key because
                  // the field owns focus: an unmodified S is a letter to type.
                  // Shown in the sort row's own label, which is where the
                  // control and its hint sit together.
                  if (root.isLive) root.cycleSort()
                  event.accepted = true
                } else if (event.key === Qt.Key_H && (event.modifiers & Qt.ControlModifier)) {
                  // Hide / show packages already installed.
                  if (root.isLive) root.setHideInstalled(!root.hideInstalled)
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.activateCursor()
                  event.accepted = true
                }
              }
            }
          }
        }

        // ------------------------------------------------------- sort & filter row
        // Only shown once there is something to sort. It sits directly above the
        // results so the control and the thing it controls are adjacent, and it
        // names its own shortcut in the label rather than adding two more items
        // to the hint footer (which is already at the limit of this panel's
        // width).
        //
        // Both controls are live only on the search tabs. The Updates tab is a
        // scan result set, not a search result set: its order comes from the
        // scan and "hide installed" would empty it entirely.
        Item {
          id: sortBar
          width: parent.width
          implicitHeight: Style.space(24)
          visible: resultsList.count > 0 && root.isLive

          Text {
            id: sortLabel
            anchors.left: parent.left
            anchors.right: sortPills.left
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            text: "Sort: " + root.sortLabelFor() + "  (Ctrl+S)"
            color: sortLabelMouse.containsMouse ? Color.accent : Util.alpha(Color.popups.text, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            textFormat: Text.PlainText
            Behavior on color { ColorAnimation { duration: 120 } }

            MouseArea {
              id: sortLabelMouse
              anchors.fill: parent
              anchors.leftMargin: -Style.space(6)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.cycleSort()
            }
          }

          Row {
            id: sortPills
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            HelperPill {
              label: "Ctrl+S"
              onClicked: root.cycleSort()
            }
            HelperPill {
              label: root.hideInstalled ? "Show installed" : "Hide installed"
              selected: root.hideInstalled
              onClicked: root.setHideInstalled(!root.hideInstalled)
            }
          }
        }

        // Batch action bar. Only exists while something is marked, so the
        // panel does not spend a permanent row on controls that have nothing
        // to act on -- and appearing the instant you press Space means the
        // count and the buttons are already there when you look up to check
        // what you marked.
        Item {
          id: batchBar
          width: parent.width
          implicitHeight: root.selectedCount > 0 ? Style.space(26) : 0
          visible: root.selectedCount > 0

          Behavior on implicitHeight {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
          }

          Text {
            id: batchCount
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.selectedCount + " selected"
            color: Util.alpha(Color.popups.text, 0.7)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            // Install and Remove are offered only when the selection actually
            // contains something they can act on. A bar whose buttons do
            // nothing reads as a broken button, and the "none of the selected
            // packages can be ..." notice that would otherwise explain it
            // arrives one keystroke too late.
            ActionPill {
              label: "Install selected"
              visible: root.batchGroups("install").length > 0 && !root.batchRunning
              onClicked: root.startBatch("install")
            }
            ActionPill {
              label: "Update selected"
              visible: root.batchGroups("update").length > 0 && !root.batchRunning
              onClicked: root.startBatch("update")
            }
            ActionPill {
              label: "Remove selected"
              // Removal stays the one action that always asks first, exactly
              // as the single-row Remove button does.
              visible: root.batchGroups("remove").length > 0 && !root.batchRunning
              destructive: true
              onClicked: root.startBatch("remove")
            }
            HelperPill {
              label: "Clear"
              onClicked: root.clearSelection()
            }
            HelperPill {
              label: root.batchRunning ? "Working…"
                : (root.batchArmed ? "Confirm to run" : "Space Select")
              enabled: !root.batchRunning
            }
          }
        }

        // ----------------------------------------------------------- results
        Item {
          width: parent.width
          implicitHeight: root.fitResultsHeight(resultsList.count) + Style.space(12)
          visible: resultsList.count > 0

          ListView {
            id: resultsList
            anchors.fill: parent
            clip: true
            spacing: Style.spacing.md
            model: filteredModel
            currentIndex: -1
            focus: false


            // Without this the panel scrolls silently: three cards are visible
            // and up to sixty exist, with no cue that the list continues.
            QC.ScrollBar.vertical: QC.ScrollBar {
              id: resultsScroll
              policy: QC.ScrollBar.AsNeeded
              width: Style.spacing.sm
            }

            delegate: Rectangle {
              id: delegateRoot
              // Declared, not left to the implicit delegate injection. The
              // check state is resolved by index (see isSelectedRowAt), and an
              // unresolved `index` there is a ReferenceError on every rebind --
              // which surfaces as cards that quietly stop showing as checked
              // rather than as an error anyone would notice.
              required property int index
              required property string name
              required property string description
              required property string website
              required property string thumbnail
              required property string iconName
              required property string pacmanPkg
              required property string aurPkg
              required property string flatpakPkg
              // Every model row now carries the full role set (see addRow), so
              // these must be `required` for the delegate to bind to the model
              // roles. A non-required property would NOT be auto-bound to its
              // role and would stay at its default "" forever, hiding the
              // live-scraped metadata.
              required property string repo
              required property string version
              required property string arch
              required property string licenses
              required property string updated
              // "1" when this row's pacman package / flatpak app id is already
              // installed. Stamped by addRow() and refreshed by the installed
              // snapshot, so a row is correct the moment it appears.
              required property string installedPacman
              required property string installedAur
              required property string installedFlatpak
              // AUR trust signals (empty on every other source).
              required property string aurVotes
              required property string aurMaintainer
              required property string aurOutdated
              required property string aurPopularity
              // "Downloaded: 12.4 MiB" straight from `pacman -Si`.
              required property string downloadSize
              // Dependency graph + installed footprint for the details sheet.
              required property string installedSize
              required property string dependsOn
              required property string optionalDeps
              required property string requiredBy
              required property string conflictsWith
              required property string provides
              required property string groups
              required property string packager
              required property string branch
              required property string collection
              // `rating`, `license`, `category` and `_pkg` stay in the model
              // (and the async writers resolve
              // rows by _pkg through filteredModel.get(), not through a
              // delegate binding) but are deliberately not declared here: a
              // delegate only needs a role it actually draws.

              // Cursor and selection are drawn as two different things rather
              // than one: a checked row is filled and outlined (it is queued
              // for a batch action), while the cursor row additionally carries
              // a hairline ring (it is merely where the next keystroke lands).
              // Overloading a single "selected" state would make the keyboard
              // cursor invisible the moment anything was checked, and adding a
              // checkbox column would slide every card sideways at the instant
              // the user started marking them.
              readonly property bool isCursor: ListView.isCurrentItem
              readonly property bool isChecked: root.isSelectedRowAt(index)
              readonly property bool isSelected: isCursor
              readonly property bool isHovered: cardHover.hovered

              // Background-only hover, beneath the interactive controls.
              HoverHandler {
                id: cardHover
              }

              width: resultsList.width
              height: root.cardHeight
              radius: Style.cornerRadius
              // Never let any child paint outside the card bounds, no matter
              // how long a name/description/button label gets.
              clip: true
              color: isChecked
                ? Util.alpha(Color.accent, 0.14)
                : (isHovered ? Util.alpha(Color.popups.text, 0.05) : "transparent")
              border.width: isChecked
                ? Border.uniformWidth(root.selectedBorderSpec)
                : (isCursor ? 1 : 0)
              border.color: isChecked
                ? Border.color(root.selectedBorderSpec)
                : (isCursor ? Util.alpha(Color.accent, 0.5) : "transparent")

              // Source rail: a 2px bar in the tab's own colour. Scannable
              // before a single word is read, and it costs the card two pixels
              // of width rather than another outline.
              Rectangle {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.xxs
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(2)
                height: parent.height - Style.space(18)
                radius: width / 2
                color: root.rowSourceColor(delegateRoot)
                opacity: isSelected || isHovered ? 1 : 0.55
                Behavior on opacity { NumberAnimation { duration: 120 } }
              }

              // Soft accent ring around the selected card — a nested overlay so
              // it draws on top of the fill but beneath the row content.
              Rectangle {
                anchors.fill: parent
                anchors.margins: Style.spacing.hairline
                radius: Math.max(2, Style.cornerRadius - Style.space(1))
                color: "transparent"
                border.width: 1.5
                border.color: Util.alpha(Color.accent, delegateRoot.isSelected ? 0.55 : 0)
                Behavior on border.color { ColorAnimation { duration: 150 } }
              }

              RowLayout {
                id: delegateRow
                anchors.fill: parent
                anchors.margins: Style.spacing.xl
                spacing: 0

                Item {
                  id: thumbWrap
                  Layout.preferredWidth: 52
                  Layout.preferredHeight: 52
                  Layout.alignment: Qt.AlignTop
                  Layout.topMargin: Style.spacing.xxs

                  // No border. A 1px outline around every app icon, on top of
                  // the outline the card already had, was most of the "form
                  // field" texture; the tinted tile carries the shape on its own.
                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: Util.alpha(root.rowSourceColor(delegateRoot), 0.14)
                  }

                  Text {
                    anchors.centerIn: parent
                    text: delegateRoot.name.charAt(0).toUpperCase()
                    color: Util.alpha(root.rowSourceColor(delegateRoot), 0.85)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.icon
                    font.bold: true
                    textFormat: Text.PlainText
                    visible: img.status !== Image.Ready
                  }

                  Image {
                    id: img
                    anchors.fill: parent
                    anchors.margins: Style.spacing.md
                    source: root.resolveThumb(delegateRoot.thumbnail, delegateRoot.iconName)
                    fillMode: Image.PreserveAspectFit
                    antialiasing: true
                    cache: true
                  }
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.leftMargin: Style.spacing.xl
                  spacing: Style.spacing.sm

                  // Row 1: Name (left) + Open Web/GitHub button (right)
                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.spacing.lg

                    FitText {
                      // The ONLY rich-text sink in the panel; the string is
                      // fully escaped in highlightName() before the one <font>
                      // tag we add ourselves.
                      textFormat: Text.RichText
                      text: root.highlightName(delegateRoot.name)
                      color: delegateRoot.isSelected ? Color.accent : Color.popups.text
                      baseSize: Style.font.title
                      minSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 0.5
                      Layout.fillWidth: true
                      // A long name must be allowed to shrink so the row never
                      // forces itself wider than the card — FitText shrinks the
                      // font to fit and only elides as a last resort.
                      Layout.minimumWidth: 0
                    }

                    // Opens the details sheet: dependency graph, installed
                    // footprint, and why this row matched at all.
                    Button {
                      id: detailsButton
                      visible: true
                      focusable: false
                      text: ""
                      iconText: root.icons.info
                      // Nerd Font, not the UI font: the shell's Button renders
                      // iconText with whatever family it is handed, and a
                      // Material Design glyph drawn in a text face is tofu.
                      fontFamily: Style.font.resolvedFamily
                      // One step below the label size: icons set to the same
                      // size as text always look like a sticker on top of it.
                      iconSize: Style.font.caption - 1
                      foreground: Util.alpha(Color.popups.text, 0.55)
                      fontSize: Style.font.caption
                      tooltipText: "Why this matched, and what it would install"
                      bordered: false
                      Layout.preferredHeight: Style.space(24)
                      Layout.minimumWidth: 0
                      onClicked: root.openDetails(delegateRoot)
                    }

                    Button {
                      id: webButton
                      visible: delegateRoot.website !== ""
                      focusable: false
                      text: ""
                      iconText: root.icons.external
                      fontFamily: Style.font.resolvedFamily
                      iconSize: Style.font.caption - 1
                      foreground: Util.alpha(root.pacmanColor, 0.75)
                      fontSize: Style.font.caption
                      tooltipText: String(delegateRoot.website).indexOf("github") !== -1
                        ? "Open the GitHub project"
                        : "Open the project website"
                      bordered: false
                      Layout.preferredHeight: Style.space(24)
                      Layout.minimumWidth: 0
                      onClicked: { if (root.isSafeWebUrl(delegateRoot.website)) Qt.openUrlExternally(delegateRoot.website) }
                    }
                  }

                  // Row 2: Description, capped at two lines and elided.
                  // The full text is one click away in the details sheet; a
                  // three-line cut mid-sentence on every row is noise, and a
                  // scrollable description inside a list row is worse.
                  Text {
                    id: cardDescription
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: Style.space(6)
                    Layout.minimumWidth: 0
                    text: delegateRoot.description || ""
                    color: Util.alpha(Color.popups.text, 0.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignTop
                  }

                  // Row 3: metadata as chips. Each one sizes to its own
                  // content, so a long licence wraps onto the next row instead
                  // of being elided to "extra…" the way a single shared text
                  // line always did.
                  Flow {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.spacing.xxs
                    Layout.minimumWidth: 0
                    spacing: Style.spacing.xs

                    Repeater {
                      model: root.cardChips(delegateRoot)

                      delegate: MetaChip {
                        required property var modelData
                        label: modelData.label
                        value: modelData.value
                        highlight: modelData.label === "Update"
                      }
                    }
                  }

                  // Row 4: Install buttons (bottom-right of the card)
                  RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.spacing.xxs
                    spacing: Style.spacing.lg

                    // Download size for the distro package — the one number
                    // people actually weigh before installing.
                    Text {
                      Layout.alignment: Qt.AlignVCenter
                      visible: delegateRoot.downloadSize !== ""
                      text: delegateRoot.downloadSize
                      color: Util.alpha(Color.popups.text, 0.55)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
                      Layout.leftMargin: Style.spacing.xs
                    }

                    // AUR trust signal: flagged out of date, or so thinly
                    // voted that a second look is warranted.
                    Text {
                      Layout.alignment: Qt.AlignVCenter
                      visible: root.trustLabel(delegateRoot) !== ""
                      text: root.trustLabel(delegateRoot)
                      color: root.trustColor(delegateRoot)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      textFormat: Text.PlainText
                    }

                    // Already on the machine — said plainly, so a re-install is
                    // never a surprise.
                    RowLayout {
                      Layout.alignment: Qt.AlignVCenter
                      spacing: Style.spacing.sm
                      visible: delegateRoot.installedPacman === "1"
                             || delegateRoot.installedAur === "1"
                             || delegateRoot.installedFlatpak === "1"

                      Icon {
                        text: root.icons.check
                        color: root.pacmanColor
                        iconSize: Style.font.caption
                      }
                      Text {
                        text: "Installed"
                        color: root.pacmanColor
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        textFormat: Text.PlainText
                      }
                    }

                    // Flexible spacer pushes the install buttons to the right.
                    Item { Layout.fillWidth: true }

                    // One update control per card, driven by the newest update
                    // across all of the row's sources. It is invisible until an
                    // update genuinely exists, so a fully-updated system looks
                    // exactly as it did before this feature.
                    UpdateButton {
                      readonly property var upd: root.updateSpecFor(delegateRoot)
                      visible: upd !== null
                      packageName: upd ? upd.pkg : ""
                      version: upd ? upd.to : ""
                      isPending: upd ? root.updatePending(upd.kind, upd.pkg) : false
                      onArmed: root.startUpdate(upd.kind, upd.pkg, upd.name, upd.from, upd.to)
                    }

                    InstallButton {
                      visible: !root.isUpdates && (root.isPacman || root.isAll) && delegateRoot.pacmanPkg !== ""
                      installKind: "pacman"
                      packageName: delegateRoot.pacmanPkg
                      installed: delegateRoot.installedPacman === "1"
                      isPending: root.installPending("pacman", delegateRoot.pacmanPkg)
                      onArmed: root.startInstall("pacman", delegateRoot.pacmanPkg, delegateRoot.name)
                      onRemoved: root.startRemove("pacman", delegateRoot.pacmanPkg, delegateRoot.name)
                    }

                    InstallButton {
                      visible: !root.isUpdates && (root.isPacman || root.isAur || root.isAll) && delegateRoot.aurPkg !== "" && root.aurHelper === "yay"
                      installKind: "yay"
                      packageName: delegateRoot.aurPkg
                      unavailable: !root.aurHelperInstalled
                      installed: delegateRoot.installedAur === "1"
                      isPending: root.installPending("yay", delegateRoot.aurPkg)
                      onArmed: root.startInstall("yay", delegateRoot.aurPkg, delegateRoot.name)
                      onRemoved: root.startRemove("yay", delegateRoot.aurPkg, delegateRoot.name)
                    }

                    InstallButton {
                      visible: !root.isUpdates && (root.isPacman || root.isAur || root.isAll) && delegateRoot.aurPkg !== "" && root.aurHelper === "paru"
                      installKind: "paru"
                      packageName: delegateRoot.aurPkg
                      unavailable: !root.aurHelperInstalled
                      installed: delegateRoot.installedAur === "1"
                      isPending: root.installPending("paru", delegateRoot.aurPkg)
                      onArmed: root.startInstall("paru", delegateRoot.aurPkg, delegateRoot.name)
                      onRemoved: root.startRemove("paru", delegateRoot.aurPkg, delegateRoot.name)
                    }

                    // Shown whenever the row carries a Flathub app id — not just
                    // on the Flatpak tab. Pacman and AUR rows get one attached
                    // by the Flathub-equivalent pass, so a single card can offer
                    // the distro package AND its Flathub equivalent.
                    InstallButton {
                      visible: !root.isUpdates && delegateRoot.flatpakPkg !== ""
                      installKind: "flatpak"
                      packageName: delegateRoot.flatpakPkg
                      installed: delegateRoot.installedFlatpak === "1"
                      isPending: root.installPending("flatpak", delegateRoot.flatpakPkg)
                      onArmed: root.startInstall("flatpak", delegateRoot.flatpakPkg, delegateRoot.name)
                      onRemoved: root.startRemove("flatpak", delegateRoot.flatpakPkg, delegateRoot.name)
                    }
                  }
                }
              }
            }
          }
        }


        // ---------------------------------------------------- recent searches
        // Only meaningful when nothing is typed: a live tab shows its own
        // results, so recents fill otherwise-empty space.
        Item {
          width: parent.width
          visible: root.recentSearches.length > 0 && searchField.text.trim() === ""
          implicitHeight: visible ? recentCol.implicitHeight + Style.space(12) : 0

          Column {
            id: recentCol
            width: parent.width
            spacing: Style.spacing.sm

            RowLayout {
              width: parent.width
              Text {
                text: "Recent"
                color: Util.alpha(Color.popups.text, 0.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.0
                textFormat: Text.PlainText
                Layout.fillWidth: true
              }
              Text {
                text: "Clear"
                color: clearRecentMouse.containsMouse ? Color.accent : Util.alpha(Color.popups.text, 0.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                textFormat: Text.PlainText
                MouseArea {
                  id: clearRecentMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.clearRecents()
                }
              }
            }

            Flow {
              width: parent.width
              spacing: Style.spacing.md

              Repeater {
                model: root.recentSearches
                delegate: Rectangle {
                  required property string modelData
                  implicitWidth: recentText.implicitWidth + Style.space(16)
                  implicitHeight: Style.space(24)
                  radius: Style.cornerRadius
                  // Borderless at rest. These are shortcuts, not actions -
                  // eight permanent outlines in the empty state was most of
                  // the "beginner" texture of the panel.
                  color: recentChipMouse.containsMouse
                    ? Util.alpha(Color.popups.text, 0.11)
                    : Util.alpha(Color.popups.text, 0.045)
                  Behavior on color { ColorAnimation { duration: 120 } }

                  Text {
                    id: recentText
                    anchors.centerIn: parent
                    text: modelData
                    color: recentChipMouse.containsMouse ? Color.accent : Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                    Behavior on color { ColorAnimation { duration: 120 } }
                  }

                  MouseArea {
                    id: recentChipMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      searchField.text = modelData
                      root.refocus()
                    }
                  }
                }
              }
            }
          }
        }

        // ------------------------------------------------------- empty states
        Item {
          width: parent.width
          implicitHeight: 120
          visible: resultsList.count === 0

          Item {
            anchors.fill: parent

            Column {
              anchors.centerIn: parent
              spacing: Style.spacing.md

              Text {
                // A search that matched only installed packages is not a failed
                // search, so it must not borrow the "No packages found" wording
                // — that tells the user to retype something that worked fine.
                text: root.query === ""
                    ? "Search " + (root.isAll ? "pacman, Flathub and the AUR"
                      : root.isPacman ? "an Arch package"
                      : root.isFlatpak ? "a Flatpak app" : "an AUR package")
                    : root.tabError() !== ""
                      ? "Lookup failed"
                      : root.hiddenInstalled > 0
                        ? "Already installed"
                        : "No " + (root.isPacman || root.isAur ? "packages" : "apps") + " found"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
              }

              Text {
                text: root.warmingLabel() !== ""
                  ? root.warmingLabel()
                  : root.query === ""
                      ? "e.g. gimp, chromecast, vscode, obs, libreoffice"
                      : root.tabError() !== ""
                        ? root.tabError()
                        : root.hiddenInstalled > 0
                          ? root.hiddenInstalled + (root.hiddenInstalled === 1
                              ? " match is already installed — Ctrl+H to show it"
                              : " matches are already installed — Ctrl+H to show them")
                          : "Try a different name"
                color: root.tabError() !== "" ? Color.urgent : Util.alpha(Color.popups.text, 0.5)
                horizontalAlignment: Text.AlignHCenter
                width: Math.min(implicitWidth, parent.width)
                wrapMode: Text.WordWrap
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
              }
            }
          }
        }

        // ------------------------------------------------------ keyboard hints
        // A thin footer naming the keys the panel actually binds. The panel is
        // keyboard-first - Enter installs, Tab cycles sources, F2 looks before
        // committing - but nothing on screen said so, and the only way to
        // discover F2 was to read the source. Deliberately the lowest-contrast
        // element in the panel: it must inform without competing with results.
        RowLayout {
          width: parent.width
          spacing: Style.spacing.lg
          visible: resultsList.count > 0

          Hint { keys: "\u2191\u2193"; label: "Move" }
          Hint { keys: "\u2423"; label: root.selectedCount > 0 ? (root.selectedCount + " marked") : "Select" }
          Hint { keys: "\u21b5"; label: root.selectedCount > 0 ? "Batch" : (root.isUpdates ? "Update" : "Install") }
          Hint { keys: "F2"; label: "Details" }
          Item { Layout.fillWidth: true }
          Hint { keys: "Tab"; label: "Source" }
          Hint { keys: "Esc"; label: root.selectedCount > 0 ? "Clear" : "Close" }
        }
      }
    }
  }

  // ------------------------------------------------------- details sheet
  // A separate PopupCard rather than an inline expansion: the results list has
  // a fixed three-row viewport, so growing a card would either overflow the
  // panel or force the whole layout to be recomputed mid-interaction.
  PopupCard {
    id: detailsSheet
    anchorItem: panel.anchorItem
    bar: root.bar
    owner: root.barIdentity
    // Centred on the bar, like the panel it belongs to.
    //
    // Without this the card anchors BELOW its anchor item -- and that item is
    // the toolbar button, which sits at the far left of the bar. The sheet
    // therefore opened in the top-left corner, under a button, while the
    // panel it describes was centred in the middle of the screen: the same
    // information, in two places at once, one of them nowhere near the rows
    // the user pressed F2 on.
    centerOnBar: true
    triggerMode: "click"
    contentWidth: detailsSheet.fittedContentWidth(Style.space(440), Style.space(440))
    // Sized to its content, then capped: the card should not carry a large
    // empty area under a short fact list, and must still scroll rather than
    // clip when the list is long. detailsCol.implicitHeight is independent of
    // the Flickable's own height, so this does not feed back on itself.
    contentHeight: detailsSheet.cappedContentHeight(
      detailsCol.implicitHeight
      + detailsHeader.implicitHeight
      + detailsReason.implicitHeight
      + Style.spacing.sm * 2 + Style.spacing.lg)

    Column {
      id: detailsOuter
      anchors.fill: parent
      spacing: Style.spacing.sm

      // Pinned header: the package name and the close button stay readable
      // however far the fact list below is scrolled.
      RowLayout {
        id: detailsHeader
        width: parent.width
        Layout.fillWidth: true

        Text {
          text: root.detailRow ? root.detailRow.name : ""
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
          textFormat: Text.PlainText
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          elide: Text.ElideRight
        }
        Button {
          focusable: false
          text: "\u2715"
          foreground: Color.popups.text
          fontFamily: Style.font.family
          fontSize: Style.font.caption
          onClicked: root.closeDetails()
        }
      }

      Text {
        id: detailsReason
        width: parent.width
        text: root.detailRow ? root.matchReason(root.detailRow.name) : ""
        color: Util.alpha(Color.popups.text, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      Flickable {
        id: detailsFlick
        width: parent.width
        Layout.fillWidth: true
        // Takes whatever is left under the pinned header.
        height: Math.max(0, parent.height - y)
        contentWidth: width
        contentHeight: detailsCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        QC.ScrollBar.vertical: QC.ScrollBar {
          policy: QC.ScrollBar.AsNeeded
          width: Style.spacing.sm
        }

        Column {
          id: detailsCol
          width: detailsFlick.width
          spacing: Style.spacing.md

          Repeater {
            model: root.detailRow ? root.sheetFacts(root.detailRow) : []
            delegate: Column {
              required property var modelData
              width: detailsCol.width
              spacing: Style.spacing.xxs
              // A label with no value carries no information - hide the pair
              // rather than leaving a dangling heading.
              visible: String(modelData.value) !== ""
                    && String(modelData.value) !== "None"

              Text {
                width: parent.width
                text: modelData.label
                color: Util.alpha(Color.popups.text, 0.45)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 1
                font.bold: true
                font.letterSpacing: 0.6
                textFormat: Text.PlainText
              }
              Text {
                width: parent.width
                text: modelData.value
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
              }
            }
          }
        }
      }
    }
  }

  // debounced query apply
  property string pendingQuery: query
  Timer {
    id: searchDebounce
    interval: root.debounceMs
    repeat: false
    onTriggered: {
      root.query = root.pendingQuery
      root.rebuildResults()
    }
  }

  function scheduleFilter() {
    pendingQuery = searchField.text
    searchDebounce.start()
    // Restarted on every keystroke, so it only elapses once the user stops.
    root.noteSearch(pendingQuery, !root.suppressRecentSettle)
  }

  //                                                         small install button
  // Single-line label that shrinks its font to fit whatever width it's given.
  // A plain Text cannot do this: its implicitWidth stays at the full-text size,
  // which forces any RowLayout/ColumnLayout it lives in wider than the card
  // (the root cause of everything running past the popup edge). FitText keeps
  // its width bounded by the layout (`Layout.minimumWidth: 0` on the caller)
  // and steps the pixel size down until the text actually fits its allotted
  // width, falling back to elide below the floor.
  component FitText: Text {
    id: ft
    property real fitWidth: 0  // 0 = use this item's own width
    property real baseSize: Style.font.caption
    property real minSize: Style.font.bodySmall
    property bool fitElide: true
    property int elideMode: Text.ElideRight
    // Guard against re-entrancy while stepping the font size.
    property bool _stepping: false

    // Sinks render repository/package metadata (names, AUR fields, install
    // labels) — always literal, never rich-text HTML from remote sources.
    textFormat: Text.PlainText

    font.family: Style.font.family
    font.pixelSize: ft.baseSize
    wrapMode: Text.NoWrap
    verticalAlignment: Text.AlignVCenter

    onFitWidthChanged: if (!ft._stepping) ft.applyFit()
    onBaseSizeChanged: if (!ft._stepping) ft.applyFit()
    onWidthChanged: if (ft.fitWidth === 0 && !ft._stepping) ft.applyFit()
    onTextChanged: if (!ft._stepping) Qt.callLater(ft.applyFit)

    Component.onCompleted: ft.applyFit()

    function applyFit() {
      if (ft._stepping) return
      var w = ft.fitWidth > 0 ? ft.fitWidth : ft.width
      if (w <= 0) return
      ft._stepping = true
      var s = ft.baseSize
      ft.font.pixelSize = s
      while (s > ft.minSize && implicitWidth > w) {
        s = Math.max(ft.minSize, s - 0.5)
        ft.font.pixelSize = s
      }
      ft.elide = (ft.fitElide && implicitWidth > w) ? ft.elideMode : Text.ElideNone
      ft._stepping = false
    }
  }

  // Label and value on one line, sized to whatever they actually are. This is
  // the component that makes "Repo: extra…" impossible: a chip cannot be
  // squeezed, it wraps onto the next row instead.
  component MetaChip: Rectangle {
    id: chip
    property string label: ""
    property string value: ""
    // Chips are neutral by default — they are facts, not prompts. The Update
    // chip opts into the confirm tint so the one fact on the card that changes
    // what you would DO about it is the one that stands out.
    property bool highlight: false

    implicitHeight: Style.space(20)
    implicitWidth: chipRow.implicitWidth + Style.space(10)
    radius: Math.max(2, Style.cornerRadius - Style.space(1))
    color: chip.highlight ? Util.alpha(root.confirmColor, 0.14) : Util.alpha(Color.popups.text, 0.055)

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.spacing.xs

      Text {
        text: chip.label
        color: chip.highlight ? Util.alpha(root.confirmColor, 0.55) : Util.alpha(Color.popups.text, 0.42)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 0.4
        textFormat: Text.PlainText
        anchors.bottom: parent.bottom
      }
      Text {
        text: chip.value
        color: chip.highlight ? root.confirmColor : Util.alpha(Color.popups.text, 0.82)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        textFormat: Text.PlainText
        anchors.bottom: parent.bottom
      }
    }
  }

  // One key + its meaning, for the footer hint row. Declared at the root level
  // alongside MetaChip/InstallButton rather than inside the row itself: an
  // inline component declared inside a nested object silently fails to
  // instantiate there, which took the whole panel down with it.
  component Hint: RowLayout {
    id: hint
    property string keys: ""
    property string label: ""
    spacing: Style.spacing.xxs
    Text {
      text: hint.keys
      color: Util.alpha(Color.popups.text, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      textFormat: Text.PlainText
    }
    Text {
      text: hint.label
      color: Util.alpha(Color.popups.text, 0.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
    }
  }

  component HelperPill: Rectangle {
    id: pill
    property string label: ""
    property string glyph: ""
    property bool selected: false
    signal clicked()

    implicitHeight: Style.space(24)
    radius: Style.cornerRadius
    color: pill.selected
      ? Style.selectedFillFor(Color.popups.text, Color.accent)
      : (pillMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent")
    border.width: Style.controlBorderWidth(false, pillMouse.containsMouse)
    border.color: Style.controlBorder(false, pillMouse.containsMouse, Color.popups.text, Color.accent)

    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: Style.spacing.sm

      Icon {
        text: pill.glyph
        visible: pill.glyph !== ""
        color: pill.selected ? Color.accent : Color.popups.text
        iconSize: Style.font.caption
        Layout.preferredWidth: pill.glyph !== "" ? Style.space(12) : 0
        Layout.alignment: Qt.AlignVCenter
        Behavior on color { ColorAnimation { duration: 120 } }
      }
      Text {
        id: pillLab
        text: pill.label
        color: pill.selected ? Color.accent : Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: pill.selected
        textFormat: Text.PlainText
      }
    }

    implicitWidth: pillRow.implicitWidth + Style.space(14)

    MouseArea {
      id: pillMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.clicked()
    }
  }

  // A pill that DOES something, so it is drawn filled rather than as a hint.
  //
  // Distinct from HelperPill on purpose: HelperPill is chrome you can read
  // (a keybinding, the current sort), while these commit package operations.
  // Removing a selection is marked destructive so it never reads as a peer of
  // Install at a glance.
  component ActionPill: Rectangle {
    id: act
    property string label: ""
    property bool destructive: false
    property bool selected: false
    signal clicked()

    implicitHeight: Style.space(24)
    radius: Style.cornerRadius
    // confirmColor, not a red: the shell's Color object has no error token, and
    // this codebase already signals "this one is the dangerous control" with
    // it on the single-row buttons and the confirm dialog. Matching them keeps
    // one visual language for destruction instead of two.
    readonly property color tone: act.destructive ? root.confirmColor : Color.accent
    color: act.selected
      ? Util.alpha(act.tone, 0.22)
      : (actMouse.containsMouse ? Util.alpha(act.tone, 0.16) : Util.alpha(Color.popups.text, 0.07))
    border.width: Style.space(1)
    border.color: Util.alpha(act.tone, actMouse.containsMouse ? 0.55 : 0.3)

    Text {
      anchors.centerIn: parent
      text: act.label
      color: act.tone
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      textFormat: Text.PlainText
    }

    implicitWidth: Math.max(implicitHeight, contentText.implicitWidth + Style.space(16))

    Text {
      id: contentText
      visible: false
      text: act.label
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    MouseArea {
      id: actMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: act.clicked()
    }
  }

  component InstallButton: Item {
    id: btn
    property string installKind: ""
    property string packageName: ""
    property bool isPending: false
    // Already installed. This does NOT disable the button — it turns it into
    // the matching removal action, so the same control both installs and
    // removes and the user never has to hunt for a separate "uninstall" path.
    property bool installed: false
    // Its command cannot run on this machine (no AUR helper). Inert, and
    // labelled so the failure is visible before it happens.
    property bool unavailable: false
    readonly property bool actionable: !btn.unavailable

    signal armed()
    signal removed()

    // Fixed-width pill: labels self-size and FitText shrinks the font to fit,
    // so a long AUR package name can never shove the button past the card edge
    // or inflate the row's minimum width.
    implicitWidth: Style.space(118)
    implicitHeight: Style.space(26)

    function label() {
      if (btn.installed) return "Remove"
      if (btn.isPending) return "Confirm?"
      if (btn.unavailable) return installKind + " missing"
      return btn.installKind + " (" + btn.packageName + ")"
    }

    // Removal always wears the urgent colour: it is the one action here that
    // takes something away, and it should never be mistaken for an install.
    function branchColor() {
      if (btn.installed) return Color.urgent
      if (btn.unavailable) return Color.urgent
      if (installKind === "pacman") return root.pacmanColor
      if (installKind === "yay" || installKind === "paru") return root.aurColor
      return root.flatpakColor
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      // The one filled control on the card. Install/Remove is what the user
      // came here to do; Details and Web are lookups. Giving all three the same
      // outline is what made the card read as three equal buttons.
      color: btn.isPending
        ? Util.alpha(root.confirmColor, 0.28)
        : !btn.actionable
          ? Util.alpha(Color.popups.text, 0.04)
          : (mouse.containsMouse ? Util.alpha(btn.branchColor(), 0.32) : Util.alpha(btn.branchColor(), 0.16))
      border.width: Style.spacing.hairline
      border.color: btn.isPending
        ? root.confirmColor
        : (mouse.containsMouse ? Util.alpha(btn.branchColor(), 0.9) : Util.alpha(btn.branchColor(), 0.55))

      Behavior on border.color { ColorAnimation { duration: 150 } }

      // Icon + label, with the label still free to shrink. A download arrow on
      // install and a bin on remove means the two states of this one control no
      // longer differ by a word alone.
      // No glyph. The label already says "Remove" or "pacman (gimp)", and a
      // 10px pictogram beside 10px text in a 26px pill turned into visual mud.
      // Weight comes from the fill and the source colour instead.
      FitText {
        id: label
        anchors.fill: parent
        anchors.margins: Style.spacing.xs
        text: btn.label()
        color: btn.isPending ? root.confirmColor
          : !btn.actionable ? Util.alpha(btn.branchColor(), 0.8)
            : (mouse.containsMouse ? btn.branchColor() : Color.popups.text)
        baseSize: Style.font.caption
        minSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        elideMode: Text.ElideMiddle
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      enabled: btn.actionable
      hoverEnabled: true
      cursorShape: btn.actionable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: {
        if (btn.installed) btn.removed()
        else btn.armed()
      }
    }
  }

  // A card can offer an update alongside its install/remove control: the
  // package is installed, and the version in the repo has moved on. It sits as
  // its OWN control rather than overloading InstallButton's label, because
  // "Update" and "Remove" are opposites and a single button that means both
  // depending on hidden state is exactly the kind of ambiguity the card
  // redesign removed. Compact, and in the confirm colour so an available update
  // is the thing your eye lands on.
  component UpdateButton: Item {
    id: ub
    property string packageName: ""
    property string version: ""
    property bool isPending: false

    signal armed()

    implicitWidth: Style.space(78)
    implicitHeight: Style.space(26)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: ub.isPending
        ? Util.alpha(root.confirmColor, 0.28)
        : (mouse.containsMouse ? Util.alpha(root.confirmColor, 0.30) : Util.alpha(root.confirmColor, 0.15))
      border.width: Style.spacing.hairline
      border.color: ub.isPending
        ? root.confirmColor
        : (mouse.containsMouse ? Util.alpha(root.confirmColor, 0.9) : Util.alpha(root.confirmColor, 0.55))

      Behavior on border.color { ColorAnimation { duration: 150 } }

      FitText {
        anchors.fill: parent
        anchors.margins: Style.spacing.xs
        text: ub.isPending ? "Confirm?" : "Update"
        color: ub.isPending || mouse.containsMouse ? root.confirmColor : Color.popups.text
        baseSize: Style.font.caption
        minSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        elideMode: Text.ElideMiddle
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: ub.armed()
    }
  }
}
