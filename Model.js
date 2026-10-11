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

// pacman prints Build Date in its OWN timezone; AUR RPC LastModified is an
// absolute epoch. Both are rendered in the viewer's local calendar day. (The
// original parsed pacman's local-time fields back through Date.UTC, which
// shifted the date by a day for every user west of Greenwich.)
function fmtUpdated(raw) {
    var s = String(raw || "").trim();
    if (!s) return "";
    var d = null;
    if (/^\d+$/.test(s)) {
        // AUR LastModified is an absolute instant, so local time is correct.
        d = new Date(Number(s) * 1000);
    } else {
        var m = s.match(/(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) (\d{1,2}) ([A-Z][a-z]{2}) (\d{4})/);
        if (m) {
            var months = {Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5,
                          Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11};
            var mn = months[m[2]];
            if (mn !== undefined) d = new Date(Number(m[3]), mn, Number(m[1]));
        } else {
            var iso = s.match(/(\d{4})-(\d{2})-(\d{2})/);
            if (iso) d = new Date(Number(iso[1]), Number(iso[2]) - 1, Number(iso[3]));
        }
    }
    if (!d || isNaN(d.getTime())) return s;
    var labels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    return d.getDate() + " " + labels[d.getMonth()] + " " + d.getFullYear();
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
    var parts = raw.split(/\s{2,}/);
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

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        isSafeWebUrl: isSafeWebUrl,
        isInsideCache: isInsideCache,
        fmtUpdated: fmtUpdated,
        escapeRich: escapeRich,
        highlightName: highlightName,
        statusDetail: statusDetail,
        fuzzySubsequence: fuzzySubsequence,
        rank: rank,
        trustLabel: trustLabel,
        isAurRow: isAurRow,
        depNames: depNames,
        matchReasonFor: matchReasonFor
    };
}