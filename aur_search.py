#!/usr/bin/env python3
# AUR live-search helper for the fossfetch panel.
#
# Queries the Arch User Repository RPC v5 `search` endpoint and emits one
# tab-separated row per match:
#
#   name \t description \t version \t website \t license \t packagebase \t votes
#   \t lastmodified \t maintainer \t outofdate
#
# The default `by=name-desc` search matches both package names and
# descriptions, so natural phrases like "video editing" surface relevant
# packages the same way the AppStream-category mapping does for the pacman and
# flatpak tabs. The AUR has no category taxonomy, so there is no group-marker
# "G|" line here — the whole search is live.
#
# Pure data on stdout (nothing else); always exits 0 so the panel's
# StdioCollector gets a clean stream. A single trailing STATUS frame lets the
# panel tell apart a successful-but-empty result set from a backend failure:
#
#   STATUS|ok|<count>        search ran, <count> rows emitted above
#   STATUS|error|<reason>    AUR lookup failed: network, oversized/unparseable,
#                            or an in-band RPC v5 error response ({"type":"error",
#                            "error":"..."}), which the AUR returns for a bad
#                            query, a rate limit, or a broken endpoint. All three
#                            are genuine failures and must not be mistaken for
#                            "no matches".
import json
import os
import sys
import urllib.parse
import urllib.request

# name, description, version, website, license, packagebase, votes,
# lastmodified, maintainer, outofdate (a unix timestamp, "" when current).
QUERY_COLUMNS = 10
MAX_BYTES = int(os.environ.get("FOSSFETCH_MAX_AUR", "8388608"))  # 8 MiB cap


def fetch(query):
    url = os.environ.get("AUR_RPC_URL", "https://aur.archlinux.org/rpc/")
    separator = "&" if "?" in url else "?"
    url += separator + "v=5&type=search&arg=" + urllib.parse.quote(query, safe="")
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


def clean_license(value):
    """Normalize the RPC's License field to a comma-joined string.

    v5 returns a string for a single license and a list for multiple, but the
    payload is remote and unvalidated — anything else (a dict, a list of
    non-strings) must not be handed straight to str.join, which would raise and
    turn a usable response into a traceback.
    """
    if isinstance(value, str):
        return cleanup(value)
    if isinstance(value, (list, tuple)):
        return cleanup(",".join(v for v in value if isinstance(v, str)))
    return ""


def clean_list(value):
    """Flatten an RPC field that may be a string, a list, or junk.

    Every dependency field comes back as a Python list, and `str()` on that
    leaks the repr — a sheet showing "['pacman>6.1', 'git']" instead of
    "pacman>6.1, git". Non-string members are dropped rather than stringified.
    """
    if isinstance(value, str):
        return cleanup(value)
    if isinstance(value, (list, tuple)):
        return cleanup(", ".join(v for v in value if isinstance(v, str)))
    return ""


def fetch_info(pkg):
    """Full metadata for ONE package via the RPC's `info` interface.

    `search` deliberately returns only NameSearch fields; Depends, Conflicts,
    Provides, Groups and License are not in it. The details sheet needs them,
    but only for the one package the user actually opened, so this is called
    lazily rather than per keystroke.
    """
    base = os.environ.get("AUR_RPC_URL", "https://aur.archlinux.org/rpc/")
    separator = "&" if "?" in base else "?"
    url = (base + separator + "v=5&type=info&arg[]="
           + urllib.parse.quote(pkg, safe=""))
    req = urllib.request.Request(url, headers={"User-Agent": "fossfetch-grouping/1.0"})
    try:
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
            return json.loads(bytes(data).decode("utf-8", "replace"))
    except Exception:
        return None


