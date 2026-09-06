#!/usr/bin/env python3
# AUR live-search helper for the fossfetch panel.
#
# Queries the Arch User Repository RPC v5 `search` endpoint and emits one
# tab-separated row per match:
#
#   name \t description \t version \t website \t license \t packagebase \t votes \t lastmodified
#
# The default `by=name-desc` search matches both package names and
# descriptions, so natural phrases like "video editing" surface relevant
# packages the same way the AppStream-category mapping does for the pacman and
# flatpak tabs. The AUR has no category taxonomy, so there is no group-marker
# "G|" line here — the whole search is live.
#
# Pure data on stdout (nothing else); always exits 0 so the panel's
# StdioCollector gets a clean stream. Network errors yield an empty result set.
import json
import os
import sys
import urllib.parse
import urllib.request

QUERY_COLUMNS = 8
MAX_BYTES = int(os.environ.get("FOSSFETCH_MAX_AUR", "8388608"))  # 8 MiB cap


def fetch(query):
    url = os.environ.get("AUR_RPC_URL", "https://aur.archlinux.org/rpc/")
    separator = "&" if "?" in url else "?"
    url += separator + "v=5&type=search&arg=" + urllib.parse.quote(query)
    req = urllib.request.Request(url, headers={"User-Agent": "fossfetch-grouping/1.0"})
    # Bounded read: reject a declared Content-Length over the cap and abort once
    # `cap` actual bytes have been read (covers chunked responses).
    with urllib.request.urlopen(req, timeout=20) as resp:
        declared = resp.headers.get("Content-Length")
        if declared is not None:
            try:
                if int(declared) > MAX_BYTES:
                    return None
            except ValueError:
                pass
        data = bytearray()
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            data += chunk
            if len(data) > MAX_BYTES:
                return None
    try:
        return json.loads(bytes(data).decode("utf-8", "replace"))
    except ValueError:
        return None


def cleanup(value):
    return str(value or "").replace("\t", " ").replace("\n", " ").strip()


def main():
    if len(sys.argv) < 2:
        return
    query = sys.argv[1]
    try:
        data = fetch(query)
    except Exception:
        return
    if not data:
        # Oversized / unparseable response: emit nothing (clean empty result).
        return
    results = data.get("results") or []
    for p in results:
        name = cleanup(p.get("Name"))
        if not name:
            continue
        desc = cleanup(p.get("Description"))
        version = cleanup(p.get("Version"))
        website = cleanup(p.get("URL"))
        license_ = cleanup(",".join(p.get("License") or []))
        pkgbase = cleanup(p.get("PackageBase")) or name
        votes = str(p.get("NumVotes") or "")
        lastmod = str(p.get("LastModified") or "")
        print("\t".join([name, desc, version, website, license_, pkgbase, votes, lastmod]))


if __name__ == "__main__":
    main()