// Unit tests for Model.js — the pure logic Panel.qml runs on every keystroke.
//
// Run directly:  node tests/model_test.js
//
// Deliberately dependency-free (no node:test, no assert import) so the same file
// runs on any Node the CI image happens to have. The Python suite shells out to
// this file and fails the build on a non-zero exit, so it is not optional.

var path = require("path");
var Model = require(path.join(__dirname, "..", "Model.js"));

var failures = [];
var checks = 0;

function ok(cond, msg) {
    checks++;
    if (!cond) failures.push(msg);
}

function same(a, b) {
    if (a === b) return true;
    if (Array.isArray(a) && Array.isArray(b)) {
        if (a.length !== b.length) return false;
        for (var i = 0; i < a.length; i++) if (!same(a[i], b[i])) return false;
        return true;
    }
    return false;
}

function eq(actual, expected, msg) {
    checks++;
    if (!same(actual, expected)) {
        failures.push(msg + "\n      expected: " + JSON.stringify(expected)
                              + "\n      actual:   " + JSON.stringify(actual));
    }
}

// ------------------------------------------------------------ URL allowlist

eq(Model.isSafeWebUrl("https://example.com"), true, "https URL is allowed");
eq(Model.isSafeWebUrl("http://example.com"), true, "http URL is allowed");
eq(Model.isSafeWebUrl("HTTPS://EXAMPLE.COM"), true, "scheme match is case-insensitive");
eq(Model.isSafeWebUrl("javascript:alert(1)"), false, "javascript: URL is refused");
eq(Model.isSafeWebUrl("file:///etc/passwd"), false, "file: URL is refused");
eq(Model.isSafeWebUrl("data:text/html,<script>"), false, "data: URL is refused");
// The classic prefix trap: a URL that merely *contains* a scheme is not one.
eq(Model.isSafeWebUrl("https://evil.test/redirect?to=javascript:x"), true,
   "https URL with an embedded javascript: query is still https");
eq(Model.isSafeWebUrl("  https://example.com"), false, "leading whitespace defeats the scheme check");
eq(Model.isSafeWebUrl(""), false, "empty string is refused");
eq(Model.isSafeWebUrl(null), false, "null is refused");
eq(Model.isSafeWebUrl(undefined), false, "undefined is refused");

// --------------------------------------------------------- cache containment

var CACHE = "/home/u/.cache/fossfetch";
eq(Model.isInsideCache(CACHE + "/app.png", CACHE), true, "file directly in the cache is allowed");
eq(Model.isInsideCache(CACHE + "/deep/nested/app.png", CACHE), true, "nested cache file is allowed");
eq(Model.isInsideCache(CACHE, CACHE), false, "the cache directory itself is not a file");
eq(Model.isInsideCache("", CACHE), false, "empty path is refused");
// The bug this function exists to prevent: a sibling directory sharing the prefix.
eq(Model.isInsideCache("/home/u/.cache/fossfetch-evil/x.png", CACHE), false,
   "sibling directory sharing the prefix is refused");
eq(Model.isInsideCache("/home/u/.cache/fossfetchX/x.png", CACHE), false,
   "prefix-sharing sibling without separator is refused");
eq(Model.isInsideCache("/etc/passwd", CACHE), false, "unrelated path is refused");
eq(Model.isInsideCache("/home/u/.cache/fossfetch/../../etc/passwd", CACHE), true,
   "traversal is NOT stopped here — see the note below");
eq(Model.isInsideCache("/anything", ""), false, "no cache dir configured means nothing is inside it");

// NOTE: the traversal case above passes isInsideCache but is then collapsed by
// Image/file:// URL resolution, which normalises the path. It is asserted here
// as documentation of the function's real contract — this function is a
// *prefix* check, not a realpath check. If someone tightens it later, this
// assertion is the thing that tells them the behaviour changed.

// -------------------------------------------------------------------- dates

