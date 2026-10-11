import QtQuick
import QtQuick.Layouts
// Aliased, not a plain import: an unaliased `import QtQuick.Controls` would
// shadow the search box's TextField with Controls' own (different default
// padding, background and metrics) and silently restyle it.
import QtQuick.Controls as QC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

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

  readonly property string alternativesPath: Qt.resolvedUrl("./alternatives.json").toString().replace("file://", "")

  // Curated alternatives shipped with the plugin. This is what makes FossFetch
  // an alternatives finder rather than a third search box: type "photoshop" and
  // get the FOSS apps that replace it, with their real install sources.
  property var alternatives: []
  property string alternativesError: ""

  FileView {
    path: root.alternativesPath
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text())
        if (Array.isArray(data)) {
          root.alternatives = data
          root.alternativesError = ""
        }
      } catch (e) {
        root.alternativesError = "alternatives.json could not be read"
      }
    }
    onLoadFailed: root.alternativesError = "alternatives.json is missing"
  }

  // Rank a curated entry against the query. The `targetApp` field is the whole
  // point of the file — a space-separated list of the proprietary apps this
  // replaces — so a hit there outranks a hit on the FOSS app's own name.
  function alternativeRank(entry, q) {
    var name = String(entry.name || "").toLowerCase()
    var category = String(entry.category || "").toLowerCase()
    if (name === q) return 0
    if (name.indexOf(q) === 0) return 1
    // `targetApp` is a space-separated keyword list, so it is matched by whole
    // token. A plain substring test is nonsense at this granularity — "word"
    // matches "bitwarden", "music" matches "musical" — and the results read as
    // if the matcher were broken.
    var targets = String(entry.targetApp || "").toLowerCase().split(/\s+/)
    for (var i = 0; i < targets.length; i++) {
      if (targets[i] === q) return 2
    }
    if (name.indexOf(q) !== -1) return 3
    if (category.indexOf(q) !== -1) return 4
    return 5
  }

  function buildAlternatives(q) {
    filteredModel.clear()
    root.pkgIndex = ({})
    root.flatpakIndex = ({})
    resultsList.currentIndex = -1
    var list = root.alternatives
    if (!list || list.length === 0) return
    if (q === "") {
      // Browse mode: the whole catalogue, alphabetical, so the tab is useful
      // before anything is typed.
      var sorted = list.slice().sort(function (a, b) {
        return String(a.name || "").localeCompare(String(b.name || ""))
      })
      for (var s = 0; s < sorted.length && s < 60; s++) root.addAlternativeRow(sorted[s])
      return
    }
    var hits = []
    for (var i = 0; i < list.length; i++) {
      if (root.alternativeRank(list[i], q) < 5) hits.push(list[i])
    }
    hits.sort(function (a, b) {
      var ra = root.alternativeRank(a, q)
      var rb = root.alternativeRank(b, q)
      if (ra !== rb) return ra - rb
      return String(a.name || "").localeCompare(String(b.name || ""))
    })
    for (var j = 0; j < hits.length && j < 60; j++) root.addAlternativeRow(hits[j])
  }

  function addAlternativeRow(entry) {
    root.addRow({
      name: String(entry.name || ""),
      description: String(entry.description || ""),
      category: String(entry.category || ""),
      repo: "alternatives",
      version: "", arch: "", licenses: String(entry.license || ""),
      updated: "",
      website: String(entry.website || ""),
      thumbnail: String(entry.thumbnail || ""),
      iconName: String(entry.iconName || ""),
      pacmanPkg: String(entry.pacmanPkg || ""),
      aurPkg: String(entry.aurPkg || ""),
      flatpakPkg: String(entry.flatpakPkg || "")
    })
  }

  // --------------------------------------------------------------- tabs
  property int activeTab: 0
  readonly property bool isPacman: activeTab === 0
  readonly property bool isFlatpak: activeTab === 1
  readonly property bool isAur: activeTab === 2
  readonly property bool isAlternatives: activeTab === 3
  // "All" runs the three live backends at once into one list. The three
  // handlers already append into a shared model and de-duplicate by key, so
  // this is a launcher change rather than a second code path.
  readonly property bool isAll: activeTab === 4
  readonly property bool isLive: root.isPacman || root.isFlatpak || root.isAur || root.isAll
  property string query: ""

  // --------------------------------------------------- options (persisted)
  // User-facing switches: whether the AUR / Flatpak tabs are shown, and which
  // AUR helper the install buttons use. Persisted to the shared omarchy
  // settings dir so the choices stick across shell restarts.
  property bool flatpakEnabled: true
  property bool aurEnabled: true
  property bool alternativesEnabled: true
  property string aurHelper: "yay"
  property bool showCoffeeButton: true
  property bool showOptions: false

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

  function setAlternativesEnabled(v) {
    root.alternativesEnabled = !!v
    if (!root.alternativesEnabled && root.activeTab === 3) root.switchTab(0)
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
  property string panelDesign: "current"

  readonly property string appstreamStateScript: Qt.resolvedUrl("./appstream_state.py").toString().replace("file://", "")
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
    var valid = ["current", "outline", "soft", "bold", "minimal", "icon"]
    if (valid.indexOf(d) === -1) return
    root.panelDesign = d
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
      alternatives: root.alternativesEnabled,
      aurHelper: root.aurHelper,
      design: root.panelDesign,
      showCoffee: root.showCoffeeButton,
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
        var data = JSON.parse(text())
        if (typeof data.flatpak === "boolean") root.flatpakEnabled = data.flatpak
        if (typeof data.aur === "boolean") root.aurEnabled = data.aur
        if (typeof data.alternatives === "boolean") root.alternativesEnabled = data.alternatives
        if (data.aurHelper === "yay" || data.aurHelper === "paru") root.aurHelper = data.aurHelper
        if (typeof data.showCoffee === "boolean") root.showCoffeeButton = data.showCoffee
        if (["current", "outline", "soft", "bold", "minimal", "icon"].indexOf(data.design) !== -1) root.panelDesign = data.design
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
      } catch (e) { /* keep defaults */ }
    }
  }

  // Enabled tab ids in their on-screen order (Pacman -> AUR -> Flatpak).
  function visibleTabs() {
    var list = [0]
    if (root.aurEnabled) list.push(2)
    if (root.flatpakEnabled) list.push(1)
    if (root.alternativesEnabled) list.push(3)
    // Only worth a tab once there is something to merge.
    if (list.length > 2) list.push(4)
    return list
  }

  function switchTab(t) {
    if (activeTab === t) return
    activeTab = t
    resultsList.currentIndex = -1
    rebuildResults()
    // Re-assert focus WITHOUT selecting the text: the query carries across tabs,
    // and selectAll() here would wipe the search the moment you pressed Tab.
    refocus()
  }

  function tabLabel() {
    if (isAll) return "All"
    if (isPacman) return "Arch repos (Pacman)"
    if (isFlatpak) return "Flathub (Flatpak)"
    if (isAlternatives) return "Alternatives"
    return "AUR (Yay / Paru)"
  }
  function tabCaption() {
    if (isAll) return "Search pacman, Flathub and the AUR at once"
    if (isPacman) return "Search pacman packages"
    if (isFlatpak) return "Search Flatpak apps"
    if (isAlternatives) return "Find a FOSS replacement for something you use"
    return "Search AUR packages"
  }
  function tabPlaceholder() {
    if (isAll) return "Search everywhere… (gimp, spotify, libreoffice)"
    if (isPacman) return "Search Arch package… (gimp, obs, audacity)"
    if (isFlatpak) return "Search a Flatpak app… (gimp, obs, libreoffice)"
    if (isAlternatives) return "What do you want to replace?… (photoshop, spotify, zoom)"
    return "Search AUR package… (spotify, google-chrome, vscode-bin)"
  }

  // Only plain http(s) links may be handed to the external browser. AUR,
  // pacman and Flatpak metadata may contain arbitrary URLs, so everything is
  // allowlisted before opening.
  function isSafeWebUrl(u) {
    var s = String(u || "").toLowerCase()
    return s.indexOf("https://") === 0 || s.indexOf("http://") === 0
  }

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
  function isInsideIconCache(path) {
    var p = String(path || "")
    var root_ = root.iconCacheDir
    if (p === root_) return false          // the directory itself, not a file
    return p.indexOf(root_ + "/") === 0
  }

  // How tall the results list may be. Grows with the number of matches but
  // never past what fits between the bar and the screen edge, so the card
  // can't overlap the bottom of the bar / off-screen. The ListView scrolls
  // internally when there are more matches than fit.
  // Fixed card height so exactly 3 result cards are on screen at a time.
  readonly property real cardHeight: Style.space(196)
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
  function fmtUpdated(raw) {
    var s = String(raw || "").trim()
    if (!s) return ""
    var d = null
    if (/^\d+$/.test(s)) {
      // AUR LastModified is an absolute instant, so local time is correct.
      d = new Date(Number(s) * 1000)
    } else {
      var m = s.match(/(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) (\d{1,2}) ([A-Z][a-z]{2}) (\d{4})/)
      if (m) {
        var months = {Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5,
                      Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11}
        var mn = months[m[2]]
        if (mn !== undefined) d = new Date(Number(m[3]), mn, Number(m[1]))
      } else {
        var iso = s.match(/(\d{4})-(\d{2})-(\d{2})/)
        if (iso) d = new Date(Number(iso[1]), Number(iso[2]) - 1, Number(iso[3]))
      }
    }
    if (!d || isNaN(d.getTime())) return s
    var labels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return d.getDate() + " " + labels[d.getMonth()] + " " + d.getFullYear()
  }

  // Escape for a rich-text sink. Package and app names come from remote
  // metadata, and the card deliberately renders everything as PlainText so a
  // crafted name can never become markup. Highlighting the match is the one
  // place markup is genuinely useful, so the text is escaped FIRST and the only
  // tags in the result are the ones this function emits. The query itself is
  // never interpolated — only its length and offset are used.
  function escapeRich(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  function highlightName(name) {
    var n = String(name || "")
    var q = root.query.toLowerCase().trim()
    if (q === "") return root.escapeRich(n)
    var idx = n.toLowerCase().indexOf(q)
    if (idx < 0) return root.escapeRich(n)
    return root.escapeRich(n.slice(0, idx))
         + '<font color="' + root.matchColor + '"><b>'
         + root.escapeRich(n.slice(idx, idx + q.length))
         + "</b></font>"
         + root.escapeRich(n.slice(idx + q.length))
  }

  // AUR trust signals. Shown as a single chip, worst-first: being flagged
  // out of date by the maintainer matters more than a low vote count, and a
  // crowd-maintained package with hundreds of votes needs no chip at all.
  function trustLabel(e) {
    if (!e) return ""
    if (String(e.aurOutdated || "") !== "")
      return "⚠ flagged out of date"
    var v = parseInt(e.aurVotes, 10)
    if (isNaN(v)) return ""
    if (v <= 0) return "⚠ unrated"
    if (v < 10) return v + " votes"
    return ""
  }

  function trustColor(e) {
    if (!e) return Color.popups.text
    if (String(e.aurOutdated || "") !== "") return root.confirmColor
    var v = parseInt(e.aurVotes, 10)
    if (isNaN(v) || v <= 0 || v < 10) return root.confirmColor
    return Util.alpha(Color.popups.text, 0.55)
  }

  function detailPoints(e) {
    var v = String((e && e.version) || "").trim()
    var r = String((e && e.repo) || "").trim()
    var a = String((e && e.arch) || "").trim()
    var l = String((e && e.licenses) || "").trim()

    var line1 = []
    if (v !== "") line1.push("Version: " + v)
    if (r !== "") line1.push("Repo: " + r)

    var line2 = []
    if (a !== "") line2.push("Arch: " + a)
    if (l !== "") line2.push("License: " + l)

    var pts = []
    if (line1.length) pts.push(line1.join("  ·  "))
    if (line2.length) pts.push(line2.join("  ·  "))
    return pts
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
    resultsList.currentIndex = -1
  }

  function rebuildResults() {
    var q = root.query.toLowerCase().trim()
    buildModel()
    // The alternatives tab is entirely local — no subprocess, no network — so
    // it short-circuits before any backend is launched.
    if (root.isAlternatives) {
      root.pacmanError = ""
      root.flatpakError = ""
      root.aurError = ""
      buildAlternatives(q)
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
  property double installedAt: 0

  function isPacmanInstalled(pkg) {
    return !!pkg && pkg !== "" && root.installedPacman[pkg] === true
  }
  function isFlatpakInstalled(id) {
    return !!id && id !== "" && root.installedFlatpak[id] === true
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
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("|")
      if (parts.length < 2) continue
      var name = parts.slice(1).join("|").trim()
      if (name === "") continue
      if (parts[0] === "P") pkgs[name] = true
      else if (parts[0] === "F") flats[name] = true
    }
    root.installedPacman = pkgs
    root.installedFlatpak = flats
    applyInstalledToRows()
  }

  function applyInstalledToRows() {
    for (var i = 0; i < filteredModel.count; i++) {
      var r = filteredModel.get(i)
      if (!r) continue
      var p = root.isPacmanInstalled(r.pacmanPkg) ? "1" : ""
      var f = root.isFlatpakInstalled(r.flatpakPkg) ? "1" : ""
      if (r.installedPacman !== p) filteredModel.setProperty(i, "installedPacman", p)
      if (r.installedFlatpak !== f) filteredModel.setProperty(i, "installedFlatpak", f)
    }
  }

  // One subprocess for both package managers. Names are read, never executed —
  // they only become keys in the lookup objects below.
  Process {
    id: installedProc
    running: false
    command: ["sh", "-c", "pacman -Qq 2>/dev/null | sed 's/^/P|/'\nflatpak list --app --columns=application 2>/dev/null | sed 's/^/F|/'", "fossfetch-installed"]
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
  function statusDetail(lines) {
    var frame = ""
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf("STATUS|") === 0) frame = lines[i]
    }
    if (frame === "") return ""
    var rest = frame.substring(7)  // "ok|msg" or "error|msg"
    if (rest.indexOf("ok|") === 0) return ""       // a successful (possibly empty) run is not an error
    if (rest.indexOf("error|") === 0) return rest.substring(6)
    return ""
  }

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
    // Recorded once the query is committed, not on every keystroke: the
    // debounced timer below is what makes it a real search.
    if (q.length >= 3) root.rememberSearch(q)
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
      aurVotes: "", aurMaintainer: "", aurOutdated: "", downloadSize: ""
    }
    for (var key in strDefaults) {
      if (row[key] === undefined || row[key] === null) row[key] = strDefaults[key]
    }
    row.installedPacman = root.isPacmanInstalled(row.pacmanPkg) ? "1" : ""
    row.installedFlatpak = root.isFlatpakInstalled(row.flatpakPkg) ? "1" : ""
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
  function pacmanRank(name, q) {
    var n = String(name).toLowerCase()
    if (n === q) return 0
    if (n.indexOf(q) === 0) return 1
    if (n.indexOf(q) !== -1) return 2
    var base = String(q).replace(/[^a-z0-9]/g, "")
    if (base.length >= 3 && n.indexOf(base) !== -1) return 3
    if (root.isFuzzySubsequence(q, n)) return 4
    return 5
  }

  // True when every character of `q` appears in `n`, in order, with the first
  // one landing near the start. Two constraints keep it from flooding the
  // ranking with noise:
  //   * under 3 characters matches almost any name, so it is rejected outright;
  //   * the run must begin in the first three characters, otherwise "zz" style
  //     coincidences deep inside a long package name would float to the top.
  function isFuzzySubsequence(q, n) {
    if (q.length < 3) return false
    var qi = 0
    var start = -1
    for (var i = 0; i < n.length && qi < q.length; i++) {
      if (n.charAt(i) !== q.charAt(qi)) continue
      if (qi === 0) {
        if (i > 2) return false
        start = i
      }
      qi++
    }
    return start >= 0 && qi === q.length
  }

  // Index of an existing model row whose pacman package id matches `name`, or
  // -1 if it isn't shown yet. Backed by pkgIndex rather than a linear scan.
  function modelRowIndex(name) {
    var i = root.pkgIndex[name]
    return i === undefined ? -1 : i
  }

  function onFlatpakResults(text) {
    if (flatpakProc.mySeq !== searchSeq) return
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
        outOfDate: parts[9] !== undefined ? parts[9].trim() : ""
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
        aurVotes: info.votes, aurMaintainer: info.maintainer, aurOutdated: info.outOfDate
      })
      added++
    }
    // Enrich icons for the newly-added rows (AUR packs usually have no icon;
    // the batched local/appstream/flathub lookups resolve one by name).
    requestEnrich()
    refreshInstalled(false)
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
      // Empty keys are never indexed: the alternatives tab fills every row with
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
      if (repo !== "") filteredModel.setProperty(idx, "repo", repo)
      if (version !== "") filteredModel.setProperty(idx, "version", version)
      if (arch !== "") filteredModel.setProperty(idx, "arch", arch)
      if (desc !== "") filteredModel.setProperty(idx, "description", desc)
      if (url !== "") filteredModel.setProperty(idx, "website", url)
      if (licenses !== "") filteredModel.setProperty(idx, "licenses", licenses)
      if (buildDate !== "") filteredModel.setProperty(idx, "updated", buildDate)
    }
  }

  // ---------------------------------------------------------------- install
  // One-click install with a confirm step. First click arms the button
  // (shows "Confirm?"), a second click within the timeout runs the install
  // in the user's terminal. Independent per-branch/per-package so pacman and
  // flatpak buttons on the same card don't fight.
  property var pendingInstall: null
  Timer {
    id: confirmResetTimer
    interval: 3000
    repeat: false
    onTriggered: root.pendingInstall = null
  }

  function installPending(kind, pkg) {
    return root.pendingInstall !== null
      && root.pendingInstall.kind === kind
      && root.pendingInstall.pkg === pkg
  }

  function startInstall(kind, pkg, name) {
    // Second click on the same armed button runs the install.
    if (root.installPending(kind, pkg)) {
      root.runInstall(kind, pkg, name)
      root.pendingInstall = null
      return
    }
    root.pendingInstall = { kind: kind, pkg: pkg, name: name }
    confirmResetTimer.restart()
  }

  // What the panel last launched, so the exit toast can name it. Captured at
  // launch time rather than read off pendingInstall, which startInstall clears
  // the moment the command is dispatched.
  property string lastInstallLabel: ""
  property string lastInstallKind: ""

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
    root.lastInstallLabel = name || pkg
    root.lastInstallKind = kind

    // Resolve the user's terminal (falls back to kitty, matching the shell).
    var term = Quickshell.env("TERMINAL")
    if (!term) term = Quickshell.env("TERMINAL_CMD")
    if (!term) term = "kitty"
    installProc.command = [term, "-e"].concat(args)
    installProc.running = true
    // The package will be installed by the time the user comes back to this
    // panel; re-read the snapshot so the row shows as Installed, not stale.
    installFinishedTimer.restart()
  }

  // Give the terminal a moment to actually do the work before re-reading.
  Timer {
    id: installFinishedTimer
    interval: 8000
    repeat: false
    onTriggered: root.refreshInstalled(true)
  }

  Process {
    id: installProc
    // The terminal stays alive for the whole command, so its exit is a decent
    // proxy for "the install finished". The exit code itself belongs to the
    // terminal, not pacman, so the toast states the outcome neutrally and points
    // at the terminal rather than claiming success.
    onExited: {
      var what = root.lastInstallLabel
      if (what === "") return
      root.notify("FossFetch",
        root.sourceLabel(root.lastInstallKind) + " finished for " + what + ". See the terminal for the result.")
      root.refreshInstalled(true)
    root.clipboardSuggestion()
    }
  }

  // ------------------------------------------------------------- lifecycle
  function open() {
    root.controller.show()
    refreshFocus()
  }

  function openFromHotkey() {
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) refreshFocus()
    })
  }

  function close() {
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
  function clipboardSuggestion() {
    clipProc.running = false
    clipProc.running = true
  }

  function applyClipboard(text) {
    var t = String(text || "").trim()
    if (t === "" || t.indexOf("\n") !== -1 || t.length > 80) return
    if (searchField.text !== "") return
    searchField.text = t
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
    root.detectAurHelperProc.running = false
    root.detectAurHelperProc.running = true
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
    // Flatpak and Alternatives tabs — never start it for a user who has both
    // switched off.
    if (root.flatpakEnabled || root.alternativesEnabled) {
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
    if (root.isFlatpak || root.isAlternatives) {
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
    if ((root.isPacman || root.isAlternatives || root.isAll) && e.pacmanPkg && e.pacmanPkg !== "")
      return { kind: "pacman", pkg: e.pacmanPkg }
    if ((root.isPacman || root.isAur || root.isAlternatives || root.isAll) && e.aurPkg && e.aurPkg !== "")
      return { kind: root.aurHelper, pkg: e.aurPkg }
    return null
  }

  // Enter on the highlighted card arms its install (first press shows the
  // button's "Confirm?" state); a second press runs the command.
  function activateCursor() {
    if (filteredModel.count === 0) return
    var idx = resultsList.currentIndex
    if (idx < 0 || idx >= filteredModel.count) return
    var spec = root.cardInstallSpec(filteredModel.get(idx))
    if (spec) root.startInstall(spec.kind, spec.pkg, filteredModel.get(idx).name)
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
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onTextKey: function(t) {
        if (t === "/") root.refreshFocus()
      }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(12)

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
            Text {
              text: "\uf002"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.title
            }
          }
          trailingControl: Component {
            Rectangle {
              id: optionsBtn
              Layout.preferredWidth: Style.space(22)
              Layout.preferredHeight: Style.space(20)
              radius: Style.cornerRadius
              color: root.showOptions
                ? Style.selectedFillFor(Color.popups.text, Color.accent)
                : (optionsMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent")
              border.width: Style.controlBorderWidth(false, optionsMouse.containsMouse)
              border.color: Style.controlBorder(false, optionsMouse.containsMouse, Color.popups.text, Color.accent)
              Behavior on border.color { ColorAnimation { duration: 150 } }

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: "transparent"
                border.color: Util.alpha(Color.accent, 0.6)
                border.width: 2
                opacity: optionsMouse.containsMouse ? 0.7 : 0
                Behavior on opacity { NumberAnimation { duration: 180 } }
              }

              Text {
                anchors.centerIn: parent
                text: root.showOptions ? "\uf00d" : "\uf013"
                color: root.showOptions || optionsMouse.containsMouse ? Color.accent : Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                Behavior on color { ColorAnimation { duration: 150 } }
              }

              MouseArea {
                id: optionsMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showOptions = !root.showOptions
              }
            }
          }
        }

        // -------------------------------------------------------------- tabs
        Item {
          width: parent.width
          implicitHeight: Style.space(34)

          RowLayout {
            id: tabRow
            anchors.fill: parent
            spacing: Style.space(8)

            TabButton {
              id: pacmanTabBtn
              text: "Pacman"
              active: root.activeTab === 0
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.preferredWidth: 1
              Layout.minimumWidth: 0
              onClicked: root.switchTab(0)
            }

            TabButton {
              id: aurTabBtn
              text: "AUR"
              active: root.activeTab === 2
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.preferredWidth: 1
              Layout.minimumWidth: 0
              visible: root.aurEnabled
              onClicked: root.switchTab(2)
            }

            TabButton {
              id: flatpakTabBtn
              text: "Flatpak"
              active: root.activeTab === 1
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.preferredWidth: 1
              Layout.minimumWidth: 0
              visible: root.flatpakEnabled
              onClicked: root.switchTab(1)
            }

            TabButton {
              id: allTabBtn
              text: "All"
              active: root.activeTab === 4
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.preferredWidth: 1
              Layout.minimumWidth: 0
              visible: root.visibleTabs().length > 3
              onClicked: root.switchTab(4)
            }

            // The alternatives tab is the one that makes this a FossFetch
            // rather than a third search box: it answers "what do I install
            // instead of X?" entirely from the bundled catalogue.
            TabButton {
              id: alternativesTabBtn
              text: "Alternatives"
              active: root.activeTab === 3
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.preferredWidth: 1
              Layout.minimumWidth: 0
              visible: root.alternativesEnabled
              onClicked: root.switchTab(3)
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
              label: "Alternatives"
              description: "Show the curated \"replace it with FOSS\" tab"
              checked: root.alternativesEnabled
              onClicked: root.setAlternativesEnabled(!root.alternativesEnabled)
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
                spacing: Style.space(6)

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
              color: Color.bad
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
                spacing: Style.space(4)

                HelperPill {
                  glyph: "\u25AA"
                  label: "Current"
                  selected: root.panelDesign === "current"
                  onClicked: root.setPanelDesign("current")
                }
                HelperPill {
                  glyph: "\u25A1"
                  label: "Outline"
                  selected: root.panelDesign === "outline"
                  onClicked: root.setPanelDesign("outline")
                }
                HelperPill {
                  glyph: "\u25CF"
                  label: "Soft"
                  selected: root.panelDesign === "soft"
                  onClicked: root.setPanelDesign("soft")
                }
                HelperPill {
                  glyph: "\u25A0"
                  label: "Bold"
                  selected: root.panelDesign === "bold"
                  onClicked: root.setPanelDesign("bold")
                }
                HelperPill {
                  glyph: "\u25CB"
                  label: "Minimal"
                  selected: root.panelDesign === "minimal"
                  onClicked: root.setPanelDesign("minimal")
                }
                HelperPill {
                  glyph: "\uf00e"
                  label: "Icon"
                  selected: root.panelDesign === "icon"
                  onClicked: root.setPanelDesign("icon")
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

                Text {
                  anchors.centerIn: parent
                  text: "\uf00c"
                  color: root.showCoffeeButton ? Color.accent : "transparent"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
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

            Text {
              id: icon
              text: "\uf002"
              color: Util.alpha(Color.popups.text, 0.45)
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22)
              horizontalAlignment: Text.AlignHCenter
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
              anchors.leftMargin: Style.space(2)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
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
                if (event.key === Qt.Key_Escape) {
                  root.close()
                  event.accepted = true
                } else if (event.key === Qt.Key_Tab) {
                  root.switchPanel(1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Backtab) {
                  root.switchPanel(-1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  root.moveCursor(0, 1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  root.moveCursor(0, -1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.activateCursor()
                  event.accepted = true
                }
              }
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
              required property string installedFlatpak
              // AUR trust signals (empty on every other source).
              required property string aurVotes
              required property string aurMaintainer
              required property string aurOutdated
              // "Downloaded: 12.4 MiB" straight from `pacman -Si`.
              required property string downloadSize
              // `rating`, `license`, `category` and `_pkg` stay in the model
              // (alternatives.json supplies them and the async writers resolve
              // rows by _pkg through filteredModel.get(), not through a
              // delegate binding) but are deliberately not declared here: a
              // delegate only needs a role it actually draws.

              // Selected / hover highlight — menu-style selected surface.
              readonly property bool isSelected: ListView.isCurrentItem
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
              color: isSelected
                ? Util.alpha(Color.accent, 0.14)
                : (isHovered ? Util.alpha(Color.popups.text, 0.05) : "transparent")
              border.width: isSelected ? Border.uniformWidth(root.selectedBorderSpec) : 0
              border.color: isSelected ? Border.color(root.selectedBorderSpec) : "transparent"

              // Soft accent ring around the selected card — a nested overlay so
              // it draws on top of the fill but beneath the row content.
              Rectangle {
                anchors.fill: parent
                anchors.margins: Style.space(1)
                radius: Math.max(2, Style.cornerRadius - Style.space(1))
                color: "transparent"
                border.width: 1.5
                border.color: Util.alpha(Color.accent, delegateRoot.isSelected ? 0.55 : 0)
                Behavior on border.color { ColorAnimation { duration: 150 } }
              }

              RowLayout {
                id: delegateRow
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: 0

                Item {
                  id: thumbWrap
                  Layout.preferredWidth: 52
                  Layout.preferredHeight: 52
                  Layout.alignment: Qt.AlignTop
                  Layout.topMargin: Style.space(2)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: Util.alpha(Color.popups.text, 0.06)
                    border.width: Style.spacing.hairline
                    border.color: Util.alpha(Color.popups.text, 0.18)
                  }

                  Text {
                    anchors.centerIn: parent
                    text: delegateRoot.name.charAt(0).toUpperCase()
                    color: Util.alpha(Color.popups.text, 0.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.icon
                    font.bold: true
                    textFormat: Text.PlainText
                    visible: img.status !== Image.Ready
                  }

                  Image {
                    id: img
                    anchors.fill: parent
                    anchors.margins: Style.space(6)
                    source: root.resolveThumb(delegateRoot.thumbnail, delegateRoot.iconName)
                    fillMode: Image.PreserveAspectFit
                    antialiasing: true
                    cache: true
                  }
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.leftMargin: Style.space(10)
                  spacing: Style.space(4)

                  // Row 1: Name (left) + Open Web/GitHub button (right)
                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(8)

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

                    Button {
                      id: webButton
                      visible: delegateRoot.website !== ""
                      focusable: false
                      text: String(delegateRoot.website).indexOf("github") !== -1
                        ? "GitHub ↗"
                        : "Web ↗"
                      foreground: root.pacmanColor
                      fontFamily: Style.font.family
                      fontSize: Style.font.caption
                      bordered: true
                      Layout.preferredHeight: Style.space(24)
                      Layout.minimumWidth: 0
                      onClicked: { if (root.isSafeWebUrl(delegateRoot.website)) Qt.openUrlExternally(delegateRoot.website) }
                    }
                  }

                  // Row 2: Description — auto-scrolls vertically when too long.
                  // The bullets/install rows below need their own space, so the
                  // description compresses (scrolling via its Flickable) rather
                  // than overflowing the fixed card height.
                  Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: Style.space(6)
                    clip: true

                    Flickable {
                      id: descFlick
                      anchors.fill: parent
                      contentWidth: width
                      contentHeight: descText.implicitHeight
                      clip: true
                      boundsBehavior: Flickable.StopAtBounds
                      flickableDirection: Flickable.VerticalFlick
                      interactive: contentHeight > height

                      Text {
                        id: descText
                        width: descFlick.width
                        text: delegateRoot.description || ""
                        color: Util.alpha(Color.popups.text, 0.62)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        textFormat: Text.PlainText
                        wrapMode: Text.WordWrap
                      }
                    }
                  }

                  // Row 3: Version / repo / arch / license — compact labeled
                  // headings directly below the description.
                  Text {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(2)
                    visible: root.detailPoints(delegateRoot).length > 0
                    // Long license/value text must be allowed to shrink (and
                    // elide) — otherwise its implicit width forces the whole
                    // card row wider than the popup and the description wraps
                    // at the wrong width, clipping mid-word at the card edge.
                    Layout.minimumWidth: 0
                    // Hard-cap the height so it can never overflow the fixed
                    // card height (in this runtime implicitHeight is computed
                    // pathologically large, which would otherwise blow up the
                    // ColumnLayout, squash the description and push the install
                    // buttons off the bottom of the card).
                    Layout.preferredHeight: Style.space(44)
                    Layout.maximumHeight: Style.space(44)
                    Layout.minimumHeight: Style.space(22)
                    clip: true
                    color: Util.alpha(Color.popups.text, 0.78)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    lineHeight: Style.space(20)
                    text: root.detailPoints(delegateRoot).join("\n")
                    textFormat: Text.PlainText
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                  }

                  // Row 4: Install buttons (bottom-right of the card)
                  RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(2)
                    spacing: Style.space(8)

                    // "Last updated" date in the bottom-left of the card, away
                    // from the install buttons on the right. Empty when the row
                    // has no release/build-date info yet.
                    Text {
                      Layout.minimumWidth: 0
                      Layout.fillWidth: true
                      Layout.alignment: Qt.AlignVCenter
                      visible: root.fmtUpdated(delegateRoot.updated) !== ""
                      text: "Updated: " + root.fmtUpdated(delegateRoot.updated)
                      color: Util.alpha(Color.popups.text, 0.55)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                    }

                    // Download size for the distro package — the one number
                    // people actually weigh before installing.
                    Text {
                      Layout.alignment: Qt.AlignVCenter
                      visible: delegateRoot.downloadSize !== ""
                      text: "⤓ " + delegateRoot.downloadSize
                      color: Util.alpha(Color.popups.text, 0.55)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
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
                    Text {
                      Layout.alignment: Qt.AlignVCenter
                      visible: delegateRoot.installedPacman === "1"
                             || delegateRoot.installedFlatpak === "1"
                      text: "✓ Installed"
                      color: root.pacmanColor
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      textFormat: Text.PlainText
                    }

                    // Flexible spacer pushes the install buttons to the right.
                    Item { Layout.fillWidth: true }

                    InstallButton {
                      visible: (root.isPacman || root.isAlternatives || root.isAll) && delegateRoot.pacmanPkg !== ""
                      installKind: "pacman"
                      packageName: delegateRoot.pacmanPkg
                      installed: delegateRoot.installedPacman === "1"
                      isPending: root.installPending("pacman", delegateRoot.pacmanPkg)
                      onArmed: root.startInstall("pacman", delegateRoot.pacmanPkg, delegateRoot.name)
                    }

                    InstallButton {
                      visible: (root.isPacman || root.isAur || root.isAlternatives || root.isAll) && delegateRoot.aurPkg !== "" && root.aurHelper === "yay"
                      installKind: "yay"
                      packageName: delegateRoot.aurPkg
                      unavailable: !root.aurHelperInstalled
                      isPending: root.installPending("yay", delegateRoot.aurPkg)
                      onArmed: root.startInstall("yay", delegateRoot.aurPkg, delegateRoot.name)
                    }

                    InstallButton {
                      visible: (root.isPacman || root.isAur || root.isAlternatives || root.isAll) && delegateRoot.aurPkg !== "" && root.aurHelper === "paru"
                      installKind: "paru"
                      packageName: delegateRoot.aurPkg
                      unavailable: !root.aurHelperInstalled
                      isPending: root.installPending("paru", delegateRoot.aurPkg)
                      onArmed: root.startInstall("paru", delegateRoot.aurPkg, delegateRoot.name)
                    }

                    // Shown whenever the row carries a Flathub app id — not just
                    // on the Flatpak tab. Pacman and AUR rows get one attached
                    // by the Flathub-equivalent pass, so a single card can offer
                    // the distro package AND its Flathub equivalent.
                    InstallButton {
                      visible: delegateRoot.flatpakPkg !== ""
                      installKind: "flatpak"
                      packageName: delegateRoot.flatpakPkg
                      installed: delegateRoot.installedFlatpak === "1"
                      isPending: root.installPending("flatpak", delegateRoot.flatpakPkg)
                      onArmed: root.startInstall("flatpak", delegateRoot.flatpakPkg, delegateRoot.name)
                    }
                  }
                }
              }
            }
          }
        }

        // ---------------------------------------------------- recent searches
        // Only meaningful when nothing is typed: the alternatives tab shows its
        // own browse list, and a live tab shows its own results.
        Item {
          width: parent.width
          visible: root.recentSearches.length > 0 && searchField.text.trim() === ""
          implicitHeight: visible ? recentCol.implicitHeight + Style.space(12) : 0

          Column {
            id: recentCol
            width: parent.width
            spacing: Style.space(4)

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
              spacing: Style.space(6)

              Repeater {
                model: root.recentSearches
                delegate: Rectangle {
                  required property string modelData
                  implicitWidth: recentText.implicitWidth + Style.space(16)
                  implicitHeight: Style.space(24)
                  radius: Style.cornerRadius
                  color: recentChipMouse.containsMouse
                    ? Util.alpha(Color.popups.text, 0.10)
                    : Util.alpha(Color.popups.text, 0.05)
                  border.width: Style.spacing.hairline
                  border.color: Util.alpha(Color.popups.text, 0.15)
                  Behavior on color { ColorAnimation { duration: 120 } }

                  Text {
                    id: recentText
                    anchors.centerIn: parent
                    text: modelData
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
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
              spacing: Style.space(6)

              Text {
                text: root.isAlternatives
                  ? (root.query === "" ? "FOSS alternatives" : "No alternative found")
                  : root.query === ""
                    ? "Search " + (root.isAll ? "pacman, Flathub and the AUR"
                      : root.isPacman ? "an Arch package"
                      : root.isFlatpak ? "a Flatpak app" : "an AUR package")
                    : root.tabError() !== ""
                      ? "Lookup failed"
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
                  : root.isAlternatives
                    ? (root.alternativesError !== "" ? root.alternativesError
                      : root.query === "" ? root.alternatives.length + " curated replacements — try photoshop, spotify or zoom"
                        : "Try the app you want to replace")
                    : root.query === ""
                      ? "e.g. gimp, chromecast, vscode, obs, libreoffice"
                      : root.tabError() !== ""
                        ? root.tabError()
                        : "Try a different name"
                color: root.tabError() !== "" ? Color.bad : Util.alpha(Color.popups.text, 0.5)
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

  component TabButton: Item {
    id: tabRoot
    property string text: ""
    property bool active: false
    signal clicked()

    implicitWidth: lab.implicitWidth + Style.space(22)
    implicitHeight: Style.space(32)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: active
        ? Style.selectedFillFor(Color.popups.text, Color.accent)
        : (tabMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent")
      border.width: Style.controlBorderWidth(false, tabMouse.containsMouse)
      border.color: Style.controlBorder(false, tabMouse.containsMouse, Color.popups.text, Color.accent)

      // Soft outer glow that fades in on hover (and stays lit while active),
      // matching the toolbar icon's hover ring.
Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: "transparent"
        border.color: Util.alpha(Color.accent, 0.6)
        border.width: 2
        opacity: tabMouse.containsMouse ? 0.7 : 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
      }

      Text {
        id: lab
        anchors.centerIn: parent
        text: tabRoot.text
        color: active ? Color.accent : Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: active
        textFormat: Text.PlainText
      }
    }

    MouseArea {
      id: tabMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tabRoot.clicked()
    }
  }

  //                                                         small install button
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
      spacing: Style.space(4)

      Text {
        text: pill.glyph
        visible: pill.glyph !== ""
        color: pill.selected ? Color.accent : Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: pill.selected
        textFormat: Text.PlainText
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

  component InstallButton: Item {
    id: btn
    property string installKind: ""
    property string packageName: ""
    property bool isPending: false
    // Already installed: the button becomes an inert status pill rather than
    // arming a re-install.
    property bool installed: false
    // Its command cannot run on this machine (no AUR helper). Also inert, and
    // labelled so the failure is visible before it happens.
    property bool unavailable: false
    readonly property bool actionable: !btn.installed && !btn.unavailable

    signal armed()

    // Fixed-width pill: labels self-size and FitText shrinks the font to fit,
    // so a long AUR package name can never shove the button past the card edge
    // or inflate the row's minimum width.
    implicitWidth: Style.space(120)
    implicitHeight: Style.space(26)

    function label() {
      if (btn.isPending) return "Confirm?"
      if (btn.installed) return "✓ Installed"
      if (btn.unavailable) return installKind + " missing"
      return btn.installKind + " (" + btn.packageName + ")"
    }

    function branchColor() {
      if (btn.installed) return root.pacmanColor
      if (btn.unavailable) return Color.bad
      if (installKind === "pacman") return root.pacmanColor
      if (installKind === "yay" || installKind === "paru") return root.aurColor
      return root.flatpakColor
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: btn.isPending
        ? Util.alpha(root.confirmColor, 0.22)
        : !btn.actionable
          ? Util.alpha(Color.popups.text, 0.04)
          : (mouse.containsMouse ? Util.alpha(btn.branchColor(), 0.2) : Util.alpha(Color.popups.text, 0.06))
      border.width: Style.spacing.hairline
      border.color: btn.isPending
        ? root.confirmColor
        : (mouse.containsMouse ? Util.alpha(btn.branchColor(), 0.8) : Util.alpha(btn.branchColor(), 0.45))

      Behavior on border.color { ColorAnimation { duration: 150 } }

      // Soft outer glow that fades in on hover (and stays lit while armed),
      // matching the toolbar icon's glow ring.
      Rectangle {
        anchors.fill: parent
        anchors.margins: -Style.space(1)
        radius: Style.cornerRadius + Style.space(1)
        color: "transparent"
        border.color: Util.alpha(btn.branchColor(), 0.5)
        border.width: 1.5
        opacity: (btn.isPending || mouse.containsMouse) ? 0.85 : 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
      }

      FitText {
        id: label
        anchors.fill: parent
        anchors.margins: Style.space(4)
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
      onClicked: btn.armed()
    }
  }
}
