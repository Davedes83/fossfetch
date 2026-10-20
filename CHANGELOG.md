# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] — unreleased

FossFetch could find and install packages. It could not tell you what was
already out of date, which is the other half of what a package manager is for.

### Added

- **Result sorting.** `Ctrl+S` (or the label above the results) cycles
  Relevance → Installed first → Popularity → Updated → Name. "Installed first"
  partitions the results without ranking them: it decides which rows lead, and
  the two groups keep the backend's relevance order, so it never quietly
  alphabetises the list while claiming to have only moved things you already
  have. It is offered only when the results actually split — all installed or
  none installed makes it a no-op — and never while "Hide installed" is on,
  which has already removed one of the groups. Relevance is the default and is the
  order the backends produced — the only ranking that knows your query, since
  no field on a row records it. It is therefore captured as each row's
  insertion position rather than re-derived, so it can be returned to at any
  point in the cycle. Name sorting is case-folded, so capitals interleave with
  lowercase instead of sorting as a separate block, and every mode falls back
  to name on a tie so two rows can never trade places between runs. The cycle
  only offers modes the current results can actually order by, so it never
  offers a mode that would silently do nothing.
- **A "Hide installed" filter** (`Ctrl+H`). Searching for a browser when you
  already run Firefox should not bury the alternatives under what you have.
  It counts what it suppresses, so a search whose only matches are installed
  says "Already installed — 12 matches — Ctrl+H to show them" rather than
  borrowing the "No packages found" wording and implying the search failed.
  Suppressed on the Updates tab, where every row is installed by definition
  and the filter would empty the tab you opened precisely to see it.
- **A keyboard hint footer** naming the keys the panel actually binds
  (`↑↓ Move`, `↵ Install`, `F2 Details`, `Tab Source`, `Esc Close`).

- **An Updates tab, shown only when there is something in it.** A background
  scan (`checkupdates`, `yay`/`paru -Qua`, `flatpak remote-ls --updates`) runs
  once at startup, every five minutes, and after any install, update or removal.
  The tab appears between Flatpak and All, and disappears the moment the last
  pending update is gone — an empty Updates tab teaches people to ignore it.
- **A count badge on the toolbar icon**, so the number is visible without
  opening the panel at all. It is drawn as an overlay rather than a third item
  in the button, so the pill does not resize and twitch as updates are applied.
- **Update availability on every card.** An installed package whose version
  has moved on gets an `Update` chip stating both versions (`2.10.38-4 →
  2.10.38-5`) and its own amber Update button. Update and Remove are separate
  controls: one button that means "install" or "update" or "remove" depending
  on hidden state is the ambiguity the card redesign removed, and a
  mis-click here uninstalls something.
- **`F2` opens the details sheet** for the highlighted row. It was mouse-only,
  so a keyboard-first panel had no way to look at a package before committing to
  it. Enter still installs; F2 is the "look first" key.
- **Version comparison in the details sheet** — Installed and Available side by
  side whenever they differ.

### Added

