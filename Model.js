// Model.js — pure logic extracted from Panel.qml so it can be unit-tested.
//
// Deliberately ES5 (var / function, no template literals, no arrow functions) so
// this exact file runs unchanged under Qt's QJSEngine inside the panel and
// under Node in tests/model_test.js. Two engines, one implementation — the tests
// cover the code the panel actually executes, not a transliteration of it.
//
// Nothing in here may touch a QML object, the clock, the network or the
// filesystem. Every function is a pure map from arguments to a value; anything
// that needs panel state is passed in explicitly by the caller.

// ----------------------------------------------------------- URL allowlist

// Only plain http(s) may be handed to the external browser. AUR, pacman and
// Flatpak metadata may carry arbitrary URLs, so everything is checked here
// before anything is opened.
function isSafeWebUrl(u) {
    var s = String(u || "").toLowerCase();
    return s.indexOf("https://") === 0 || s.indexOf("http://") === 0;
}

// True only for paths genuinely inside the plugin's cache directory. A bare
// startsWith() would also accept a sibling like ~/.cache/fossfetch-evil or
// ~/.cache/fossfetchX, since those share the prefix — which would let remote
// metadata point Image.source at an arbitrary file the user owns.
function isInsideCache(path, cacheDir) {
    var p = String(path || "");
    var dir = String(cacheDir || "");
    if (dir === "") return false;
    if (p === dir) return false;          // the directory itself, not a file
    return p.indexOf(dir + "/") === 0;
}

// ------------------------------------------------------------------ dates

var MONTH_LABELS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
var MONTH_INDEX = {Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5,
                   Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11};

// Parse either an AUR epoch (seconds) or a pacman build-date line into a Date,
// or null when the input is not a date at all.
//
// Split out of fmtUpdated so the "Updated" sort orders by the SAME instant the
// card displays. Sorting on the formatted string instead would compare "1 Feb
// 2024" against "11 Feb 2024" as text, putting single-digit days last.
//
// pacman prints Build Date in its OWN timezone; AUR RPC LastModified is an
// absolute epoch. Both are rendered in the viewer's local calendar day. (The
// original parsed pacman's local-time fields back through Date.UTC, which
// shifted the date by a day for every user west of Greenwich.)
function parseDate(raw) {
    var s = String(raw === undefined || raw === null ? "" : raw).trim();
    if (!s) return null;
    var d = null;
    if (/^\d+$/.test(s)) {
        // AUR LastModified is an absolute instant, so local time is correct.
        d = new Date(Number(s) * 1000);
    } else {
        var m = s.match(/(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) (\d{1,2}) ([A-Z][a-z]{2}) (\d{4})/);
        if (m) {
            var mn = MONTH_INDEX[m[2]];
            if (mn === undefined) return null;
            d = new Date(Number(m[3]), mn, Number(m[1]));
        } else {
            var iso = s.match(/(\d{4})-(\d{2})-(\d{2})/);
            if (iso) d = new Date(Number(iso[1]), Number(iso[2]) - 1, Number(iso[3]));
        }
    }
    return (d && !isNaN(d.getTime())) ? d : null;
}

function fmtUpdated(raw) {
    var s = String(raw === "" || raw === undefined || raw === null ? "" : raw).trim();
    if (!s) return "";
    var d = parseDate(s);
    if (!d) return s;
    return d.getDate() + " " + MONTH_LABELS[d.getMonth()] + " " + d.getFullYear();
}

// ---------------------------------------------------- rich-text escaping

// Package and app names come from remote metadata, and the card deliberately
// renders everything as PlainText so a crafted name can never become markup.
// Highlighting the match is the one place markup is genuinely useful, so the
// text is escaped FIRST and the only tags in the result are the ones this
// function emits. The query is never interpolated into the output — only its
// length and offset are used to slice the name.
//
// Quotes are escaped as well as the three angle/ampersand characters. They are
// harmless in text content today, but escapeRich is the single choke point for
// every untrusted string that reaches the rich-text sink, so it neutralises the
// full set rather than relying on no caller ever moving text into an attribute.
function escapeRich(s) {
    return String(s)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&apos;");
}