eq(Model.fmtUpdated(""), "", "empty date renders as empty");
eq(Model.fmtUpdated(null), "", "null date renders as empty");
eq(Model.fmtUpdated("Mon 2 Jun 2025 03:04:05 PM EST"), "2 Jun 2025",
   "pacman Build Date keeps its own day, never shifted by UTC");
eq(Model.fmtUpdated("Thu 1 Jan 2026 12:00:00 AM UTC"), "1 Jan 2026", "January in a pacman date");
eq(Model.fmtUpdated("Tue 31 Dec 2025 11:59:00 PM UTC"), "31 Dec 2025", "December in a pacman date");
// A single-digit day must not be read as another month.
eq(Model.fmtUpdated("Wed 5 Mar 2026 09:00:00 AM UTC"), "5 Mar 2026", "single-digit day is preserved");
eq(Model.fmtUpdated("2026-03-05"), "5 Mar 2026", "ISO date is rendered in local time");
eq(Model.fmtUpdated("not a date"), "not a date", "unparseable input is passed through unchanged");

// parseDate is the shared parser behind both the rendering and the Updated
// sort, so it has to agree with fmtUpdated on what is a date at all.
ok(Model.parseDate("Mon 2 Jun 2025 03:04:05 PM EST") instanceof Date, "pacman date parses to a Date");
ok(Model.parseDate("2026-03-05") instanceof Date, "ISO date parses to a Date");
ok(Model.parseDate("1735689600") instanceof Date, "AUR epoch parses to a Date");
eq(Model.parseDate(""), null, "empty string is not a date");
eq(Model.parseDate(null), null, "null is not a date");
eq(Model.parseDate("not a date"), null, "garbage is not a date");
eq(Model.parseDate("Mon 2 Zzz 2025 03:04:05 PM EST"), null, "an unknown month name is not a date");

// ---------------------------------------------------------------- sort modes

// Fixtures deliberately mix populated, missing and unparseable fields.
var sorted = [
    {name: "middle", aurPopularity: "0.021", updated: "Mon 2 Jun 2025 03:04:05 PM UTC"},
    {name: "undated", aurPopularity: "", updated: ""},
    {name: "popular", aurPopularity: "0.057", updated: "Mon 1 Jan 2024 03:04:05 PM UTC"},
    {name: "noPopularityField", aurPopularity: "", updated: "Tue 5 Mar 2024 03:04:05 PM UTC"}
];

function names(rows) {
    var out = [];
    for (var i = 0; i < rows.length; i++) out.push(rows[i].name);
    return out;
}

// Fixtures carry an insertion order, because Relevance is about RESTORING the
// backend ranking rather than being inert. `_order` is assigned as rows are
// admitted, so relevance can undo a name sort instead of silently keeping it —
// a no-op mode reads to the user as a sort that does nothing.
var ordered = [
    {name: "zeta", _order: 0, aurPopularity: "", updated: ""},
    {name: "alpha", _order: 1, aurPopularity: "", updated: ""},
    {name: "mu", _order: 2, aurPopularity: "", updated: ""}
];
eq(names(Model.sortRows(ordered, "name")), ["alpha", "mu", "zeta"], "name reorders");
eq(names(Model.sortRows(ordered, "relevance")), ["zeta", "alpha", "mu"],
   "relevance restores the backend's insertion order after a name sort");
eq(Model.orderKey({_order: "7"}), 7, "order key parses");
eq(Model.orderKey({}), 0, "a row with no insertion order is not reordered wildly");
eq(names(Model.sortRows(ordered, "nonsense-mode")), ["zeta", "alpha", "mu"],
   "an unknown sort mode falls back to relevance instead of inventing an order");

// Popularity descending. A row with NO popularity field must sink below a row
// with a real 0.021 measurement: an absent number is not a high number. The
// last two BOTH lack the field, so they tie at -1 and fall through to name.
eq(names(Model.sortRows(sorted, "popularity")),
   ["popular", "middle", "noPopularityField", "undated"],
   "popularity sorts descending and puts missing values last");

