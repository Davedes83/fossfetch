# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

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
- **Details sheet** — dependency graph, installed size, provides/conflicts, and
  a plain-language explanation of *why* the row matched (exact, prefix,
  substring, punctuation-insensitive, fuzzy, or natural-language category).
  "Required by" is fetched lazily from `pacman -Qi` only for installed rows,
  because it is the field that tells you whether removing a package would break
  something else — and `pacman -Si` does not report it at all.
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