def emit_info(pkg):
    """Print the dependency/licence facts for one package as `I|<field>|<value>`."""
    data = fetch_info(pkg)
    if not isinstance(data, dict) or data.get("type") == "error":
        print("STATUS|error|aur info unavailable")
        return
    results = data.get("results")
    if not isinstance(results, list) or not results:
        print("STATUS|error|package not found in the AUR")
        return
    p = results[0]
    if not isinstance(p, dict):
        print("STATUS|error|response rejected (entry is not an object)")
        return
    fields = (
        ("Version", "version"), ("License", "licenses"), ("Depends", "dependsOn"),
        ("OptDepends", "optionalDeps"), ("Conflicts", "conflictsWith"),
        ("Provides", "provides"), ("Groups", "groups"), ("URL", "website"),
    )
    for key, label in fields:
        print("I|%s|%s" % (label, clean_list(p.get(key))))
    print("STATUS|ok|info")


def main():
    if len(sys.argv) < 2:
        return
    # `info <pkg>` — one package's full metadata, for the details sheet.
    if sys.argv[1] == "info":
        if len(sys.argv) < 3 or not sys.argv[2].strip():
            print("STATUS|error|usage: aur_search.py info <package>")
            return
        emit_info(sys.argv[2].strip())
        return
    query = sys.argv[1]
    try:
        data = fetch(query)
    except Exception as e:
        print("STATUS|error|network: %s" % cleanup(str(e)))
        return
    if data is None:
        # Oversized / unparseable response: emit a rejected frame instead of a
        # silent (and misleadingly empty) result set.
        print("STATUS|error|response rejected (oversized or unparseable)")
        return
    if not isinstance(data, dict):
        print("STATUS|error|response rejected (not a JSON object)")
        return
    # The RPC reports failures in-band, as a well-formed body with
    # type:"error" and an empty results list. Treating that as a successful
    # empty search is exactly the confusion the STATUS frame exists to prevent,
    # so surface the server's own message.
    if data.get("type") == "error":
        print("STATUS|error|aur: %s" % cleanup(data.get("error") or "request rejected"))
        return

    # A well-formed response whose content is unusable (results not a list, or
    # entries that are not objects) is not a transport failure: report zero
    # rows rather than crashing.
    results = data.get("results")
    if not isinstance(results, list):
        results = []
    count = 0
    for p in results:
        if not isinstance(p, dict):
            continue
        name = cleanup(p.get("Name"))
        if not name:
            continue
        desc = cleanup(p.get("Description"))
        version = cleanup(p.get("Version"))
        website = cleanup(p.get("URL"))
        license_ = clean_license(p.get("License"))
        pkgbase = cleanup(p.get("PackageBase")) or name
        votes = str(p.get("NumVotes") or "")
        lastmod = str(p.get("LastModified") or "")
        # Popularity is the AUR's own 0..1 "how many people have this
        # installed" figure, maintained separately from votes. It answers a
        # different question than NumVotes ("is this well-regarded?"), so both
        # are carried. Emitted with a fixed 3-decimal precision so it never
        # renders as a float's platform-dependent trailing digits.
        pop = p.get("Popularity")
        try:
            popularity = "%.3f" % float(pop) if pop is not None else ""
        except (TypeError, ValueError):
            popularity = ""
        # Trust signals. The RPC returns null/0 for packages that are current;
        # anything non-zero in OutOfDate means the maintainer has flagged it as
        # out of date, which is the single most useful warning on an AUR card.
        maintainer = cleanup(p.get("Maintainer"))
        outofdate = p.get("OutOfDate")
        try:
            outofdate = str(int(outofdate)) if outofdate else ""
        except (TypeError, ValueError):
            outofdate = ""
        # NOTE: the RPC's *search* interface does not return Depends, Conflicts,
        # Provides, Groups or even License — only NameSearch does. Those facts
        # are fetched on demand by the `info` subcommand when the details sheet
        # is opened, rather than turning every keystroke into N extra requests.
        print("\t".join([name, desc, version, website, license_, pkgbase, votes,
                         lastmod, maintainer, outofdate, popularity]))
        count += 1
    print("STATUS|ok|%d" % count)


if __name__ == "__main__":
    main()