import QtQuick
import QtQuick.Layouts
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
  property string query: ""

  // --------------------------------------------------- options (persisted)
  // User-facing switches: whether the AUR / Flatpak tabs are shown, and which
  // AUR helper the install buttons use. Persisted to the shared omarchy
  // settings dir so the choices stick across shell restarts.
  property bool flatpakEnabled: true
  property bool aurEnabled: true
  property string aurHelper: "yay"
  property bool showCoffeeButton: true
  property bool showOptions: false

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
  // current | outline | soft | bold | minimal. The panel itself keeps its
  // stock look; this setting is pushed to the BarWidget so the button in the
  // bar restyles itself live.
  property string panelDesign: "current"

  function setPanelDesign(d) {
    var valid = ["current", "outline", "soft", "bold", "minimal", "icon"]
    if (valid.indexOf(d) === -1) return
    root.panelDesign = d
    root.persistOptions()
    if (root.hostWidget && root.hostWidget.setToolbarDesign)
      root.hostWidget.setToolbarDesign(d)
  }

  function persistOptions() {
    optionsFile.setText(JSON.stringify({
      flatpak: root.flatpakEnabled,
      aur: root.aurEnabled,
      aurHelper: root.aurHelper,
      design: root.panelDesign,
      showCoffee: root.showCoffeeButton
    }, null, 2) + "\n")
  }

  FileView {
    id: optionsFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/davedes.fossfetch.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text())
        if (typeof data.flatpak === "boolean") root.flatpakEnabled = data.flatpak
        if (typeof data.aur === "boolean") root.aurEnabled = data.aur
        if (data.aurHelper === "yay" || data.aurHelper === "paru") root.aurHelper = data.aurHelper
        if (typeof data.showCoffee === "boolean") root.showCoffeeButton = data.showCoffee
        if (["current", "outline", "soft", "bold", "minimal", "icon"].indexOf(data.design) !== -1) root.panelDesign = data.design
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
    return list
  }

  function switchTab(t) {
    if (activeTab === t) return
    activeTab = t
    resultsList.currentIndex = -1
    rebuildResults()
    refreshFocus()
  }

  function tabLabel() {
    if (isPacman) return "Arch repos (Pacman)"
    if (isFlatpak) return "Flathub (Flatpak)"
    return "AUR (Yay / Paru)"
  }
  function tabCaption() {
    if (isPacman) return "Search pacman packages"
    if (isFlatpak) return "Search Flatpak apps"
    return "Search AUR packages"
  }
  function tabPlaceholder() {
    if (isPacman) return "Search Arch package… (gimp, obs, audacity)"
    if (isFlatpak) return "Search a Flatpak app… (gimp, obs, libreoffice)"
    return "Search AUR package… (spotify, google-chrome, vscode-bin)"
  }

  function resolveThumb(remote, iconName) {
    if (remote !== "") {
      // Bare local paths (e.g. AppStream-catalog or icon-theme hits) must be
      // wrapped in a file:// URL — Image.source won't load a raw path,
      // matching how omarchy's own iconSource() resolves local files.
      var s = String(remote)
      if (s.indexOf("file://") === 0 || s.indexOf("https://") === 0 || s.indexOf("http://") === 0) return s
      return Util.fileUrl(s)
    }
    var local = iconName !== "" ? Quickshell.iconPath(iconName, true) : ""
    return local !== "" ? local : ""
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
  function fmtUpdated(raw) {
    var s = String(raw || "").trim()
    if (!s) return ""
    var d = null
    if (/^\d+$/.test(s)) {
      d = new Date(Number(s) * 1000)
    } else {
      var m = s.match(/(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) (\d{1,2}) ([A-Z][a-z]{2}) (\d{4})/)
      if (m) {
        var months = {Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5,
                      Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11}
        var mn = months[m[2]]
        if (mn !== undefined) d = new Date(Date.UTC(Number(m[3]), mn, Number(m[1])))
      } else {
        var iso = s.match(/(\d{4})-(\d{2})-(\d{2})/)
        if (iso) d = new Date(Date.UTC(Number(iso[1]), Number(iso[2]) - 1, Number(iso[3])))
      }
    }
    if (!d || isNaN(d.getTime())) return s
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return d.getUTCDate() + " " + months[d.getUTCMonth()] + " " + d.getUTCFullYear()
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

  // hmmPadding allows the header + search + tab labels to fit within the card.
  readonly property real headerAllowance: Style.space(150)

  // ------------------------------------------------------- result building
  ListModel { id: filteredModel }
  property int searchSeq: 0

  // rebuild the visible list for the active tab + query.
  // The model is populated purely by live search results (pacman -Ss /
  // flatpak search); there is no curated app list. Every appended row carries
  // the FULL role set (including empty version, repo, arch, licenses, _pkg) so
  // ListModel knows about those roles from the start — otherwise
  // `filteredModel.set()` later can't add new roles and any live-scraped
  // metadata would be silently dropped.
  function buildModel(q) {
    filteredModel.clear()
    resultsList.currentIndex = -1
  }

  function rebuildResults() {
    var q = root.query.toLowerCase().trim()
    buildModel(q)
    if (q === "") return
    launchLiveSearch(q)
  }

  // -------------------------------------------------------- live scraping
  property bool pacmanDone: false
  property bool flatpakDone: false

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
    var seq = ++searchSeq
    root.pendingGroup = ({})
    if (isPacman) {
      pacmanProc.mySeq = seq
      pacmanProc.running = false
      // One shot: resolve the category -> packages mapping for <q>, emit a
      // "G|pkg1|pkg2|..." marker line, then the normal `pacman -Ss` output
      // followed by a `pacman -Ss ^(pkg1|pkg2|...)$` whole-category search.
      // pkg names only come from the local groups index (never from user input).
      var pacmanScript =
        "Q=$1; C=$2; GS=$3\n"
        + "P=$( \"$GS\" resolve \"$C\" \"$Q\" 2>/dev/null )\n"
        + "if [ -n \"$P\" ]; then\n"
        + "  R=$( printf '%s' \"$P\" | tr '\\n' '|' | sed 's/|$//' )\n"
        + "  echo \"G|$R\"\n"
        + "fi\n"
        + "pacman -Ss \"$Q\"\n"
        + "if [ -n \"$P\" ]; then pacman -Ss \"^($R)$\"; fi\n"
      pacmanProc.command = ["sh", "-c", pacmanScript, "fossfetch-groups", q, root.iconCacheDir, root.appstreamGroupsScript]
      pacmanProc.running = true
    } else if (isFlatpak) {
      flatpakProc.mySeq = seq
      flatpakProc.running = false
      // Group rows (app cat + meta) come first, tagged G| with flatpak-search
      // column order (name, desc, appid, version); then normal search output.
      var flatpakScript =
        "Q=$1; C=$2; GS=$3\n"
        + "python3 \"$GS\" resolve \"$C\" \"$Q\" 2>/dev/null |"
        + " awk -F'\\t' '{print \"G|\"$2\"\\t\"$3\"\\t\"$1\"\\t\"$4\"\\t\"$5}'\n"
        + "flatpak search --columns=name,description,application,version \"$Q\" |"
        + " awk -F'\\t' -v idx=\"$C/flathub/appids.tsv\" '"
        + " BEGIN { while ((getline l < idx) > 0) { split(l, a, \"\\t\"); d[a[1]] = a[2] } close(idx) }"
        + " NF >= 4 { print $0 (d[$3] != \"\" ? \"\\t\" d[$3] : \"\") }'\n"
      flatpakProc.command = ["sh", "-c", flatpakScript, "fossfetch-flatpak-groups", q, root.iconCacheDir, root.flathubGroupsScript]
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

  function appendRow(spec) {
    if (spec === null) return
    filteredModel.append(spec)
  }

  // parses `pacman -Ss <q>`: alternating "repo/name version" header lines and
  // indented description lines, so each result carries its real description.
  function onPacmanResults(text) {
    if (pacmanProc.mySeq !== searchSeq) return
    var q = root.query.toLowerCase().trim()
    if (q === "") return
    var lines = String(text || "").split("\n")

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
      filteredModel.append({
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
    enqueueEnrich()
  }

  // Rank a pacman result by how well its package name matches the query:
  // exact (0) > prefix (1) > substring (2) > base-name (3) > description only (4).
  function pacmanRank(name, q) {
    var n = String(name).toLowerCase()
    if (n === q) return 0
    if (n.indexOf(q) === 0) return 1
    if (n.indexOf(q) !== -1) return 2
    var base = String(q).replace(/[^a-z0-9]/g, "")
    if (base.length >= 3 && n.indexOf(base) !== -1) return 3
    return 4
  }

  // Index of an existing model row whose pacman package id matches `name`, or
  // -1 if it isn't shown yet.
  function modelRowIndex(name) {
    for (var i = 0; i < filteredModel.count; i++) {
      var r = filteredModel.get(i)
      if ((r.pacmanPkg !== undefined && r.pacmanPkg === name)
          || (r._pkg !== undefined && r._pkg === name)) return i
    }
    return -1
  }

  function onFlatpakResults(text) {
    if (flatpakProc.mySeq !== searchSeq) return
    var q = root.query.toLowerCase().trim()
    if (q === "") return
    var lines = String(text || "").split("\n")
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
      appendRow({
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
  }

  // True if a live row with this flatpak app id is already in the model.
  // Guards against duplicate search-result lines for the same app (multiple
  // remotes/arches/versions).
  function modelHasFlatpak(id) {
    for (var i = 0; i < filteredModel.count; i++) {
      if (filteredModel.get(i).flatpakPkg === id) return true
    }
    return false
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
        lastModified: parts[7] !== undefined ? parts[7].trim() : ""
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
      filteredModel.append({
        name: info.name, description: info.desc,
        rating: "", website: info.website, license: "", category: "AUR",
        repo: "aur", version: info.version, arch: "", licenses: info.license,
        updated: info.lastModified,
        thumbnail: "", iconName: "", pacmanPkg: "", aurPkg: info.name, flatpakPkg: "",
        _pkg: info.name
      })
      added++
    }
    // Enrich icons for the newly-added rows (AUR packs usually have no icon;
    // the batched local/appstream/flathub lookups resolve one by name).
    enqueueEnrich()
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
  property var enrichQueue: []
  property var localQueue: []
  property var flatpakQueue: []
  property bool enrichBusy: false

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
      if (!e || e.thumbnail !== "" || e.iconName !== "" || e._pkg === undefined || e._pkg === "") continue
      enrichQueue.push({ index: i, name: e.name, pkg: e._pkg })
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
    script += "for p in " + names.join(" ") + "; do resolve \"$p\" || echo \"I|$p|\"; done"
    localIconProc.command = ["sh", "-c", script]
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
    for (var i = 0; i < root.flatpakQueue.length && names.length < 30; i++)
      if (names.indexOf(root.flatpakQueue[i].pkg) === -1) names.push(root.flatpakQueue[i].pkg)
    if (names.length === 0) { root.enrichBusy = false; return }
    enrichQuery.command = ["python3", flatpakIconScript].concat(names)
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
    var script = ""
    for (var k = 0; k < pkgs.length; k++)
      script += "o=$(pacman -Si " + pkgs[k] + " 2>/dev/null); lic=$(printf '%s\\n' \"$o\" | sed -n -e 's/^Licenses[[:space:]]*: *//p' -e 's/^License[[:space:]]*: *//p' | head -1); echo \"P|" + pkgs[k] + "|$lic\"\n"
    for (var m = 0; m < flats.length; m++)
      script += "lic=$(flatpak info --show-metadata " + flats[m] + " 2>/dev/null | sed -n 's/^license=//p' | head -1); echo \"F|" + flats[m] + "|$lic\"\n"
    root.licenseSeq++
    licenseProc.mySeq = root.licenseSeq
    licenseProc.command = ["sh", "-c", script]
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
      if (filteredModel.get(idx).thumbnail !== "") continue
      filteredModel.setProperty(idx, "thumbnail", flathubIcon(appId))
      filteredModel.setProperty(idx, "category", "Pacman · Flathub")
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
    for (var i = 0; i < filteredModel.count; i++) {
      if (filteredModel.get(i)._pkg === pkg || filteredModel.get(i).pacmanPkg === pkg) return i
    }
    return -1
  }

  function rowIndexForFlatpak(id) {
    for (var i = 0; i < filteredModel.count; i++) {
      if (filteredModel.get(i).flatpakPkg === id) return i
    }
    return -1
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

  function runInstall(kind, pkg, name) {
    var args
    if (kind === "pacman") args = ["sudo", "pacman", "-S", "--needed", pkg]
    else if (kind === "yay") args = ["yay", "-S", "--needed", pkg]
    else if (kind === "paru") args = ["paru", "-S", "--needed", pkg]
    else args = ["flatpak", "install", "--assumeyes", "flathub", pkg]

    // Resolve the user's terminal (falls back to kitty, matching the shell).
    var term = Quickshell.env("TERMINAL")
    if (!term) term = Quickshell.env("TERMINAL_CMD")
    if (!term) term = "kitty"
    installProc.command = [term, "-e"].concat(args)
    installProc.running = true
  }

  Process {
    id: installProc
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

  onOpenedChanged: if (opened) {
    refreshFocus()
    root.warmGroupIndexes()
  }

  // Builds the AppStream category indexes (pacman + flatpak) once in the
  // background when the panel first opens, so the first group search doesn't
  // stall on a download. The scripts' own staleness checks make this a fast
  // no-op after the first successful build.
  property bool groupsWarmed: false
  function warmGroupIndexes() {
    if (root.groupsWarmed) return
    root.groupsWarmed = true
    var script = "\"" + root.appstreamGroupsScript + "\" ensure \"" + root.iconCacheDir + "\" >/dev/null 2>&1\n"
    script += "python3 \"" + root.flathubGroupsScript + "\" ensure \"" + root.iconCacheDir + "\" >/dev/null 2>&1\n"
    groupWarmProc.command = ["sh", "-c", script]
    groupWarmProc.running = false
    groupWarmProc.running = true
  }

  Process {
    id: groupWarmProc
    running: false
    stdout: StdioCollector { waitForEnd: true }
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
    if (root.isPacman && e.pacmanPkg && e.pacmanPkg !== "") return { kind: "pacman", pkg: e.pacmanPkg }
    if ((root.isPacman || root.isAur) && e.aurPkg && e.aurPkg !== "") return { kind: root.aurHelper, pkg: e.aurPkg }
    if (root.isFlatpak && e.flatpakPkg && e.flatpakPkg !== "") return { kind: "flatpak", pkg: e.flatpakPkg }
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
        RowLayout {
          width: parent.width
          spacing: Style.space(12)

          Text {
            id: heroIcon
            text: "\uf002"
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            Layout.alignment: Qt.AlignVCenter
          }

          Column {
            id: heroLabels
            Layout.alignment: Qt.AlignVCenter
            Layout.fillWidth: true
            spacing: Style.space(2)

            Text {
              text: "FossFetch"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              text: "Browse open-source packages · Pacman + AUR + Flathub"
              color: Util.alpha(Color.popups.text, 0.52)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.0
              width: parent.width
              elide: Text.ElideRight
            }
          }

          // Options gear (top right): toggles the options panel. Shares the
          // accent glow treatment with the tabs and search bar.
          Rectangle {
            id: optionsBtn
            Layout.preferredWidth: Style.space(22)
            Layout.preferredHeight: Style.space(20)
            Layout.alignment: Qt.AlignTop | Qt.AlignCenter
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
              id: optionsIcon
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

            // Design preset picker — five visual styles for the whole panel.
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

            // Buy Me a Coffee — same button used in the mouse & keybind app.
            BorderSurface {
              id: buyButton
              visible: root.showCoffeeButton
              x: (parent.width - width) / 2
              implicitWidth: buyRow.implicitWidth + Style.space(16)
              implicitHeight: Style.space(22)
              radius: Style.cornerRadius
              color: buyHover.hovered ? Util.alpha("#FF813F", 0.22) : Util.alpha("#FF813F", 0.10)
              borderSpec: Border.controlSpec(buyHover.hovered ? "hover-cursor" : "normal", Color.popups.text, Color.popups.text)
              Behavior on color { ColorAnimation { duration: 150 } }

              RowLayout {
                id: buyRow
                anchors.centerIn: parent
                spacing: Style.space(3)

                Text {
                  text: "☕"
                  color: "#FF813F"
                  font.family: Style.font.family
                  font.pixelSize: Style.space(13)
                }
                Text {
                  text: "Buy Me a Coffee"
                  color: buyHover.hovered ? "#FFB347" : "#FF813F"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption - 1
                  font.bold: true
                }
              }

              MouseArea {
                id: buyHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Qt.openUrlExternally("https://www.paypal.com/paypalme/DavidDesousa13")
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

              Keys.onDownPressed: root.moveCursor(0, 1)
              Keys.onUpPressed: root.moveCursor(0, -1)
              Keys.onReturnPressed: root.activateCursor()
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
            spacing: Style.space(6)
            model: filteredModel
            currentIndex: -1
            focus: false

            delegate: Rectangle {
              id: delegateRoot
              required property string name
              required property string description
              required property string rating
              required property string website
              required property string license
              required property string category
              required property string thumbnail
              required property string iconName
              required property string pacmanPkg
              required property string aurPkg
              required property string flatpakPkg
              // Every model row now carries the full role set (see buildModel /
              // onPacmanResults / onFlatpakResults), so these must be `required`
              // for the delegate to bind to the model roles. A non-required
              // property would NOT be auto-bound to its role and would stay at
              // its default "" forever, hiding the live-scraped metadata.
              required property string repo
              required property string version
              required property string arch
              required property string licenses
              required property string updated
              // Live pacman rows carry a package name under _pkg (absent on
              // flatpak rows) used to resolve the row after async work completes.
              required property string _pkg

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
                      text: delegateRoot.name
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
                      text: String(delegateRoot.website).indexOf("github") !== -1
                        ? "GitHub ↗"
                        : "Web ↗"
                      foreground: root.pacmanColor
                      fontFamily: Style.font.family
                      fontSize: Style.font.caption
                      bordered: true
                      Layout.preferredHeight: Style.space(24)
                      Layout.minimumWidth: 0
                      onClicked: Qt.openUrlExternally(delegateRoot.website)
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
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                    }

                    // Flexible spacer pushes the install buttons to the right.
                    Item { Layout.fillWidth: true }

                    InstallButton {
                      visible: root.isPacman && delegateRoot.pacmanPkg !== ""
                      installKind: "pacman"
                      packageName: delegateRoot.pacmanPkg
                      isPending: root.installPending("pacman", delegateRoot.pacmanPkg)
                      onArmed: root.startInstall("pacman", delegateRoot.pacmanPkg, delegateRoot.name)
                    }

                    InstallButton {
                      visible: (root.isPacman || root.isAur) && delegateRoot.aurPkg !== "" && root.aurHelper === "yay"
                      installKind: "yay"
                      packageName: delegateRoot.aurPkg
                      isPending: root.installPending("yay", delegateRoot.aurPkg)
                      onArmed: root.startInstall("yay", delegateRoot.aurPkg, delegateRoot.name)
                    }

                    InstallButton {
                      visible: (root.isPacman || root.isAur) && delegateRoot.aurPkg !== "" && root.aurHelper === "paru"
                      installKind: "paru"
                      packageName: delegateRoot.aurPkg
                      isPending: root.installPending("paru", delegateRoot.aurPkg)
                      onArmed: root.startInstall("paru", delegateRoot.aurPkg, delegateRoot.name)
                    }

                    InstallButton {
                      visible: root.isFlatpak && delegateRoot.flatpakPkg !== ""
                      installKind: "flatpak"
                      packageName: delegateRoot.flatpakPkg
                      isPending: root.installPending("flatpak", delegateRoot.flatpakPkg)
                      onArmed: root.startInstall("flatpak", delegateRoot.flatpakPkg, delegateRoot.name)
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
                text: root.query === ""
                  ? "Search " + (root.isPacman ? "an Arch package"
                    : root.isFlatpak ? "a Flatpak app" : "an AUR package")
                  : "No " + (root.isPacman || root.isAur ? "packages" : "apps") + " found"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                anchors.horizontalCenter: parent.horizontalCenter
              }

              Text {
                text: root.query === ""
                  ? "e.g. gimp, chromecast, vscode, obs, libreoffice"
                  : "Try a different name"
                color: Util.alpha(Color.popups.text, 0.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
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
      }
      Text {
        id: pillLab
        text: pill.label
        color: pill.selected ? Color.accent : Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: pill.selected
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

    signal armed()

    // Fixed-width pill: labels self-size and FitText shrinks the font to fit,
    // so a long AUR package name can never shove the button past the card edge
    // or inflate the row's minimum width.
    implicitWidth: Style.space(120)
    implicitHeight: Style.space(26)

    function branchColor() {
      if (installKind === "pacman") return root.pacmanColor
      if (installKind === "yay" || installKind === "paru") return root.aurColor
      return root.flatpakColor
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: btn.isPending
        ? Util.alpha(root.confirmColor, 0.22)
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
        text: btn.isPending ? "Confirm?" : btn.installKind + " (" + btn.packageName + ")"
        color: btn.isPending ? root.confirmColor : (mouse.containsMouse ? btn.branchColor() : Color.popups.text)
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
      onClicked: btn.armed()
    }
  }
}