function highlightName(name, query, matchColor) {
    var n = String(name || "");
    var q = String(query || "").toLowerCase().trim();
    if (q === "") return escapeRich(n);
    var idx = n.toLowerCase().indexOf(q);
    if (idx < 0) return escapeRich(n);
    return escapeRich(n.slice(0, idx))
         + '<font color="' + matchColor + '"><b>'
         + escapeRich(n.slice(idx, idx + q.length))
         + "</b></font>"
         + escapeRich(n.slice(idx + q.length));
}

// ------------------------------------------------------- backend framing

// Backends report success/failure with a trailing "STATUS|ok|msg" frame line
// (documented as "one trailing frame" in both backend_*.sh headers).
//
// The frame must be the LAST NON-EMPTY line, not merely the last line that
// happens to start with "STATUS|". Package descriptions come from remote
// metadata and may contain newlines, so a description that embeds its own
// STATUS line could otherwise forge the panel's status. Since the real frame is
// always emitted last, a forged one is always followed by the genuine one and
// loses.
function statusDetail(lines) {
    var i = lines.length - 1;
    while (i >= 0 && String(lines[i]).trim() === "") i--;
    if (i < 0) return "";
    var frame = String(lines[i]).trim();
    if (frame.indexOf("STATUS|") !== 0) return "";
    var rest = frame.substring(7);            // "ok|msg" or "error|msg"
    if (rest.indexOf("ok|") === 0) return ""; // a successful (possibly empty) run is not an error
    if (rest.indexOf("error|") === 0) return rest.substring(6);
    return "";
}

// ---------------------------------------------------------------- ranking

// True when every character of `q` appears in `n`, in order, with the first one
// landing near the start. Two constraints keep it from flooding the ranking:
//   * under 3 characters matches almost any name, so it is rejected outright;
//   * the run must begin in the first three characters, otherwise "zz" style
//     coincidences deep inside a long name would float to the top.
function fuzzySubsequence(q, n) {
    if (q.length < 3) return false;
    var qi = 0;
    var start = -1;
    for (var i = 0; i < n.length && qi < q.length; i++) {
        if (n.charAt(i) !== q.charAt(qi)) continue;
        if (qi === 0) {
            if (i > 2) return false;
            start = i;
        }
        qi++;
    }
    return start >= 0 && qi === q.length;
}

// Lower is better. Exact, prefix, substring, then a punctuation-stripped
// substring (so "gimp 2" finds "gimp2"), then the fuzzy subsequence.
function rank(name, q) {
    var n = String(name).toLowerCase();
    if (n === q) return 0;
    if (n.indexOf(q) === 0) return 1;
    if (n.indexOf(q) !== -1) return 2;
    var base = String(q).replace(/[^a-z0-9]/g, "");
    if (base.length >= 3 && n.indexOf(base) !== -1) return 3;
    if (fuzzySubsequence(q, n)) return 4;
    return 5;
}

// ---------------------------------------------------------- AUR trust chip

// A single chip, worst-first: being flagged out of date by the maintainer
// matters more than a low vote count, and a crowd-maintained package with
// hundreds of votes needs no chip at all.
function trustLabel(e) {
    if (!e) return "";
    if (String(e.aurOutdated || "") !== "") return "⚠ flagged out of date";
    var v = parseInt(e.aurVotes, 10);
    if (isNaN(v)) return "";
    if (v <= 0) return "⚠ unrated";
    if (v < 10) return v + " votes";
    return "";
}

// Is this row AUR-sourced? Used to decide whether the trust chip applies and
// whether the AUR install button is meaningful.
function isAurRow(e) {
    return !!e && String(e.aurPkg || "") !== "";
}


// ------------------------------------------------------- details sheet