- **Five toolbar designs, along one axis — how much chrome sits behind the
  magnifier.** `Icon` (a bare glyph, and the first-install default), `Circle`
  (the pill's shape without its wording), `Text` (glyph + "Find App", no chip),
  `Brand` (glyph + "FossFetch", no chip) and `Pill`. The magnifier keeps the
  same grey circle on every style that has a label, so the borderless ones read
  as the pill's own control rather than loose text.
- **The supporter prompt is re-shown once per release.** It comes back ticked
  on any update; untick it and it stays unticked until the next one. Still a
  plain checkbox — nothing is blocked and nothing is decided for the user.
- **`SUPER + CTRL + SHIFT + F` toggles the panel** from anywhere, installed
  into `~/.config/hypr/hyprland.lua` on first run. `SUPER + SHIFT + F` is
  already Omarchy's "open files" and `SUPER + ALT + F` its "full width", so
  the extra `CTRL` is what keeps the binding clear of both. Details stays on
  `F2`: Hyprland consumes a bound combo before the focused client ever sees
  it, so the same chord inside the panel would have toggled it shut.

- **Multi-select and batch actions.** `Space` marks the highlighted row and
  steps down, `Shift`+`↑↓` extends a range, `Ctrl+A` takes everything, and
  `Esc` puts the marks down again. A bar appears while anything is marked,
  offering only the actions the selection can actually take — "Install
  selected" is not offered when every marked package is already installed —
  and `Enter` acts on the marks rather than on whatever the cursor happens to
  sit on, using the same precedence as a single row: an available update first,
  otherwise removal when everything marked is already installed.

  A batch runs **one command per source, not one per package**. `actionProc` is
  a single process and pacman holds a global database lock for the whole of an
  install, so a terminal per package would either deadlock on that lock or open
  a dozen windows, each independently re-resolving the same dependency set.
  Removal stays non-cascading for every source, exactly as the single-row
  button is, and still asks for confirmation first; install and update keep the
  arm-then-run second click.

### Added

- **The shell restarts after you update a package from here.** An update
  replaces an app in place, and the bar and dock keep serving the old one's
  cached state until the shell is told to re-read it — so the update appears to
  do nothing until the desktop flashes. A fresh install has no such problem
  (its `.desktop` file is new, and launchers pick that up on their next read)
  and a removal takes an entry away, so neither triggers a restart.

  The restart runs as its own `systemd-run --user` unit, and
  `restart_shell.sh` polls for the shell to answer before giving up, retrying
  up to three times. Both parts are load-bearing: the first because the shell
  runs in a systemd unit whose cgroup is torn down wholesale, taking any child
  with it — so a restart spawned from inside the shell was killed by the very
  thing it meant to outlive, and the session came back with no bar, no dock and
  no shell at all. The second because this runs unattended off a package
  update, where a failed relaunch means a desktop that never comes back.

### Fixed

- **The bar button did nothing at all.** Clicking FossFetch did not open the
  panel — no window, no error, nothing in the shell log. `3aad206` gave the
  panel its own `property bool opened`, which silently shadowed the shell `Panel`
  base type's `opened`, a readonly alias of its `PanelController`. The
  controller was still flipped by `show()`, but nothing was listening any more,
  so `KeyboardPanel.open` never went true and the panel sat at zero implicit
  size. The shadowing declaration and the write-back that fed it are gone; open
  state comes from the controller again, which is what it is for.

- **The panel was built on first click instead of at start-up.** Deferring the
  panel's construction until the bar button was pressed turned out not to
  survive contact with the shell: a panel created outside start-up never
  finishes wiring its controller, so `show()` did nothing even with the open
  state fixed. The panel is loaded eagerly again. The reason for deferring it
  was to keep a clipboard-reading surface out of the shared shell process, and
  that surface is already gone with the native text field — see the entry below
  — so there was nothing left to defer for.

- **The query's caret and selection never appeared.** Placing the drawn caret
  and the selection band used `positionToRectangle()`, which reads like the
  obvious way to turn a character index into a pixel but is declared on
  `TextInput`/`TextEdit` only. On the plain `Text` that draws the query it is
  not a function, so each binding threw on every evaluation and both markers
  stayed unplaced. They are measured with `TextMetrics` against the same font
  now, using `advanceWidth` rather than `width` so a trailing space still
  advances the caret.

- **A permanently-broken source stopped retrying every 25 seconds.** The
  retry exists for the transient pacman lock of a shell start, which clears in
  seconds — but a source that is still broken after a few retries (a dead AUR
  helper, a missing binary, a machine that is offline) does not heal in 25
  seconds, and retrying at that rate for the life of the session re-ran the
  whole three-source scan every 25 seconds, each pass invoking `fakeroot
  pacman -Sy` over the network. The interval now doubles up to the periodic
  tick, so a broken source costs at most one extra scan per five minutes until
  it comes back, and a clean scan resets the clock to 25s.

- **An up-to-date machine scanned forever, every 25 seconds.** `checkupdates`
  exits **2** to say "nothing pending" — that is its documented empty-update
  path, and `exit 1` is the real failure (`Cannot fetch updates`, the pacman
  lock). Reading 2 as a failure marked the scan degraded on every machine that
  was simply up to date, which is most of them most of the time. Worse, a
  degraded scan arms a 25-second retry, so a fully updated system ran the whole
  three-source scan forever — every 25 seconds, each pass invoking
  `fakeroot pacman -Sy` against the network. Exit 2 is now the healthy no-news
  result; exit 1 still reports as a failure and still arms the retry, which is
  what that timer is for.

- **The bar widget failed to load, so the update badge disappeared.** Moving the
  update scan out of the panel into the bar widget landed the file with two
  copies of the same method in one object. QML rejects that outright, so
  `UpdateScan` never instantiated and the widget that owns the scan was dropped
  from the bar with nothing on screen but a line in the shell log. The duplicate
  is gone; `tools/qml_lint.py` now checks every `*.qml` in the plugin root (the
  new file had never been in its list) and rejects a name declared twice in the
  same scope, which is the exact failure the QML parser reports.

- **Enter did nothing on a Flatpak-only row.** The Flathub install button shows
  on any tab whenever a row carries an app id, but the keyboard path only knew
  about the pacman and AUR branches, so the card offered a button that Enter
  ignored and a batch silently dropped. Both now use the same rule.

- **The All tab stayed hidden after being switched on.** It needed three source
  tabs to appear, so with AUR disabled Pacman+Flatpak — already a merge — did
  not qualify and the opt-in appeared to do nothing. Two source tabs is enough.

- **A partial update scan was reported as a complete one.** Only a scan that
  lost *every* source was treated as unusable: pacman answering while the AUR
  helper was locked took the rows, cleared the degraded flag and stopped the
  retry, so the missing source stayed missing until the next tick. Any
  `SCANFAIL` now keeps the flag and the retry, whatever the scan did find.

- **A failing AUR helper looked like a clean scan.** `yay -Qua` / `paru -Qua`
  exit non-zero when the pacman lock is held — the seconds right after a shell
  start — and their stderr was discarded, so the panel reported "no updates"
  for a check that never ran. They are now handled exactly like `checkupdates`
  and `flatpak`: a failure is a `SCANFAIL` line and a degraded status.

- **`FOSSFETCH_MAX_AUR` could crash the search outright.** A non-numeric value
  raised `ValueError` at import time and killed the search before it made a
  request. The cap is a safety limit, not a setting worth failing over, so a
  bad, empty or negative value falls back to the 8 MiB default.

- **A `..` in the cache path was not refused.** The containment check was a
  prefix test, so a path inside the cache that walked back out with `..` passed
  it and was left for URL normalisation to fix. Every component now has to be a
  real name — no `.`, no `..`, no empty component.

- **The catalog state helper accepted traversal paths.** `rmtree`, `put` and
  `tmpfile` used their path arguments directly, so `../` reached outside the
  catalog — a recursive delete into the rest of the cache, or a temp file
  written elsewhere. They now validate like `swap` already did, and `rmtree`
  with no path reports a usage error instead of a traceback.

- **The group index was rebuilt on every search.** `groups_stale` statted a
  `groups.tsv` *underneath* the `current` marker, which is a file, so the index
  mtime always read as zero and the function was always true: a fresh index was
  thrown away and a rebuild kicked off behind every keystroke. It now stats the
  index the marker actually names, and the marker is validated before it is
  used as a path.

- **Ranking ignored the case of the query.** The needle was compared against an
  already-lowercased name, so a search carrying capitals ranked every row as "no
  match" and the list came back in backend order.

- **An unrecognised sort mode silently did nothing.** It fell through with the
  input untouched; per the contract, anything unknown is "relevance", so it now
  restores the backend order. `sortModes` also hands back a copy, so a caller
  that mutates it cannot strip modes from the cycle.

- **The hotkey combo was written into `hyprland.lua` unsanitised.** That file is
  LUA: a combo carrying a quote closed the string and appended whatever followed
  to the user's Hyprland config. A combo is only modifier and key names joined
  by " + ", so anything outside that alphabet — including a line break — is
  refused rather than escaped.

- **The details sheet opened in the top-left corner.** It anchored below its
  anchor item, which is the toolbar button — and that button sits at the far
  left of the bar. The sheet therefore appeared under a button, in the corner,
  while the panel it describes was centred in the middle of the screen: the
  same information in two places at once, one of them nowhere near the rows
  F2 was pressed on. It now centres on the bar, like the panel.

- **A first install did not get the toolbar it was supposed to.** "Icon" is now
  the default when there is no settings file at all. An install that already
  has one keeps its choice — and a file without a stored design falls back to
  the historical "pill" rather than being switched under the user.

- **Batch actions never launched anything.** The batch runner reached the
  process through `root.actionProc`, which resolves to `undefined` in this
  scope and throws — while the identical single-action code, using the bare id,
  works. The throw happened after `batchActive` had already been set, so the
  bar read "Working…" indefinitely over a command that was never dispatched.
- **The terminal was hard-coded to kitty.** `TERMINAL` is unset in the Omarchy
  shell's environment, so the `if (!term) term = "kitty"` fallback worked for
  the author and produced a terminal that could not start for anyone else. The
  runner now resolves the user's own terminal: `xdg-terminal-exec` first
  (which reads `~/.config/xdg-terminals.list`, where `omarchy default terminal`
  records the choice), then `omarchy-default-terminal`, then `TERMINAL` /
  `TERMINAL_CMD`, with kitty kept only as a last resort. The single-row install,
  update and remove paths use the same resolution.
- **A failed batch reported itself as finished.** The outcome is now the
  command's own exit status: pacman refuses an entire command when any target
  is unknown, and the terminal is gone in under a second, so an unconditional
  "Batch finished" is how a batch that installed nothing gets announced as a
  success. A non-zero status says so and points at re-running it.


  `controller.show()` flips the panel's `opened` flag, and a panel that is not
  yet visible has no focusable window — so the immediate `forceActiveFocus()`
  after it was silently dropped, the panel appeared, and every keystroke went to
  whatever was behind it. Both open paths now defer the focus request until the
  panel is actually up, retrying while it is not.

- **A failed update scan reported itself as "no updates".** `checkupdates`
  copies the sync databases to a temp dir before comparing, so it fails outright
  while anything holds the pacman lock — which is what happens in the seconds
  after a shell start, when the eager scan first runs. Its stderr was discarded,
  so that failure produced zero rows and a confident `STATUS|ok|updates`. The
  panel read it as a clean result: the badge and the Updates tab disappeared and
  stayed gone for the next five minutes while updates were waiting, with no
  error anywhere. A source that could not answer now says so (`SCANFAIL` /
  `STATUS|degraded`), an incomplete scan never overwrites a known count with
  zero, and it retries in 25s rather than waiting out the full interval.
- **Recent searches recorded every keystroke.** Live search runs on each
  debounced prefix, and each one was filed as its own recent — typing
  "vivaldi" left `via`, `vial`, `vival`, `vivald` and `vivaldi` behind as five
  separate entries. Those are the innards of one search, not five searches. A
  query is now remembered once the typing stops (1.2s), or immediately on an
  explicit commit (Enter, Tab, close). A genuine pause longer than that still
  records both halves, which is the honest reading. A clipboard suggestion is
  armed but does not start the timer, so one you ignore never appears.
- **Persisted settings were silently discarded.** `Model.sortModes` was read as
  a bare array, but a `.js` imported with `import "Model.js" as Model` exposes
  only top-level declarations to QML — `module.exports` is a Node-only
  construct. The value was `undefined` in the panel while every Node test
  passed, and the settings loader's empty `catch` swallowed the TypeError. The
  result: the panel came up with defaults every time and any later save
  overwrote the saved preferences. The loader now reports failures instead of
  swallowing them, and a test asserts every `Model.x` the panel references is
  declared at top level.
- **Relevance sorting could not be undone, and Popularity was a relabelled
  Name sort.** Relevance was treated as "leave the order alone", so once you
  sorted by name, switching back kept the alphabetical order — a mode that
  silently does nothing. Rows now carry their insertion order, which is the
  backend's own relevance ranking, and Relevance restores it. Separately,
  sorting Pacman results by Popularity found no popularity on any row, so every
  pair tied and the comparator fell through to its name tiebreak: alphabetical
  order wearing a popularity label, identical to the Name mode. A mode whose
  field is absent from every row no longer reorders at all, and the cycle only
  offers modes the current results can actually order by.
- **Changing the sort kept the old scroll position.** The viewport was left
  where the previous order happened to leave it, which after a re-sort points at
  an unrelated set of rows and reads as the list jumping at random. Selecting a
  sort now shows the top card of the new order; results merely settling from a
  slow backend still keep your place.
- **The "Updated" mode was missing from the cycle.** Which sorts are offered was
  computed once, before the batched `pacman -Si` pass had supplied any build
  dates — so the cycle offered a sort the cards could not yet support, and
  gained it only after some unrelated action happened to re-run the sort.
- **Sorting blanked the cards.** `QQmlListModel.get()` returns objects bound to
  the live rows, so clearing the model to reorder emptied them too —
  re-appending gave cards with no name, no chips and no icon. Rows are now
  snapshotted before the rebuild.
- **The toolbar magnifier sat 2.5px above every other bar icon**, and its count
  badge ran off the top of the screen. The badge was anchored above the button,
  which already begins two pixels below the top of the display. Both are now
  positioned inside the button's own bounds.
- **The installed-package snapshot lost its versions.** It read names only
  (`pacman -Qq`), so there was nothing to compare an offered version against
  and no update could ever be detected honestly. It now reads `pacman -Q` and
  flatpak's version column — still one subprocess for both.

### Changed

- **Enter now prefers an update.** On a row with a pending update it drives the
  Update button rather than removal, which is what the row is inviting.
- **The background update scan moved to the bar widget.** The badge must stay
  live while the popup is closed, so the scan now lives on the always-loaded bar
  widget instead of inside the panel. The count is up to date whether or not the
  panel has ever been opened. (The panel itself is loaded eagerly again — see
  the Fixed entries above.)
- **The query line is no longer a native editable text field.** A maintainer
  review of the plugin's verification flagged what the loader alone could not
  fix: an editable native text item makes the Qt Wayland client treat the
  shell as a clipboard consumer, and on the packaged Qt 6.12.0 a clipboard
  change is read synchronously inside the shared shell process — foreign text,
  no byte cap, no overall deadline, without a paste. One stalled or oversized
  provider can freeze or exhaust the whole bar. The query line is now built
  from the shell's own primitives: a JS buffer, a drawn caret and
  hand-forwarded key handling, with the same editing keys as before —
  `←`/`→`/`Home`/`End` (with `Shift` they select), `Backspace` and `Delete`
  cut, `Ctrl+V` pastes. `Space` still marks the highlighted row rather than
  typing a gap: package names and app ids do not carry spaces.
- **Every clipboard read is explicit and bounded.** The only two are the
  speculative "offer what you just copied as the query" after an action
  finishes, and the explicit `Ctrl+V` paste. Both run `wl-paste` as a
  short-lived child process whose command carries the bounds in itself —
  `timeout` is the overall deadline, `head -c` the hard byte cap — so the
  shell process itself never touches foreign clipboard data, and a stalled or
  oversized provider can neither hang the window nor stream data into it.

### Security

- **The support button no longer fetches anything into the shell.** It was the
  hosted `kofi5.png`, loaded by an `Image` from `storage.ko-fi.com` on every
  panel load, decoded inside the shared shell process alongside the bar, the
  dock and every other plugin. The URL is mutable by whoever answers for that
  host, so the bytes were not this plugin's to vouch for, and the 138×30
  `sourceSize` only bounds the pixel grid Qt scales *to* — not the ancillary
  text chunks libpng reads and retains *before* that scaling. A small-pixel PNG
  carrying a large volume of individually permitted compressed text metadata
  would have been held in shared shell memory with no bound this panel
  controls, which is the same class of unbounded foreign input the query line
  and the clipboard reads were already reworked for: a third party able to
  stall or exhaust the whole desktop rather than just its own corner of it.

  The button is drawn instead — a `Rectangle`, a cup made of two more, and two
  `Text` items, themed from `Color.popups.text` and `Color.accent` like every
  other control in the panel. Nothing is decoded, nothing is cached, and there
  is no asset for anyone to swap between two launches. Clicking it still opens
  `ko-fi.com/davedes` in the user's own browser; that is the only network
  request the button makes, and it leaves the machine.

### Notes

- Version comparison follows pacman's scheme (epochs, pkgrel, numeric segment
  ordering) and is deliberately conservative: an unparseable or missing
  version never produces an update. A missed prompt is recoverable; telling
  someone to update something already current is not.
