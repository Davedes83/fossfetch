#!/usr/bin/env python3
"""Resolve package names to their Flathub app id.

Emits one line per requested name:  N|<name>|<appid>   (empty appid if no match)

Two tiers, cheapest first:

  1. LOCAL — read <cacheRoot>/flathub/names.tsv, the complete display-name ->
     app-id index built by flathub_groups.py. This answers nearly every lookup
     in milliseconds.
  2. REMOTE — only for names the local index misses, run `flatpak search` and
     score the results. Bounded twice over so a batch of 60 names can never
     turn into minutes of serialized lookups: at most
     FOSSFETCH_FLATPAK_REMOTE_MAX names (default 3) reach this tier, and a
     wall-clock budget (FOSSFETCH_FLATPAK_BUDGET seconds, default 5) caps it.

Tier 1 exists because the old implementation ran `flatpak search` up to three
times per name, each a separate process doing its own remote lookup: five names
measured 6.7 s, and the panel batches up to sixty. The count cap matters just
as much: the overwhelming majority of Arch packages (bash, kernel modules,
libraries) have no Flathub counterpart at all, so an uncapped remote tier would
spend the whole budget proving that over and over. Measured on a 60-package
batch: local-only 0.05 s, remote tier allowed 8 names -> 9.1 s for one extra
hit, so the defaults are deliberately tight. Raise them if you want more
description-based matching and can spare the subprocess churn.

Usage:
    flatpak_icon.py --cache <cacheRoot> -- <name> [<name> ...]
    flatpak_icon.py <name> [<name> ...]      # legacy: remote-only, no index
"""

import os
import subprocess
import sys
import time

EXCLUDE = (
    ".manual", ".plugin", ".sdk", ".platform", ".extension", ".locale",
    ".addon", "gtk3theme", "-gtk3", ".theme",
)

BUDGET_SECONDS = float(os.environ.get("FOSSFETCH_FLATPAK_BUDGET", "5"))
REMOTE_MAX = int(os.environ.get("FOSSFETCH_FLATPAK_REMOTE_MAX", "3"))


def norm(s):
    return "".join(c for c in s.lower() if c.isalnum())


# Arch renames packages that Flathub still lists under the plain upstream name:
# firefox-esr -> Firefox, libreoffice-fresh -> LibreOffice, google-chrome ->
# Google Chrome. Stripping these before the index lookup costs nothing and
# recovers most of the misses without spending the remote budget.
ARCH_SUFFIXES = (
    "fresh", "esr", "bin", "git", "stable", "nightly", "bin",
    "qt5", "qt6", "desktop", "full", "common",
)


def lookup_keys(name):
    """Candidate normalized keys for a package name, best first."""
    keys = []
    raw = str(name).lower()
    parts = [p for p in raw.replace("_", "-").split("-") if p]
    while len(parts) > 1 and parts[-1] in ARCH_SUFFIXES:
        parts.pop()
        keys.append(norm("-".join(parts)))
    keys.append(norm(raw))
    seen = set()
    return [k for k in keys if k and not (k in seen or seen.add(k))]


def is_variant(appid):
    low = appid.lower()
    return any(x in low for x in EXCLUDE)


def load_index(cache_root):
    """Build the local name/basename/app-id lookup tables.

    Missing or unreadable index is not an error: the remote tier still runs.
    """
    tables = ({}, {}, {})
    if not cache_root:
        return tables
    try:
        path = os.path.join(cache_root, "flathub", "names.tsv")
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 2:
                    continue
                aid = parts[0].strip()
                name = parts[1].strip()
                if not aid or is_variant(aid):
                    continue
                by_name, by_base, by_id = tables
                if name:
                    by_name.setdefault(norm(name), aid)
                by_base.setdefault(norm(aid.split(".")[-1]), aid)
                by_id.setdefault(norm(aid), aid)
    except OSError:
        return ({}, {}, {})
    return tables


def local_lookup(tables, name):
    keys = lookup_keys(name)
    if not keys:
        return ""
    # Every table is tried for every key before falling back to the remote tier,
    # so an exact display-name hit always beats a looser suffix-stripped one.
    for table in tables:
        for k in keys:
            hit = table.get(k)
            if hit:
                return hit
    return ""


def run(term):
    try:
        out = subprocess.run(
            ["flatpak", "search", "--columns=application,name", term],
            capture_output=True, text=True, timeout=8,
        ).stdout
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        appid = parts[0].strip()
        dname = parts[1].strip()
        if appid:
            rows.append((appid, dname))
    return rows


def remote_lookup(name, deadline):
    """Score `flatpak search` hits for one name, or "" if the budget is spent."""
    if time.monotonic() >= deadline:
        return ""
    pn = norm(name)
    terms = [name]
    spaced = name.replace("-", " ")
    if spaced != name:
        terms.append(spaced)

    best_score = 0
    best_id = ""
    for term in terms:
        if time.monotonic() >= deadline:
            break
        for appid, dname in run(term):
            if is_variant(appid):
                continue
            dn = norm(dname)
            base = appid.split(".")[-1] if "." in appid else appid
            score = 0
            if dn and dn == pn:
                score = 3
            elif norm(base) == pn or norm(appid) == pn:
                score = 2
            if score > best_score:
                best_score = score
                best_id = appid
    return best_id


def parse_args(argv):
    cache_root = ""
    names = argv
    if "--cache" in argv:
        idx = argv.index("--cache")
        if idx + 1 < len(argv):
            cache_root = argv[idx + 1]
        names = argv[idx + 2:]
    if names and names[0] == "--":
        names = names[1:]
    return cache_root, names


def main():
    cache_root, names = parse_args(sys.argv[1:])
    if not names:
        return
    tables = load_index(cache_root)
    deadline = time.monotonic() + max(0.0, BUDGET_SECONDS)
    remote_budget = max(0, REMOTE_MAX)
    for name in names:
        appid = local_lookup(tables, name)
        if not appid and remote_budget > 0 and time.monotonic() < deadline:
            remote_budget -= 1
            appid = remote_lookup(name, deadline)
        print("N|%s|%s" % (name, appid))


if __name__ == "__main__":
    main()