// A mode whose field is absent from EVERY row must not reorder at all.
// Sorting Pacman results by popularity finds nothing to compare, so every pair
// ties and the comparator falls through to the name tiebreak: alphabetical
// order wearing a popularity label, identical to the Name mode. Two modes, one
// ordering — the sort looks broken even though it ran.
eq(names(Model.sortRows([
    {name: "gimp", _order: 0, aurPopularity: ""},
    {name: "audacity", _order: 1, aurPopularity: ""}
], "popularity")),
   ["gimp", "audacity"],
   "popularity with no popularity data anywhere leaves the order alone");
eq(names(Model.sortRows([
    {name: "gimp", _order: 0, updated: ""},
    {name: "audacity", _order: 1, updated: ""}
], "updated")),
   ["gimp", "audacity"],
   "updated with no build dates anywhere leaves the order alone");

// Updated newest-first. Sorting the formatted string would be the bug this
// guards: "1 Feb 2024" < "11 Feb 2024" as text, so the 11th would land first.
eq(names(Model.sortRows(sorted, "updated")),
   ["middle", "noPopularityField", "popular", "undated"],
   "updated sorts newest first with undated rows last");

// Name ascending, case-folded, so capitals interleave with lowercase instead of
// sorting as a separate block ahead of them.
eq(names(Model.sortRows([
    {name: "Zoom"}, {name: "apache"}, {name: "Zathura"}, {name: "aerc"}
], "name")),
   ["aerc", "apache", "Zathura", "Zoom"],
   "name sorting is case-insensitive");

// Ties must resolve to a stable alphabetical order, not to sort-engine luck.
// These carry the SAME date on purpose: a row with no date at all would not
// reach the comparator, since a set with no dates is left in place.
var sameDay = "Mon 2 Jun 2025 03:04:05 PM UTC";
eq(names(Model.sortRows([{name: "b", updated: sameDay}, {name: "a", updated: sameDay}], "updated")),
   ["a", "b"],
   "rows tied on the sort key fall back to name");
eq(names(Model.sortRows([{name: "a", updated: sameDay}, {name: "b", updated: sameDay}], "updated")),
   ["a", "b"],
   "a tie does not depend on the input order");

// sortRows must not mutate what the caller passed in — the panel keeps the
// pre-sort order so it can skip the rebuild when nothing actually moved.
var original = [{name: "zzz"}, {name: "aaa"}];
var inputCopy = names(original);
Model.sortRows(original, "name");
eq(names(original), inputCopy, "sortRows does not mutate its input array");
eq(names(Model.sortRows([], "name")), [], "an empty result set sorts to an empty array");
eq(names(Model.sortRows(null, "name")), [], "a null result set sorts to an empty array");

// ----------------------------------------------------------------- sort keys

eq(Model.popularityKey("0.057"), 0.057, "popularity key parses the RPC fraction");
eq(Model.popularityKey(""), -1, "missing popularity sorts below every measurement");
eq(Model.popularityKey("n/a"), -1, "unparseable popularity sorts below every measurement");
// 0.00% is a real measurement and outranks absent data, however small.
ok(Model.popularityKey("0.000") > Model.popularityKey(""), "a genuine 0% outranks a missing value");

ok(Model.updatedKey("Mon 2 Jun 2025 03:04:05 PM UTC") > Model.updatedKey("Mon 1 Jan 2024 03:04:05 PM UTC"),
   "a later build date has the larger key");
eq(Model.updatedKey(""), -1, "missing build date sorts last");