- The Updates tab hides Install and Remove. The tab exists to update things,
  and offering Remove beside Update invites a mis-click.

## [1.1.1] — unreleased

A visual pass over the whole panel. Nothing about what FossFetch does changed;
how it looks while doing it did.

### Fixed

- **Two icons were the wrong glyph.** The header mark and the search field both
  drew `U+F002` — Font Awesome's *bookmark*. The app's logo was a bookmark and
  the search box offered you a bookmark instead of a magnifier. Every glyph now
  comes from the Material Design set the rest of the shell draws, and the
  codepoints were read out of the font this machine actually resolves rather
  than copied by hand.
- **The toolbar icon was in the wrong font.** `BarWidget.qml` set no
  `font.family` on its glyph at all, so the one control visible in the bar all
  day rendered in whatever fallback the process happened to get.
- **Metadata was being elided mid-word.** `Repo: extra…`, `Updated: 28 …` — a
  single shared text line was squeezed between the install buttons and cut the
  *values* off. Every fact on a card is now its own chip, which wraps instead
  of truncating.
- The `Installed` tick had no space between it and its label.

### Changed

- **One segmented control instead of three outlined tab pills.** Outlining all
  three tabs gave "Pacman", "AUR" and "Flatpak" identical weight, so the active
  one read as "also selected". The old `TabButton` component is gone.