// Flatten a pacman dependency field to a list of package names.
//
// The real `pacman -Si` / `-Qi` format is worth encoding precisely rather than
// approximating:
//   * entries are separated by TWO spaces ("bash  acl  curl"),
//   * a version constraint is attached with "=" ("systemd-libs=261.2"),
//   * optional deps may carry a colon description ("apparmor: extra security"),
//   * an empty field prints as "none".
// Splitting on single whitespace would tear "foo>=1.2" into "foo>=1.2" plus a
// stray ">=1.2" token.
function depNames(field) {
    var raw = String(field === undefined || field === null ? "" : field).trim();
    if (raw === "") return [];
    // Two formats reach here: pacman separates entries with TWO spaces, while
    // the AUR info path delivers a comma-joined list. Splitting on only the
    // former silently collapsed every AUR dependency list into one entry
    // ("pacman>6.1, git" read as a single dependency). Package names never
    // contain a comma, so treating one as a separator is safe.
    var parts = raw.split(/(?:\s{2,}|,)/);
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        var part = parts[i].trim();
        if (part === "") continue;
        // "apparmor: additional security features" -> "apparmor"
        var colon = part.indexOf(":");
        if (colon !== -1) part = part.substring(0, colon).trim();
        // First token only, so a trailing description or constraint suffix is
        // not mistaken for another dependency.
        var name = part.split(/\s+/)[0];
        if (name === "") continue;
        if (name.toLowerCase() === "none") continue;
        if (out.indexOf(name) === -1) out.push(name);
    }
    return out;
}

// Why did this row show up? The ranker already knows the answer, so the sheet
// explains the match in the same terms the ranking used rather than inventing a
// second, possibly-contradictory explanation. `inGroup` is supplied by the
// caller because pendingGroup lives on the panel, not here.
function matchReasonFor(name, query, inGroup) {
    var raw = String(name || "");
    var n = raw.toLowerCase();
    var q = String(query || "").toLowerCase().trim();
    if (q === "") {
        if (inGroup) return "Shown by natural-language category match: \"" + String(query).trim() + "\"";
        return "Shown before anything was typed";
    }
    if (n === q) return "Exact name match";
    if (n.indexOf(q) === 0) return "Name starts with \"" + q + "\"";
    if (n.indexOf(q) !== -1) return "Name contains \"" + q + "\"";
    var base = q.replace(/[^a-z0-9]/g, "");
    if (base.length >= 3 && n.indexOf(base) !== -1)
        return "Name matches \"" + q + "\" ignoring punctuation";
    if (fuzzySubsequence(q, n)) return "Fuzzy match \u2014 the letters of \"" + q + "\" in order";
    if (inGroup) return "Shown by natural-language category match: \"" + String(query).trim() + "\"";
    return "Matched through this package's metadata";
}

// ------------------------------------------------------- version comparison
//
// Decides whether the version on offer is genuinely newer than what is
// installed, so a card can offer "Update" honestly. pacman's version scheme is
// not a plain string order, so the comparison is done segment-by-segment the
// way vercmp does it, but simplified to the cases that actually appear in a
// package manager card:
//
//   [epoch:]version[-pkgrel]
//
//   * an "epoch:" prefix (rare, but pacman honours it) is compared as a number
//     and overrides everything after it;
//   * the pkgrel (after the last '-') is compared last;
//   * within a segment, runs of digits compare numerically and runs of letters
//     compare lexically (a rule of thumb that matches rpm/pacman for the
//     letter/digit boundaries we see here).
//
// Deliberately conservative: when the two versions cannot be parsed confidently
// it returns 0 ("no meaningful difference"), so an update is never *offered*
// on the strength of a guess. A missed update prompt is recoverable; telling
// someone to update a package that is already current is not.
function splitVersion(v) {
    var s = String(v === undefined || v === null ? "" : v).trim();
    if (s === "") return null;
    var epoch = 0;
    var colon = s.indexOf(":");
    if (colon !== -1) {
        var e = s.substring(0, colon);
        if (/^\d+$/.test(e)) { epoch = parseInt(e, 10); s = s.substring(colon + 1); }
    }
    var release = null;
    var dash = s.lastIndexOf("-");
    if (dash !== -1) { release = s.substring(dash + 1); s = s.substring(0, dash); }
    return { epoch: epoch, version: s, release: release === null ? "" : release };
}

