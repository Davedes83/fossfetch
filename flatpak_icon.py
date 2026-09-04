#!/usr/bin/env python3
"""Resolve a list of app/package names to their Flathub app id.

Emits one line per argument:  N|<name>|<appid>   (empty appid if none matched)

Matching strategy: run `flatpak search` for a few candidate spellings of each
name, then score the returned (appid, display-name) pairs. Prefer an exact
display-name match, then an appid basename match; never pick Manual/Plugin/
Sdk/Platform/Extension/Locale/Theme variant bundles (those would give the
wrong icon).
"""

import subprocess
import sys

EXCLUDE = (
    ".manual", ".plugin", ".sdk", ".platform", ".extension", ".locale",
    ".addon", "gtk3theme", "-gtk3", ".theme",
)


def norm(s):
    return "".join(c for c in s.lower() if c.isalnum())


def is_variant(appid):
    low = appid.lower()
    return any(x in low for x in EXCLUDE)


def run(term):
    try:
        out = subprocess.run(
            ["flatpak", "search", "--columns=application,name", term],
            capture_output=True, text=True, timeout=15,
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


def resolve(name):
    if not name:
        return ""
    pn = norm(name)
    terms = [name, name.replace("-", " "), name.replace("_", " ")]
    seen = set()
    candidates = []
    for term in terms:
        if term in seen:
            continue
        seen.add(term)
        candidates.extend(run(term))

    best_score = 0
    best_id = ""
    for appid, dname in candidates:
        if is_variant(appid):
            continue
        dn = norm(dname)
        base = appid.split(".")[-1] if "." in appid else appid
        score = 0
        if dn and dn == pn:
            score = 3
        elif norm(base) == pn:
            score = 2
        elif norm(appid) == pn:
            score = 2
        if score > best_score:
            best_score = score
            best_id = appid
    return best_id


def main():
    for name in sys.argv[1:]:
        print("N|%s|%s" % (name, resolve(name)))


if __name__ == "__main__":
    main()