- **One action hierarchy on a card.** Install/Remove is the only filled
  control; Details and Web became borderless icon-only buttons. Details and Web
  were carrying full text labels in ~40px, which is what made the row look like
  a form.
- **Install/Remove lost its pictogram.** A 10px glyph beside 10px text in a
  26px pill is visual mud. The label already says "Remove" or "pacman (gmp)",
  so the weight comes from the fill and the source colour instead.
- **Cards are denser** (196px → 150px) and descriptions are capped at two lines
  rather than hiding in a scroll region with no affordance.
- **A source rail** — a 2px bar in the tab's own colour down the leading edge,
  plus a matching tint on the app-icon fallback. A list is scannable by colour
  before a word is read.
- **The settings button is the shell's own `PanelActionButton` again.** It was
  a hand-rolled 22x20 `Rectangle` — not square, so the corner radius rendered
  as a squashed oval — wrapped around a second `Rectangle` doing duty as a glow
  ring. The shell already ships the right component: square, borderless, proper
  hover fill, tooltip, focus ring.
- **The toolbar label is no longer a headline.** "Find App" was bold at 13px in
  a 26px pill, which reads as a title in a status bar. It is now caption-sized,
  unbold, tinted to the foreground and paired with a 16px icon chip.
- **The panel's mark is a magnifying glass**, not a package box. The box was a
  guess at "app store"; the search frame it actually is now matches the icon in
  the bar that opens it.