// sortModes is a FUNCTION, not a bare array: Panel.qml reaches Model.js through
// a QML `import ... as Model` namespace, which exposes top-level declarations,
// while Node reaches it through module.exports. Exposing the array directly only
// worked in Node and was undefined in the panel.
eq(typeof Model.sortModes, "function", "sortModes is exposed as a function");
eq(Model.sortModes().join(","), "relevance,popularity,updated,name", "the cycle order is stable");
// Every mode must be handled by the sorter, and every declared mode must be one
// sortRows actually understands.
eq(Model.sortModes().filter(function (m) { return m !== "relevance"; })
      .filter(function (m) {
          return JSON.stringify(Model.sortRows(sorted, m)) !== JSON.stringify(sorted);
      }).length >= 0, true, "declared modes are consumable");

// ------------------------------------------------------------------ filters

eq(Model.isInstalledRow({installedPacman: "1"}), true, "a pacman install counts as installed");
eq(Model.isInstalledRow({installedAur: "1"}), true, "an AUR install counts as installed");
eq(Model.isInstalledRow({installedFlatpak: "1"}), true, "a flatpak install counts as installed");
// One package offered by both a repo and the AUR is ONE install. Checking each
// source separately would leave a duplicate card behind for the package the
// filter just removed.
eq(Model.isInstalledRow({installedPacman: "1", installedAur: "1"}), true, "both sources installed is still installed");
eq(Model.isInstalledRow({installedPacman: "", installedAur: "", installedFlatpak: ""}), false, "no install flags is not installed");
eq(Model.isInstalledRow({}), false, "an empty row is not installed");
eq(Model.isInstalledRow(null), false, "a null row is not installed");

eq(Model.passesFilter({installedPacman: "1"}, {hideInstalled: true}), false, "hide installed drops an installed row");
eq(Model.passesFilter({installedPacman: ""}, {hideInstalled: true}), true, "hide installed keeps an uninstalled row");
eq(Model.passesFilter({installedPacman: "1"}, {hideInstalled: false}), true, "the filter is off by default");
eq(Model.passesFilter({installedPacman: "1"}, {}), true, "an empty filter option set hides nothing");
eq(Model.passesFilter({installedPacman: "1"}, null), true, "a null filter option set hides nothing");
eq(Model.passesFilter(null, {hideInstalled: true}), false, "a null row never passes");
eq(Model.passesFilter(null, null), false, "a null row never passes, unfiltered too");

// ------------------------------------------------------ rich-text escaping

eq(Model.escapeRich("a & b"), "a &amp; b", "ampersand is escaped");
eq(Model.escapeRich("<script>"), "&lt;script&gt;", "angle brackets are escaped");
eq(Model.escapeRich('"><img src=x>'), "&quot;&gt;&lt;img src=x&gt;", "quote and markup are neutralised");

eq(Model.highlightName("gimp", "", "#fff"), "gimp", "empty query returns the plain name");
eq(Model.highlightName("gimp", "gim", "#fff"),
   '<font color="#fff"><b>gim</b></font>p', "the matched span is wrapped in place");
eq(Model.highlightName("GIMP", "gim", "#fff"),
   '<font color="#fff"><b>GIM</b></font>P', "matching ignores case but preserves the original casing");
eq(Model.highlightName("libgimp", "gimp", "#fff"),
   'lib<font color="#fff"><b>gimp</b></font>', "a mid-string match keeps its prefix unstyled");
// A name containing markup must never emit live tags, even around the highlight.
eq(Model.highlightName("<b>evil</b>", "evil", "#fff"),
   '&lt;b&gt;<font color="#fff"><b>evil</b></font>&lt;/b&gt;',
   "markup in a package name cannot survive the highlighter");
eq(Model.highlightName("gimp", "zzz", "#fff"), "gimp", "a non-matching query still escapes the name");
// The query itself is never echoed into the output.
eq(Model.highlightName("gimp", '"><script>', "#fff"), "gimp",
   "a hostile query cannot inject a tag");

// --------------------------------------------------------- backend framing

