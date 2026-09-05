<img width="1536" height="1024" alt="preview" src="https://github.com/user-attachments/assets/134fe99c-a64b-42a0-a95f-93bf8f301e29" />


# FossFetch

A launcher-style package search for [Omarchy](https://omarchy.org/) that hunts on
**three package ecosystems at once** — Arch repos, Flathub and the AUR — and
installs results with a quick arm-and-confirm, straight from your top bar.

Search anything FOSS: type a package name, or browse **by what it does**
("video editing", "browser", "chat"). Every result card shows real, live-scraped
metadata: version, repository, architecture, license, homepage and last-updated
date — with install buttons for each package source.

```
FossFetch — Browse open-source packages · Pacman + AUR + Flathub
```

---

## Features

### Search three ecosystems in one panel
Three tabs, each backed by a live search (no stale curated lists):

| Tab | Source | Live query |
|-----|--------|------------|
| **Pacman** | Arch repos (core / extra / multilib) | `pacman -Ss` |
| **Flatpak** | Flathub | `flatpak search` + Flathub AppStream catalog |
| **AUR** | Arch User Repository | AUR RPC `name-desc` search |

Both the Pacman and Flatpak tabs support **natural-language category browsing**
— enter a phrase like `video editing`, `browser`, `music`, `terminal` or
`discord` and matching AppStream-category members surface first, then ranked
name matches. The keyword → category mapping lives in [`groups.keywords`](groups.keywords)
and is shared by the Arch and Flathub group matchers.

### Real metadata on every card
Results are enriched on the fly:
- **Version · Repo · Arch** from `pacman -Si` (batched into one subprocess).
- **License** from `pacman -Si` / `flatpak info --show-metadata`.
- **Homepage / GitHub link** (opens externally).
- **Last updated** — pacman `Build Date`, AUR `LastModified`, or Flathub
  release timestamps — shown in the bottom-left of each card.
- **App icons**: Arch's published AppStream icon catalog, Flathub icons, plus a
  local fallback that extracts an icon from installed packages via `pacman -Ql`.

### Arm-and-confirm install, per source
Each card shows install buttons for the matching sources (a Pacman result may
offer Pacman **and** a Flathub/AUR equivalent). First click **arms** ("Confirm?");
a second click runs the real command in your terminal:

| Button | Command |
|--------|---------|
| Pacman | `sudo pacman -S --needed <pkg>` |
| yay / paru | `yay -S --needed <pkg>` / `paru -S --needed <pkg>` |
| Flatpak | `flatpak install --assumeyes flathub <appid>` |

The terminal is read from `$TERMINAL` / `$TERMINAL_CMD` and falls back to
`kitty`. Pacman and Flatpak install attempts run independently, so arming one
never conflicts with another.

### Six toolbar icon designs
The "Find App" pill in the bar restyles itself live. Choose from the options
panel: **Current, Outline, Soft, Bold, Minimal, Icon** (a bare magnifying-glass
glyph). The setting is pushed to the bar widget in real time and persists.

### Options panel (gear icon)
- Toggle the **AUR** and **Flatpak** tabs on/off.
- Choose the AUR install helper: **yay** or **paru**.
- Toolbar **icon design** picker.
- Compact **"Buy Me a Coffee"** button with a small tick-box to hide it.

All options persist to
`~/.local/state/omarchy/settings/davedes.fossfetch.json`.

### Built for the Omarchy shell
- **Keyboard-first**: `Tab` cycles tabs, arrow keys move the selection,
  `Enter` arms the highlighted card's install (a second press runs it),
  `Esc` closes, `/` refocuses the search box.
- **Theme-aware**: per-ecosystem accents (green = Pacman, cyan = AUR,
  blue = Flatpak, yellow = confirm state) are read from the active theme's
  `colors.toml`, so the panel blends with whatever theme is running.
- Renders on Omarchy's frosted popup surface with the standard menu
  selected-row treatment.

---

## Requirements

- **Omarchy 4.x** (Quickshell-based shell) on **Arch Linux**
- `pacman` (base), `python3` (datastore scripts)
- Optional / feature-gated:
  - `flatpak` — for the Flatpak tab and Flatpak installs
  - `yay` or `paru` — for AUR installs
  - a network connection for the first category/icon catalog download
    (cached locally; see [Caches](#caches-and-privacy))

---

## Installation

### 1. Clone the plugin

```bash
omarchy plugin clone davedes.fossfetch
```

…or manually:

```bash
git clone https://github.com/Davedes83/fossfetch.git ~/.config/omarchy/plugins/davedes.fossfetch
```

### 2. Add it to your top bar

Add the **FossFetch** widget to your preferred bar section via the Omarchy
widgets menu (or `~/.config/omarchy/shell.json`). Default section: `right`.

### 3. Bind the hotkey

In `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + F", "FossFetch", "omarchy-shell fossfetch toggle")
```

The panel can also be toggled over IPC with
`omarchy-shell fossfetch toggle` from any launcher/hotkey.

> A built-in optional Hyprland global shortcut
> (`quickshell:toggle_alt_finder`) is also available as an alternative to the
> IPC binding — bind it with
> `bind = SUPER ALT, F, global, quickshell:toggle_alt_finder`.

---

## Usage

1. Press `SUPER + ALT + F` (or click the magnifier pill in the bar).
2. Type a query:
   - a package / app name → exact, prefix and substring matches ranked first;
   - a natural-language phrase → category members listed, then name matches.
3. `Tab` to switch tab (Pacman / AUR / Flatpak), arrow keys to select, `Enter`
   to install: the first press **arms** the card's primary install
   ("Confirm?"), a second press runs the command.
4. Clicking an install button works the same way. The card's homepage ("Visit
   site") chip opens the project website externally.
5. Click the **gear** (top right) to reach the options.
6. `Esc` closes; `/` refocuses search.

---

## Configuration

The plugin ships sensible defaults; the shell's settings UI exposes the
`BarWidget` schema:

| Setting | Default | Description |
|---------|---------|-------------|
| `panelWidth` | 560 | Width of the search popup (360–900) |
| `debounceMs` | 150 | Delay after typing before searching (0–500) |
| `buttonLabel` | "Find App" | Text on the bar pill (hidden in Icon design) |

Options chosen in the panel are persisted to
`~/.local/state/omarchy/settings/davedes.fossfetch.json`:

```json
{
  "flatpak": true,
  "aur": true,
  "aurHelper": "yay",
  "design": "current",
  "showCoffee": true
}
```

| Key | Values | Meaning |
|-----|--------|---------|
| `flatpak` | `true`/`false` | show the Flatpak tab |
| `aur` | `true`/`false` | show the AUR tab |
| `aurHelper` | `yay`/`paru` | AUR install command |
| `design` | `current`, `outline`, `soft`, `bold`, `minimal`, `icon` | toolbar pill style |
| `showCoffee` | `true`/`false` | show the "Buy Me a Coffee" button |

---

## Caches and privacy

- Datastore indices live under `~/.cache/fossfetch/`:
  - `catalog/<date>/groups.tsv` + icons — built from Arch's published AppStream
    catalog and refreshed when it is over 32 days old;
  - `flathub/groups.tsv` + `flathub/appids.tsv` — built from Flathub's
    AppStream catalog (same staleness window).
- Everything is resolved against public, first-party sources (Arch's AppStream
  mirror, Flathub's AppStream feed, the AUR RPC). No accounts, no telemetry, no
  third-party trackers.
- Search results and enriched metadata are always fetched live; remove the
  cache directory at any time and it will be rebuilt on the next search.

---

## Repository layout

| File | Purpose |
|------|---------|
| `BarWidget.qml` | Top-bar pill widget + toolbar icon designs |
| `Panel.qml` | Main search panel UI, results model, install flow |
| `aur_search.py` | AUR RPC search (name/desc), emits 8-column TSV |
| `flathub_groups.py` | Flathub AppStream category matcher + release-date index |
| `appstream_groups.sh` | Arch AppStream category matcher (`groups.tsv`) |
| `appstream_icons.sh` | Arch AppStream icon catalog resolution |
| `flatpak_icon.py` | Name → Flathub app-id resolution for icons |
| `groups.keywords` | Natural-language keyword → AppStream category table |
| `alternatives.json` | Bundled curated metadata of FOSS alternatives to
  proprietary apps |
| `manifest.json` | Omarchy plugin manifest (bar-widget) |

---

## Known limitations

- AUR install buttons are no-ops until `yay` or `paru` is actually installed;
  pick the helper you have in Options.
- Flatpak results/installs require the `flathub` remote to be present.
- First search on a tab may be slower while the AppStream/icon catalogs are
  downloaded once; afterwards everything is served from the local cache.
- `paru` is not bundled — it must be installed via your preferred AUR helper.

---

## License

MIT. See [`manifest.json`](manifest.json) for plugin metadata.