- **Two toolbar designs instead of six.** `outline` / `soft` / `bold` /
  `minimal` were the same pill at different alphas; asking someone to choose
  between four greys is not a decision they should have to make. Retired
  values are normalised onto the default on load, so an existing settings file
  cannot leave the bar unstyled.

## [1.1.0] — unreleased

Three passes of work on the panel, the backends and the repository itself.

The curated **Alternatives** tab was built during this cycle and then removed
again: it duplicated what a plain cross-source search already does well, and
its curated catalogue was too thin to be worth the fourth tab. The remaining
`All` tab merges the three live sources and is **off by default**.

### Added

- **Remove from an installed package.** An installed package keeps its `✓
  Installed` chip, and the button beside it becomes a working **Remove**
  instead of an inert status pill. Removal is never cascading: `pacman -R`
  removes only the package that was named, never `-Rs`/`-Rns`, because a
  package's dependencies are usually still wanted by something else and taking
  them silently breaks unrelated apps.
- **A real confirm dialog for removal.** The old "click once, then click again
  within 3 seconds" arm reverted with no feedback when the timer expired, and a
  destructive removal was confirmed by exactly the same gesture as an install —
  and removed nothing if the timer lapsed. Removal now goes through the shell's
  ConfirmDialog, which names the package and stays up until answered.
  Installing keeps the quick two-click arm on purpose: ConfirmDialog hardcodes
  `destructive: index === 1`, so its second button always renders in the danger
  colour — correct for "Remove", actively misleading for "Install".