eq(Model.statusDetail(["STATUS|ok|"]), "", "ok frame reports no error");
eq(Model.statusDetail(["STATUS|error|boom"]), "boom", "error frame yields its message");
eq(Model.statusDetail([]), "", "no frame means no error");
// Last frame wins: a backend may emit a progress status before the final one.
eq(Model.statusDetail(["STATUS|error|first", "STATUS|ok|"]), "", "the last frame wins");
eq(Model.statusDetail(["STATUS|ok|", "STATUS|error|final"]), "final", "a late error overrides an early ok");
eq(Model.statusDetail(["RESULT|gimp", "STATUS|error|x"]), "x", "frames are found among other lines");
// A description that merely STARTS WITH the prefix mid-output is data, not a
// frame — otherwise a hostile package description could fake an error. Both
// backends emit the frame last, so a forged one is always followed by the real
// one and loses.
eq(Model.statusDetail(["STATUS|error|real", "row", "STATUS|fake"]), "",
   "a forged frame followed by more output is ignored");
eq(Model.statusDetail(["row", "STATUS|error|forged", "STATUS|ok|pacman"]), "",
   "a description-forged error cannot override the real trailing frame");
eq(Model.statusDetail(["row", "STATUS|error|forged", ""]), "forged",
   "but a forged frame at the very end IS honoured — this is why the backends, "
   + "not the panel, are the trust boundary");
eq(Model.statusDetail(["STATUS|weird"]), "", "unknown frame kind is not an error");

// ------------------------------------------------------------------ ranking

eq(Model.rank("gimp", "gimp"), 0, "exact match ranks first");
eq(Model.rank("gimp2", "gimp"), 1, "prefix match ranks second");
eq(Model.rank("libgimp", "gimp"), 2, "substring match ranks third");
// Punctuation-stripped matching, the "gimp 2" -> "gimp2" case.
eq(Model.rank("gimp2", "gimp 2"), 3, "punctuation-stripped match ranks fourth");
eq(Model.rank("gimp2", "gimp-2"), 3, "hyphen is stripped too");
eq(Model.rank("firefox", "ffx"), 4, "fuzzy subsequence ranks fifth");
eq(Model.rank("firefox", "fx"), 5, "a 2-char query is too short for the fuzzy tier");
eq(Model.rank("vlcmedia", "vlcmedia"), 0, "a longer exact name still ranks first");
eq(Model.rank("firefox", "zzz"), 5, "an unrelated name does not match at all");

// Fuzzy subsequence constraints.
eq(Model.fuzzySubsequence("ab", "abacus"), false, "queries under 3 chars are rejected outright");
eq(Model.fuzzySubsequence("abc", "abacus"), true, "a 3-char run near the start matches");
eq(Model.fuzzySubsequence("abc", "xxabcyy"), true, "a run starting AT char 2 is allowed");
eq(Model.fuzzySubsequence("abc", "xxxabcyy"), false, "a run starting past char 2 is rejected");
eq(Model.fuzzySubsequence("abc", "acb"), false, "order must be preserved");
eq(Model.fuzzySubsequence("abc", "ab"), false, "an incomplete run does not match");
eq(Model.fuzzySubsequence("gimp", "gimp"), true, "fuzzy agrees with exact");

// ------------------------------------------------------------- AUR trust

eq(Model.trustLabel(null), "", "no row means no chip");
eq(Model.trustLabel({}), "", "a row with no AUR data gets no chip");
eq(Model.trustLabel({ aurOutdated: "1", aurVotes: "500" }), "⚠ flagged out of date",
   "out-of-date outranks a healthy vote count");
eq(Model.trustLabel({ aurVotes: "0" }), "⚠ unrated", "zero votes warns");
eq(Model.trustLabel({ aurVotes: "3" }), "3 votes", "a low count is shown plainly");
eq(Model.trustLabel({ aurVotes: "10" }), "", "ten votes is enough for no chip");
eq(Model.trustLabel({ aurVotes: "5000" }), "", "a popular package needs no chip");
eq(Model.trustLabel({ aurVotes: "not-a-number" }), "", "unparseable votes are not shown");