function cmpSegment(a, b) {
    // Walk both segments, comparing digit-runs numerically and letter-runs
    // lexically, exactly the way vercmp classifies each character.
    var re = /(\d+|[A-Za-z]+)/g;
    var ta = a.match(re) || [];
    var tb = b.match(re) || [];
    var n = Math.max(ta.length, tb.length);
    for (var i = 0; i < n; i++) {
        var x = ta[i], y = tb[i];
        if (x === undefined) return -1;
        if (y === undefined) return 1;
        var xn = /^\d+$/.test(x), yn = /^\d+$/.test(y);
        if (xn && yn) {
            var dx = parseInt(x, 10), dy = parseInt(y, 10);
            if (dx !== dy) return dx < dy ? -1 : 1;
        } else if (xn !== yn) {
            // A numeric run outranks an alphabetic one at the same position.
            return xn ? 1 : -1;
        } else {
            if (x !== y) return x < y ? -1 : 1;
        }
    }
    return 0;
}

// Returns 1 if `avail` is strictly newer than `inst`, -1 if older, 0 if equal
// or not confidently comparable.
function compareVersions(avail, inst) {
    var a = splitVersion(avail), b = splitVersion(inst);
    if (!a || !b) return 0;
    if (a.epoch !== b.epoch) return a.epoch < b.epoch ? -1 : 1;
    var c = cmpSegment(a.version, b.version);
    if (c !== 0) return c;
    if (a.release === "" || b.release === "") return 0;
    return cmpSegment(a.release, b.release);
}

// True only when the package is installed AND the offered version is strictly
// newer. Identical or unparseable versions return false, so the card stays a
// plain "Installed" pill rather than claiming an update that is not one.
function needsUpdate(avail, inst) {
    var installed = String(inst === undefined || inst === null ? "" : inst).trim();
    var available = String(avail === undefined || avail === null ? "" : avail).trim();
    if (installed === "" || available === "") return false;
    if (installed === available) return false;
    return compareVersions(available, installed) === 1;
}

// ---------------------------------------------------------- sort and filter

// Sort modes in cycle order (Ctrl+S walks this list).
//
// "relevance" is not a comparator over any field — it restores the order the
// rows arrived in, which each backend already ranked: exact name hit, then
// prefix, substring, fuzzy, with AppStream category members boosted. That
// ranking knows the user's query in a way no stored key can reproduce, so it
// must never be re-derived. But it MUST be restorable: without an explicit
// insertion order, sorting by name throws the backend's ranking away and
// "Relevance" becomes a no-op that can never undo the change, which reads to
// the user as a sort that silently does nothing.
var SORT_MODES = ["relevance", "popularity", "updated", "name"];

// Exposed as a FUNCTION, not read straight off the array. A `.js` imported into
// QML with `import "Model.js" as Model` exposes the script's top-level vars and
// functions as the namespace — `module.exports` only exists for the Node test
// harness. So the panel must call this; reading `Model.SORT_MODES` works in Node
// and is silently `undefined` in QML, which is exactly how the settings load
// ended up throwing inside its try/catch and quietly dropping every preference.
function sortModes() { return SORT_MODES; }

// Comparable key for the "Updated" sort, or -1 when the row has no date.
// Missing sorts LAST, not first: a row with no build time is not the newest
// package, and putting it on top would make an absent field look like a claim.
function updatedKey(raw) {
    var d = parseDate(raw);
    return d ? d.getTime() : -1;
}

// Comparable key for AUR Popularity, which the RPC already reports as a 0..1
// fraction of AUR users running the package. -1 for missing so that every
// pacman and Flathub row — and any AUR row whose payload omitted the field —
// sinks below rows that carry a real measurement instead of tying with them.
function popularityKey(raw) {
    var s = String(raw === undefined || raw === null ? "" : raw).trim();
    if (s === "") return -1;
    var n = parseFloat(s);
    return isNaN(n) ? -1 : n;
}

function rowName(row) {
    return String(row && row.name ? row.name : "").toLowerCase();
}

// Name ascending, case-folded. The default String comparison puts every
// capitalised name ("Zoom") ahead of every lowercase one ("apache"), which
// reads as a broken alphabet to anyone scanning the column.
function byName(a, b) {
    var an = rowName(a), bn = rowName(b);
    if (an < bn) return -1;
    if (an > bn) return 1;
    return 0;
}