- **Details sheet** for every source, not just Pacman. Dependency graph,
  sizes, provides/conflicts and a plain-language explanation of *why* the row
  matched (exact, prefix, substring, punctuation-insensitive, fuzzy, or
  natural-language category). Previously AUR and Flathub rows rendered almost
  empty, because the shared `pacman -Si` batch only collects rows carrying a
  pacman package — AUR and Flathub rows arrived with no metadata at all.
  AUR details come from a new `aur_search.py info` subcommand (the RPC's
  `search` interface returns only NameSearch fields — it has no Depends,
  Conflicts, Provides, Groups or even License), and Flathub details from
  `flatpak remote-info`, which adds Branch and Release. Both are fetched on
  demand for the one package whose sheet you open, never per keystroke.
  "Required by" is fetched lazily from `pacman -Qi` only for installed rows —
  it is the field that tells you whether removing a package would break
  something else, and `pacman -Si` does not report it at all.
- **The sheet fits.** Long package lists are truncated to 8 with a
  "+N more" count (mpv has 67 dependencies, which as one wrapped string took
  over the whole sheet and pushed Conflicts and Required-by off-screen
  entirely), the body scrolls, the header stays pinned, and the card is sized
  to its content instead of clipping its last facts.
- **Unit-tested panel logic.** Ranking, date formatting, URL allowlisting,
  cache-path containment, rich-text escaping, status-frame parsing, dependency
  parsing and match explanation now live in `Model.js` and are covered by 95
  assertions run in CI. Previously all of it was inline in `Panel.qml` with no
  coverage at all.