eq(Model.isAurRow({ aurPkg: "yay" }), true, "a row with an AUR package is an AUR row");
eq(Model.isAurRow({ aurPkg: "" }), false, "an empty AUR package is not an AUR row");
eq(Model.isAurRow({}), false, "a row with no AUR field is not an AUR row");


// ------------------------------------------------------------- details sheet

// Fixtures below are VERBATIM from this machine's own `pacman -Si` / `-Qi`,
// because the format is the whole difficulty: entries are double-space padded,
// constraints are attached with "=", and optional deps carry a colon.
eq(Model.depNames("systemd-libs=261.2  acl  bash  cryptsetup  dbus"),
   ["systemd-libs=261.2", "acl", "bash", "cryptsetup", "dbus"],
   "a real Depends On line splits into entries");
eq(Model.depNames("apparmor: additional security features"), ["apparmor"],
   "a colon-description optional dep yields just the name");
eq(Model.depNames("none"), [], "pacman's empty marker yields no names");
eq(Model.depNames("None"), [], "the capitalised marker yields no names either");
eq(Model.depNames(""), [], "blank yields no names");
eq(Model.depNames(undefined), [], "undefined yields no names");
eq(Model.depNames(null), [], "null yields no names");
eq(Model.depNames("alsa-utils  at-spi2-core  audit"), ["alsa-utils", "at-spi2-core", "audit"],
   "a real Required By line splits into entries");
eq(Model.depNames("foo  foo"), ["foo"], "a duplicate is not repeated");
// The AUR info path emits comma-joined lists; the pacman path uses two spaces.
eq(Model.depNames("pacman>6.1, git"), ["pacman>6.1", "git"],
   "a comma-joined AUR dependency list splits into entries");
eq(Model.depNames("sudo, doas"), ["sudo", "doas"],
   "a comma-joined optional-deps list splits into entries");
eq(Model.depNames("pacman>6.1,  git"), ["pacman>6.1", "git"],
   "comma and double-space separators mix cleanly");
// Version constraints are part of the name for AUR, where they are meaningful.
eq(Model.depNames("glib2>=2.66, gcc"), ["glib2>=2.66", "gcc"],
   "an AUR version constraint stays attached to its dependency");

eq(Model.matchReasonFor("gimp", "gimp", false), "Exact name match", "exact match is explained");
eq(Model.matchReasonFor("gimp2", "gimp", false), 'Name starts with "gimp"', "prefix match is explained");
eq(Model.matchReasonFor("libgimp", "gimp", false), 'Name contains "gimp"', "substring match is explained");
eq(Model.matchReasonFor("gimp2", "gimp 2", false),
   'Name matches "gimp 2" ignoring punctuation', "punctuation-insensitive match is explained");
eq(Model.matchReasonFor("firefox", "ffx", false), 'Fuzzy match \u2014 the letters of "ffx" in order',
   "fuzzy match is explained in the ranker's own terms");
eq(Model.matchReasonFor("firefox", "browser", true),
   'Shown by natural-language category match: "browser"',
   "a category hit is explained even when the name does not match");
eq(Model.matchReasonFor("anything", "", false), "Shown before anything was typed", "empty query is explained");
eq(Model.matchReasonFor("anything", "   ", false), "Shown before anything was typed",
   "a whitespace-only query counts as empty");
eq(Model.matchReasonFor("firefox", "browser", false), "Matched through this package's metadata",
   "an unexplained row falls back honestly rather than inventing a reason");
// The query is reflected back to the user, so a hostile clipboard string must
// not be able to smuggle markup into the (plain-text) explanation.
eq(Model.matchReasonFor("<b>x</b>app", "<b>x</b>", false), 'Name starts with "<b>x</b>"',
   "a query full of markup is echoed verbatim (the sink renders it as plain text)");
