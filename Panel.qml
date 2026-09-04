import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// FossFetch browse panel. Two search-driven tabs list FOSS apps — Pacman
// (Arch repos) and Flatpak (Flathub) — each with one-click install. Results
// come straight from live `pacman -Ss` / `flatpak search`; metadata (repo,
// version, arch, license) and a website/GitHub link are enriched via
// `pacman -Si` / Flatpak appstream info.
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

  // --------------------------------------------------------------- tabs
  property int activeTab: 0
  readonly property bool isPacman: activeTab === 0
  property string query: ""

  function switchTab(t) {
    if (activeTab === t) return
    activeTab = t
    resultsList.currentIndex = -1
    rebuildResults()
    refreshFocus()
  }

  function tabLabel()        { return isPacman ? "Arch repos (Pacman)" : "Flathub (Flatpak)" }
  function tabCaption()      { return isPacman ? "Search pacman packages" : "Search Flatpak apps" }
  function tabPlaceholder()  { return isPacman ? "Search Arch package… (gimp, obs, audacity)" : "Search a Flatpak app… (gimp, obs, libreoffice)" }

  function resolveThumb(remote, iconName) {
    if (remote !== "") return remote
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

  function launchLiveSearch(q) {
    var seq = ++searchSeq
    if (isPacman) {
      pacmanProc.mySeq = seq
      pacmanProc.running = false
      pacmanProc.command = ["pacman", "-Ss", q]
      pacmanProc.running = true
    } else {
      flatpakProc.mySeq = seq
      flatpakProc.running = false
      flatpakProc.command = ["flatpak", "search", "--columns=name,description,application,version", q]
      flatpakProc.running = true
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
    parsed.sort(function(a, b) {
      var ra = root.pacmanRank(a.name, q)
      var rb = root.pacmanRank(b.name, q)
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
  // locally-installed icon (fast, via per-row filesystem lookup); the rest get
  // a Flathub icon via a SINGLE batched `flatpak search` per query (mapped by
  // name), avoiding one slow serialized search per row.
  property var enrichQueue: []
  property var flatpakQueue: []
  property bool enrichBusy: false

  function enqueueEnrich() {
    enrichQueue = []
    flatpakQueue = []
    for (var i = 0; i < filteredModel.count; i++) {
      var e = filteredModel.get(i)
      if (!e || e.thumbnail !== "" || e.iconName !== "" || e._pkg === undefined || e._pkg === "") continue
      enrichQueue.push({ index: i, name: e.name, pkg: e._pkg })
    }
    pumpEnrich()
  }

  // Drain local-icon lookups in ONE batched subprocess, then run a single
  // batched flathub search for the rows still lacking icons.
  function pumpEnrich() {
    if (enrichBusy) return
    if (enrichQueue.length > 0) {
      enrichBusy = true
      lookupLocalIcons()
      return
    }
    // Local pass done — list the remaining rows that still lack icons and run
    // one flatpak search for all of them at once.
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
  // rows fall through to the batched flathub lookup).
  function lookupLocalIcons() {
    var names = []
    for (var i = 0; i < enrichQueue.length; i++)
      if (names.indexOf(enrichQueue[i].pkg) === -1) names.push(enrichQueue[i].pkg)
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
            for (var k = 0; k < root.enrichQueue.length; k++)
              if (root.enrichQueue[k].pkg === parts[1]) { root.flatpakQueue.push(root.enrichQueue[k]); break }
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
      if (repo !== "") filteredModel.setProperty(idx, "repo", repo)
      if (version !== "") filteredModel.setProperty(idx, "version", version)
      if (arch !== "") filteredModel.setProperty(idx, "arch", arch)
      if (desc !== "") filteredModel.setProperty(idx, "description", desc)
      if (url !== "") filteredModel.setProperty(idx, "website", url)
      if (licenses !== "") filteredModel.setProperty(idx, "licenses", licenses)
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
    else if (kind === "aur") args = ["paru", "-S", "--needed", pkg]
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

  onOpenedChanged: if (opened) refreshFocus()

  // --------------------------------------------------------------- keyboard
  function moveCursor(dx, dy) {
    if (filteredModel.count === 0) return
    var idx = resultsList.currentIndex
    var n = filteredModel.count
    if (dy !== 0) idx = Math.max(0, Math.min(n - 1, idx + dy))
    resultsList.currentIndex = idx
    resultsList.positionViewAtIndex(idx, ListView.Center)
  }

  function activateCursor() {
    if (filteredModel.count === 0) return
    var idx = resultsList.currentIndex
    if (idx < 0 || idx >= filteredModel.count) return
    var e = filteredModel.get(idx)
    if (e.website) Qt.openUrlExternally(e.website)
  }

  // Tab cycles the two tabs (0 <-> 1).
  function switchPanel(direction) {
    switchTab(direction > 0 ? 1 - activeTab : 1 - activeTab)
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
              text: "Browse open-source packages · Pacman + Flathub"
              color: Util.alpha(Color.popups.text, 0.52)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.0
              width: parent.width
              elide: Text.ElideRight
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
              onClicked: root.switchTab(0)
            }

            TabButton {
              id: flatpakTabBtn
              text: "Flatpak"
              active: root.activeTab === 1
              Layout.fillWidth: true
              Layout.fillHeight: true
              onClicked: root.switchTab(1)
            }
          }
        }

        PanelSeparator {
          foreground: Color.popups.text
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
              color: isSelected
                ? Color.menu.selectedBackground
                : (isHovered ? Util.alpha(Color.popups.text, 0.05) : "transparent")
              border.width: isSelected ? Border.uniformWidth(root.selectedBorderSpec) : 0
              border.color: isSelected ? Border.color(root.selectedBorderSpec) : "transparent"

              RowLayout {
                id: delegateRow
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: 0

                Item {
                  id: thumbWrap
                  Layout.preferredWidth: 44
                  Layout.preferredHeight: 44
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

                    Text {
                      text: delegateRoot.name
                      color: Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: true
                      font.letterSpacing: 0.5
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }

                    Button {
                      visible: delegateRoot.website !== ""
                      text: String(delegateRoot.website).indexOf("github") !== -1
                        ? "GitHub ↗"
                        : "Web ↗"
                      foreground: "#a6e3a1"
                      fontFamily: Style.font.family
                      fontSize: Style.font.caption
                      bordered: true
                      Layout.preferredHeight: Style.space(24)
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
                        font.pixelSize: Style.font.caption - 1
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
                    // Hard-cap the height so it can never overflow the fixed
                    // card height (in this runtime implicitHeight is computed
                    // pathologically large, which would otherwise blow up the
                    // ColumnLayout, squash the description and push the install
                    // buttons off the bottom of the card).
                    Layout.preferredHeight: Style.space(32)
                    Layout.maximumHeight: Style.space(32)
                    Layout.minimumHeight: Style.space(16)
                    clip: true
                    color: Util.alpha(Color.popups.text, 0.62)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption - 1
                    lineHeight: Style.space(16)
                    text: root.detailPoints(delegateRoot).join("\n")
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                  }

                  // Row 4: Install buttons (bottom-right of the card)
                  RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(2)
                    spacing: Style.space(8)

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
                      visible: root.isPacman && delegateRoot.aurPkg !== ""
                      installKind: "aur"
                      packageName: delegateRoot.aurPkg
                      isPending: root.installPending("aur", delegateRoot.aurPkg)
                      onArmed: root.startInstall("aur", delegateRoot.aurPkg, delegateRoot.name)
                    }

                    InstallButton {
                      visible: !root.isPacman && delegateRoot.flatpakPkg !== ""
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
                  ? "Search " + (root.isPacman ? "an Arch package" : "a Flatpak app")
                  : "No " + (root.isPacman ? "packages" : "apps") + " found"
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
  component InstallButton: Item {
    id: btn
    property string installKind: ""
    property string packageName: ""
    property bool isPending: false

    signal armed()

    implicitWidth: label.implicitWidth + 8
    implicitHeight: Style.space(26)

    function branchColor() {
      if (installKind === "pacman") return "#a6e3a1"
      if (installKind === "aur") return "#94e2d5"
      return "#89b4fa"
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: btn.isPending
        ? Util.alpha("#f9e2af", 0.22)
        : (mouse.containsMouse ? Util.alpha(btn.branchColor(), 0.2) : Util.alpha(Color.popups.text, 0.06))
      border.width: Style.spacing.hairline
      border.color: btn.isPending
        ? "#f9e2af"
        : (mouse.containsMouse ? Util.alpha(btn.branchColor(), 0.6) : Util.alpha(Color.popups.text, 0.18))

      Text {
        id: label
        anchors.centerIn: parent
        text: btn.isPending ? "Confirm?" : btn.installKind + " (" + btn.packageName + ")"
        color: btn.isPending ? "#f9e2af" : (mouse.containsMouse ? btn.branchColor() : Color.popups.text)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
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