- **Cross-source install buttons actually appear.** The Flathub equivalent
  resolved for a Pacman or AUR result was used for its icon and then thrown
  away, so a card could never offer both. The app id is now attached to the row
  and a card carries `pacman (firefox)` *and* `flatpak (org.mozilla.firefox)`.
- **Installed-state detection.** One batched `pacman -Qq` + `flatpak list`
  snapshot marks what is already on the machine: the card carries an
  `✓ Installed` chip and the matching install button becomes a Remove action.
- **AUR helper auto-detection.** The helper was hard-coded to `yay`, so a
  paru-only user got a button that opened a terminal running a command that
  does not exist, with no indication anything was wrong. `paru` / `yay` /
  `pikaur` are detected on open, the panel follows whatever is installed, and a
  missing helper is labelled on the button and called out in options.
- **AUR trust signals** — votes, maintainer and the maintainer's
  flagged-out-of-date marker are surfaced as a single chip, worst-first.
- **Fuzzy matching.** A new ranking tier lets `librofice` find `libreoffice`
  and `obsstudio` find `obs-studio`. It is about abbreviations and dropped
  characters, not transpositions.
- **Matched-span highlighting** on the card title.
- **Recent searches** — up to 8, de-duplicated, persisted in the same hardened
  settings file and shown as chips when the box is empty.
- **Download size** on Pacman cards, read straight from `pacman -Si`.
- **Clipboard prefill** — a short, single-line clipboard is offered as the
  query when the panel opens empty.
- **Install feedback** — a desktop toast when the install command finishes.
- **CI** (`.github/workflows/ci.yml`) — the regression suite, `shellcheck`, a
  QML structural check and manifest validation on every push.