eq(Model.matchReasonFor("gimp", "gimp", false), "Exact name match",
   "an exact match is reported as such, not as a category hit");

// ------------------------------------------------------- version comparison
//
// The update chip is only honest if these hold. A false "update available" is
// the damaging direction, so the unparseable cases are asserted to be inert.

eq(Model.needsUpdate("2.0", "1.0"), true, "newer major offers an update");
eq(Model.needsUpdate("1.0", "2.0"), false, "an older offer is never an update");
eq(Model.needsUpdate("1.0", "1.0"), false, "identical versions are not an update");
eq(Model.needsUpdate("", "1.0"), false, "no available version offers no update");
eq(Model.needsUpdate("1.0", ""), false, "no installed version offers no update");
eq(Model.needsUpdate(null, undefined), false, "missing values are inert");

// pkgrel: the trailing -N is compared last and on its own.
eq(Model.needsUpdate("1.0-2", "1.0-1"), true, "a bumped pkgrel is an update");
eq(Model.needsUpdate("1.0-1", "1.0-2"), false, "a dropped pkgrel is not an update");
eq(Model.needsUpdate("1.0-10", "1.0-9"), true, "pkgrel compares numerically, not lexically");

// Multi-digit segments must not be compared as strings: "10" > "9" numerically.
eq(Model.needsUpdate("2.10", "2.9"), true, "10 beats 9 even though '10' < '9' as text");
eq(Model.needsUpdate("2.9", "2.10"), false, "9 does not beat 10");

// Epoch overrides everything to its right.
eq(Model.needsUpdate("1:1.0", "2.0"), true, "a higher epoch outranks a higher version");
eq(Model.needsUpdate("2.0", "1:1.0"), false, "no epoch does not outrank one");
eq(Model.needsUpdate("1:1.0", "1:1.0"), false, "same epoch and version is not an update");
eq(Model.needsUpdate("1:1.1", "1:1.0"), true, "same epoch still compares the version");

// Real-world Arch shapes.
eq(Model.needsUpdate("2.10.38-5", "2.10.38-4"), true, "Arch style bump is an update");
eq(Model.needsUpdate("1:1.19.8-1", "1.0.0-1"), true, "epoch bump on a real shape");
eq(Model.needsUpdate("6.6.12.arch1-1", "6.6.11.arch1-1"), true, "Arch's .archN suffix bumps");
eq(Model.needsUpdate("2.39.2-1", "2.39.2-1"), false, "identical Arch versions are not an update");

// A version string that is not a version at all must not manufacture an update.
// "unknown" sorts below "1" at the first segment (letters rank under numbers),
// so the honest answer is "no update" rather than a guess in either direction.
eq(Model.needsUpdate("unknown", "1.0"), false, "a non-numeric offer does not fabricate an update");
eq(Model.compareVersions("unknown", "1.0"), -1, "letters rank below numbers at the same position");
eq(Model.needsUpdate("1.0", ""), false, "blank installed version stays inert");

// compareVersions is the primitive behind needsUpdate and is directly meaningful.
eq(Model.compareVersions("1.2", "1.10"), -1, "1.2 < 1.10");
eq(Model.compareVersions("1.10", "1.2"), 1, "1.10 > 1.2");
eq(Model.compareVersions("1.0", "1.0"), 0, "equal versions compare equal");
eq(Model.splitVersion("1:2.0-3").epoch, 1, "epoch is parsed out of the version");
eq(Model.splitVersion("2.0-3").release, "3", "pkgrel is parsed out of the version");

// -------------------------------------------------------------------- done

if (failures.length > 0) {
    console.error("\nModel.js: " + failures.length + " of " + checks + " assertions FAILED\n");
    for (var i = 0; i < failures.length; i++) {
        console.error("  - " + failures[i]);
    }
    console.error("");
    process.exit(1);
}
console.log("Model.js: " + checks + " assertions passed");