function byPopularity(a, b) {
    var d = popularityKey(b.aurPopularity) - popularityKey(a.aurPopularity);
    return d !== 0 ? d : byName(a, b);
}

function byUpdated(a, b) {
    var d = updatedKey(b.updated) - updatedKey(a.updated);
    return d !== 0 ? d : byName(a, b);
}

// Insertion order, assigned once when a row is admitted. Sorting by it
// reproduces exactly the sequence the backends produced, which is what makes
// Relevance a real mode rather than a no-op. Rows that predate the field (or
// arrive without one) all compare equal, and the sort stays stable, so an
// older caller still gets the backend order rather than a scramble.
function orderKey(row) {
    var v = row && row._order;
    var n = parseInt(v, 10);
    return isNaN(n) ? 0 : n;
}

function byOrder(a, b) {
    var d = orderKey(a) - orderKey(b);
    return d !== 0 ? d : byName(a, b);
}

// True when at least one row actually carries the field a mode sorts on.
//
// This matters more than it looks. Sorting the Pacman results by "Popularity"
// finds no popularity on ANY row, so every pair ties and the comparator falls
// through to the name tiebreak — producing alphabetical order under a
// popularity label. Two different modes, one ordering, no visible difference:
// the sort looks broken even though it ran. Refusing to reorder when there is
// nothing to compare is the honest answer.
function anyField(rows, key) {
    for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        if (!r) continue;
        if (key === "updated" ? updatedKey(r.updated) >= 0 : popularityKey(r.aurPopularity) >= 0)
            return true;
    }
    return false;
}

// Reorder a result set for a sort mode. Returns a NEW array; the caller's is
// never mutated, so the caller can keep the pre-sort order for comparison.
//
// Every comparator ends in byName, so rows that tie on the sort key fall back
// to a stable alphabetical order instead of whatever order the engine's sort
// happened to leave them in. Without that, two rows with no build date would
// be free to swap places between two otherwise identical runs.
function sortRows(rows, mode) {
    var arr = [];
    var n = rows ? rows.length : 0;
    for (var i = 0; i < n; i++) arr.push(rows[i]);
    var m = String(mode === undefined || mode === null ? "relevance" : mode);
    if (m === "relevance") {
        // Restore the backend ranking rather than inventing one.
        arr.sort(byOrder);
    } else if (m === "popularity") {
        if (anyField(arr, "popularity")) arr.sort(byPopularity);
    } else if (m === "updated") {
        if (anyField(arr, "updated")) arr.sort(byUpdated);
    } else if (m === "name") {
        arr.sort(byName);
    }
    return arr;
}

// Installed by ANY of the three sources. A package offered by both a repo and
// the AUR is one installed package, not two — otherwise "hide installed" would
// leave a duplicate card behind for the package you just filtered out.
function isInstalledRow(row) {
    if (!row) return false;
    return String(row.installedPacman || "") === "1"
        || String(row.installedAur || "") === "1"
        || String(row.installedFlatpak || "") === "1";
}

function passesFilter(row, opts) {
    if (!row) return false;
    if (opts && opts.hideInstalled && isInstalledRow(row)) return false;
    return true;
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        isSafeWebUrl: isSafeWebUrl,
        isInsideCache: isInsideCache,
        fmtUpdated: fmtUpdated,
        parseDate: parseDate,
        escapeRich: escapeRich,
        highlightName: highlightName,
        statusDetail: statusDetail,
        fuzzySubsequence: fuzzySubsequence,
        rank: rank,
        trustLabel: trustLabel,
        isAurRow: isAurRow,
        depNames: depNames,
        matchReasonFor: matchReasonFor,
        splitVersion: splitVersion,
        compareVersions: compareVersions,
        needsUpdate: needsUpdate,
        sortModes: sortModes,
        sortRows: sortRows,
        orderKey: orderKey,
        updatedKey: updatedKey,
        popularityKey: popularityKey,
        isInstalledRow: isInstalledRow,
        passesFilter: passesFilter
    };
}