- **Pin-bump automation** (`.github/workflows/pin-check.yml`) — watches the
  upstream AppStream pkgver and opens a reviewable PR when it moves.
- `tools/qml_lint.py` — structural QML check (delimiter balance including JS
  regex literals, tabs, trailing whitespace).
- 14 new regression tests (30 → 42... 42 total, all green).

### Fixed

- **Shell injection.** Package names and Flathub app ids — remote metadata —
  were interpolated into `sh -c` script text in three places. They are now
  passed as argv, matching the rule the backend scripts already followed.
  Covered by a test that runs a crafted package name through the real script.
- **Left/Right arrows moved the caret** in the search box — no, they switched
  tabs, making it impossible to edit a query mid-string. Tab and Escape are
  now handled on the field itself, which also means `Tab` works again while
  typing (the panel key catcher is short-circuited whenever the field has
  focus, so it never saw the key).
- **A stale catalogue could block a search.** `resolve` built the index
  *before* emitting anything, so a slow or stuck refresh delayed every result
  list. A stale index is now served immediately and rebuilt in the background.
- **No retry backoff.** A failing build was retried on every keystroke —
  a ~10 MB download each time. Retries now back off exponentially, 60 s → 6 h.
- **Cache-path allowlist** used a bare `startsWith`, so
  `~/.cache/fossfetch-evil/x.png` passed. A trailing separator is now required.
- **Dates were a day off** for every user west of Greenwich: pacman prints
  Build Date in local time and it was being read back as UTC.
- **fd leak** in `appstream_state.py`: `open_sub` reassigned its loop variable
  without closing the previous descriptor.
- **XML entities** (`&amp;`, `&apos;`) were written into the Flathub index
  undecoded, so a card could read `Dinonuggy&apos;s Journey`.
- `buttonLabel` was documented as a setting but missing from the manifest
  schema, so the shell settings UI could never set it.

### Performance

| | before | after |
|---|---|---|
| Flathub catalogue build, peak RSS | 126.6 MiB | 35.2 MiB |
| Arch catalogue build, peak RSS | 75.7 MiB | 23.3 MiB |
| Flathub equivalent resolution | 6.7 s / 5 names | 0.05 s / 60 names |

- Both catalogues are now streamed (bounded reader + `XMLPullParser`) instead of
  decompressed whole and regex-scanned. Output verified byte-identical against
  the previous implementation, minus the entity fix.
- `flatpak_icon.py` resolves names from a new complete `flathub/names.tsv`
  index instead of running up to three `flatpak search` subprocesses per name.
  `groups.tsv` could not serve this: it only contains apps that declare a
  category.
- `O(n²)` model scans replaced with key → row index maps.
- The first-open catalogue warm no longer downloads the Flathub index for users
  who have switched the Flatpak search off, and its progress is now visible
  instead of silent.

### Changed

- **The `All` tab is off by default.** Merging all three backends is slower per
  keystroke than searching one, which is the wrong trade for a launcher opened
  dozens of times a day. Turn it on with **All results** in the options panel.

- `alternatives.json` is no longer dead weight — it is the Alternatives tab.
- Removed dead code: delegate roles nothing rendered (`rating`, `license`,
  `category`, `_pkg`), the unused `headerAllowance` property, and an unused
  parameter on `buildModel`.
- `preview.png` optimised (1.9 MB → 408 KiB) and referenced from the README
  instead of a separately hosted copy.
- Manifest: version 1.1.0, plus `homepage`, `repository`, `keywords` and
  `barWidget.aliases` so the plugin is findable in the widgets menu.

### Known limitations (unchanged)

- The Alternatives catalogue is only as good as `alternatives.json`. Coverage is
  broad for office/graphics/media but thin for video conferencing and design
  tools.
- The Alternatives tab's empty query shows the first 60 entries
  alphabetically, not a curated selection.
- Fuzzy matching recovers abbreviations, not transpositions.

## [1.0.0]

Initial release: three-ecosystem search (Arch repos, Flathub, AUR), AppStream
category browsing, live metadata enrichment, arm-and-confirm install, six
toolbar designs, and a checksum-pinned, owner-checked catalogue cache.