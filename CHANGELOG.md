# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

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