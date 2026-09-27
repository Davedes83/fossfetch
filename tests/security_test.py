#!/usr/bin/env python3
"""Security regression tests for the fossfetch plugin.

Covers the review findings:
  * oversize / no-Content-Length responses  (flathub groups, AUR)
  * gzip bombs                                (flathub groups, arch groups)
  * tar path traversal                        (appstream icons)
  * tar symlink / hardlink members            (appstream icons)
  * checksum binding before use               (appstream icons + groups)
  * QML Text.PlainText sinks + URL allowlist  (static scan of Panel.qml)
  * STATUS|... error-vs-empty channel contract (AUR backend)

Run:  python3 tests/security_test.py
"""

import gzip
import http.server
import io
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.dirname(HERE)
ICONS = os.path.join(PLUGIN, "appstream_icons.sh")
GROUPS = os.path.join(PLUGIN, "appstream_groups.sh")
STATE = os.path.join(PLUGIN, "appstream_state.py")
FLATHUB = os.path.join(PLUGIN, "flathub_groups.py")
AUR = os.path.join(PLUGIN, "aur_search.py")
PANEL = os.path.join(PLUGIN, "Panel.qml")
PINS = os.path.join(PLUGIN, "appstream_pins.sh")
BACKEND_PACMAN = os.path.join(PLUGIN, "backend_pacman.sh")
BACKEND_FLATPAK = os.path.join(PLUGIN, "backend_flatpak.sh")

VER = "20260101"


class FixtureServer:
    def __init__(self):
        self.routes = {}
        self._httpd = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), self._Handler)
        self._httpd.routes = self.routes
        self.port = self._httpd.server_address[1]
        self._httpd.requests = []
        self.thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self.thread.start()

    @property
    def requests(self):
        return self._httpd.requests

    class _Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def do_GET(self):
            self.server.requests.append(self.path)
            routes = self.server.routes
            spec = routes.get(self.path.split("?")[0])
            if spec is None:
                # Content-Length + Connection: close are required here: with
                # protocol_version HTTP/1.1 and neither header, the connection
                # is kept alive and the client blocks until its own read
                # timeout expires (20s for aur_search), instead of failing fast
                # on a clean 404.
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                return
            payload = spec["data"]
            try:
                if spec.get("no_length"):
                    # Close-delimited body (like a chunked/unbounded response):
                    # do not declare Content-Length so the client must read
                    # until EOF — exercising the actual-read cap.
                    self.send_response(200)
                    self.send_header("Content-Type", spec["ct"])
                    self.send_header("Connection", "close")
                    self.end_headers()
                    for i in range(0, len(payload), 1024):
                        self.wfile.write(payload[i:i + 1024])
                    return
                self.send_response(200)
                self.send_header("Content-Type", spec["ct"])
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass  # client aborted the transfer (size-cap hit) — expected

    def add(self, path, data, ct="application/octet-stream", no_length=False):
        self.routes[path] = {"data": data, "ct": ct, "no_length": no_length}

    def url(self, path):
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def close(self):
        self._httpd.shutdown()
        self._httpd.server_close()
        self.thread.join(timeout=5)


def sha256(b):
    import hashlib
    return hashlib.sha256(b).hexdigest()


def make_sums(art, xml, filler=None):
    """Fixture equivalent of the reviewed, immutable FOSSFETCH_PINNED_SUMS pin.

    Slots mirror appstream_pins.sh: per repo (core, extra, multilib) x
    (xml=0, icons-48x48=1, icons-64x64=2, icons-128x128=3).
    """
    filler = sha256(filler or b"\x00-unused")
    return [sha256(xml) if s % 4 == 0 else sha256(art) if s % 4 == 1 else filler
            for s in range(12)]


def make_valid_icons_tar():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, content in (
            ("gimp_org.gimp.GIMP.png", b"\x89PNG-fake-gimp"),
            ("firefox_org.mozilla.firefox.png", b"\x89PNG-fake-firefox"),
        ):
            info = tarfile.TarInfo(name)
            info.size = len(content)
            tf.addfile(info, io.BytesIO(content))
    buf.seek(0)
    return buf.read()


def make_evil_icons_tar():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        info = tarfile.TarInfo("../evil.png")
        info.size = 4
        tf.addfile(info, io.BytesIO(b"evil"))
        sym = tarfile.TarInfo("sym.png")
        sym.type = tarfile.SYMTYPE
        sym.linkname = "/etc/passwd"
        tf.addfile(sym)
        hard = tarfile.TarInfo("hard.png")
        hard.type = tarfile.LNKTYPE
        hard.linkname = "../../etc/shadow"
        tf.addfile(hard)
    buf.seek(0)
    return buf.read()


def make_xml(pairs):
    comps = []
    for cid, name, cats in pairs:
        catxml = "".join("<category>%s</category>" % c for c in cats)
        comps.append(
            '<component type="desktop-application"><id>%s</id>'
            "<pkgname>%s</pkgname><name>%s</name><summary>S</summary>%s</component>"
            % (cid, cid, name, catxml)
        )
    return ("<?xml version=\"1.0\"?><components>%s</components>" % "".join(comps)).encode()


def make_gzip_bomb(kb=1024):
    return gzip.compress(b"\x00" * (kb * 1024))


class FossFetchTests(unittest.TestCase):
    def setUp(self):
        self.srv = FixtureServer()
        # Scratch dir under the real home (owner-checked chain) — the hardened
        # cache helper refuses to descend through shared/writable dirs like /tmp.
        self.root = tempfile.mkdtemp(prefix="fossfetch-test-",
                                     dir=os.path.expanduser("~"))

    def tearDown(self):
        self.srv.close()
        shutil.rmtree(self.root, ignore_errors=True)

    def env(self):
        # Strip ambient overrides so a developer with FOSSFETCH_* / ARCH_BASE /
        # AUR_RPC_URL / FLATHUB_APPSTREAM_URL exported does not get
        # order-dependent, confusing failures. Each test supplies its own.
        e = {k: v for k, v in os.environ.items()
             if not k.startswith("FOSSFETCH_")
             and k not in ("ARCH_BASE", "AUR_RPC_URL", "FLATHUB_APPSTREAM_URL")}
        e["HOME"] = self.root
        return e

    def fake_bin(self, name, body):
        """Create an executable stub on a private bin dir and return a PATH
        that resolves `name` to it. Used to drive the backends' status logic
        deterministically (a "flatpak" that exits 1 with no output, etc.)."""
        d = os.path.join(self.root, "fakebin")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, name)
        with open(p, "w") as fh:
            fh.write("#!/bin/sh\n" + body)
        os.chmod(p, 0o755)
        return d + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin")

    # ---------------------------------------------------------------- flathub
    def run_flathub(self, extra_env):
        e = self.env()
        e.update(extra_env)
        p = subprocess.run(
            [sys.executable, FLATHUB, "ensure", os.path.join(self.root, "cache")],
            capture_output=True, text=True, timeout=60, env=e)
        return p.returncode, p.stdout, p.stderr

    def test_flathub_oversized_close_delimited(self):
        self.srv.add("/flathub/appstream.xml.gz", b"\x00" * (128 * 1024),
                     no_length=True)
        rc, out, err = self.run_flathub({
            "FLATHUB_APPSTREAM_URL": self.srv.url("/flathub/appstream.xml.gz"),
            "FOSSFETCH_MAX_RAW": "16384",
        })
        self.assertNotEqual(rc, 0)
        self.assertFalse(os.path.exists(
            os.path.join(self.root, "cache", "flathub", "groups.tsv")))

    def test_flathub_gzip_bomb(self):
        self.srv.add("/flathub/appstream.xml.gz", make_gzip_bomb(1024))
        rc, out, err = self.run_flathub({
            "FLATHUB_APPSTREAM_URL": self.srv.url("/flathub/appstream.xml.gz"),
            "FOSSFETCH_MAX_RAW": str(32 * 1024 * 1024),
            "FOSSFETCH_MAX_OUT": "65536",
        })
        self.assertNotEqual(rc, 0)
        self.assertFalse(os.path.exists(
            os.path.join(self.root, "cache", "flathub", "groups.tsv")))

    def test_flathub_valid(self):
        xml = make_xml([("org.example.App", "Example", ["Audio"])])
        self.srv.add("/flathub/appstream.xml.gz", gzip.compress(xml))
        rc, out, err = self.run_flathub({
            "FLATHUB_APPSTREAM_URL": self.srv.url("/flathub/appstream.xml.gz"),
            "FOSSFETCH_MAX_RAW": str(8 * 1024 * 1024),
            "FOSSFETCH_MAX_OUT": str(64 * 1024 * 1024),
        })
        self.assertEqual(rc, 0, err)
        target = os.path.join(self.root, "cache", "flathub", "groups.tsv")
        self.assertTrue(os.path.exists(target))
        with open(target, encoding="utf-8") as fh:
            self.assertIn("Audio\torg.example.App", fh.read())

    def test_flathub_newline_in_fields_is_flattened(self):
        # Remote <name>/<summary> may contain tabs and newlines. Written
        # verbatim, a newline splits one TSV record into two and the tail is
        # emitted by resolve() as a phantom row with a garbage appid. Every
        # field must be flattened to a single line.
        xml = make_xml([("org.example.App", "Multi\nLine\tName", ["Audio"])])
        self.srv.add("/flathub/appstream.xml.gz", gzip.compress(xml))
        e = self.env()
        e["FLATHUB_APPSTREAM_URL"] = self.srv.url("/flathub/appstream.xml.gz")
        p = subprocess.run(
            [sys.executable, FLATHUB, "ensure", os.path.join(self.root, "cache")],
            capture_output=True, text=True, timeout=60, env=e)
        self.assertEqual(p.returncode, 0, p.stderr)
        target = os.path.join(self.root, "cache", "flathub", "groups.tsv")
        with open(target, encoding="utf-8") as fh:
            lines = [l for l in fh.read().splitlines() if l]
        # Exactly one record for the one component, and it is six fields.
        self.assertEqual(len(lines), 1, lines)
        self.assertEqual(len(lines[0].split("\t")), 6, lines[0])
        self.assertNotIn("\n", lines[0])
        self.assertIn("Multi Line Name", lines[0])

    # ------------------------------------------------------------------- AUR
    def test_aur_oversized(self):
        payload = json_dumps({"results": [{"Name": "pad"}] * 5000})
        self.srv.add("/aur/rpc", payload.encode(), ct="application/json")
        e = self.env()
        e["AUR_RPC_URL"] = self.srv.url("/aur/rpc?y=1")
        e["FOSSFETCH_MAX_AUR"] = "1024"
        p = subprocess.run(
            [sys.executable, AUR, "coolapp"],
            capture_output=True, text=True, timeout=60, env=e)
        self.assertEqual(p.returncode, 0)
        # A rejected response is reported through the STATUS channel instead of
        # being silently indistinguishable from a legitimate empty result.
        self.assertEqual(p.stdout.strip(), "STATUS|error|response rejected (oversized or unparseable)")

    def test_aur_status_ok_empty(self):
        # A successful search with zero matches must be distinguishable from a
        # backend failure: no rows + a clear STATUS|ok|<count> frame.
        self.srv.add("/aur/rpc", json_dumps({"results": []}).encode(), ct="application/json")
        e = self.env()
        e["AUR_RPC_URL"] = self.srv.url("/aur/rpc?y=1")
        p = subprocess.run(
            [sys.executable, AUR, "no-such-thing-xyz"],
            capture_output=True, text=True, timeout=60, env=e)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout.strip(), "STATUS|ok|0")

    def test_aur_status_error_network(self):
        # An unreachable endpoint (no route added -> a clean 404) surfaces as an
        # explicit error frame rather than a silent empty result set.
        e = self.env()
        e["AUR_RPC_URL"] = self.srv.url("/aur-does-not-exist?y=1")
        p = subprocess.run(
            [sys.executable, AUR, "coolapp"],
            capture_output=True, text=True, timeout=60, env=e)
        self.assertEqual(p.returncode, 0)
        self.assertTrue(p.stdout.startswith("STATUS|error|network:"), p.stdout)

    def test_aur_status_error_api_error(self):
        # The RPC reports failures in-band, as a well-formed body with
        # type:"error" and an empty results list. That must surface as an
        # explicit error frame, NOT as a successful-but-empty search.
        self.srv.add("/aur/rpc", json_dumps({
            "version": 5, "type": "error", "resultcount": 0,
            "error": "Too many results for query", "results": [],
        }).encode(), ct="application/json")
        e = self.env()
        e["AUR_RPC_URL"] = self.srv.url("/aur/rpc?y=1")
        p = subprocess.run(
            [sys.executable, AUR, "a"],
            capture_output=True, text=True, timeout=60, env=e)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(
            p.stdout.strip(), "STATUS|error|aur: Too many results for query")
        self.assertNotIn("STATUS|ok|", p.stdout)

    def test_aur_malformed_payload_is_not_a_crash(self):
        # A well-formed response whose content is unusable (results not a
        # list, or entries that are not objects) is not a transport failure:
        # report zero rows rather than raising and printing a traceback.
        for payload in ({"results": "oops"}, {"results": [1, 2, 3]}):
            with self.subTest(payload=payload):
                self.srv.add("/aur/rpc", json_dumps(payload).encode(),
                             ct="application/json")
                e = self.env()
                e["AUR_RPC_URL"] = self.srv.url("/aur/rpc?y=1")
                p = subprocess.run(
                    [sys.executable, AUR, "coolapp"],
                    capture_output=True, text=True, timeout=60, env=e)
                self.assertEqual(p.returncode, 0)
                self.assertEqual(p.stdout.strip(), "STATUS|ok|0")
                self.assertNotIn("Traceback", p.stderr)

    def test_aur_license_field_never_raises(self):
        # License is a string or list upstream, but the payload is remote and
        # unvalidated: a dict (or a list of non-strings) must not reach
        # str.join and turn a usable response into a crash.
        self.srv.add("/aur/rpc", json_dumps({
            "results": [{"Name": "pad", "License": {"a": 1}}],
        }).encode(), ct="application/json")
        e = self.env()
        e["AUR_RPC_URL"] = self.srv.url("/aur/rpc?y=1")
        p = subprocess.run(
            [sys.executable, AUR, "pad"],
            capture_output=True, text=True, timeout=60, env=e)
        self.assertEqual(p.returncode, 0)
        self.assertNotIn("Traceback", p.stderr)
        self.assertTrue(p.stdout.strip().endswith("STATUS|ok|1"), p.stdout)

    # ------------------------------------------------------- appstream icons
    def pin_env(self, sums):
        e = self.env()
        e["FOSSFETCH_PINNED_VER"] = VER
        e["FOSSFETCH_PINNED_SUMS"] = " ".join(sums)
        return e

    def serve_arch(self, arts, xmls=None):
        for repo, tar in arts.items():
            self.srv.add("/arch/%s/%s/icons-48x48.tar.gz" % (VER, repo), tar)
        for repo, x in (xmls or {}).items():
            self.srv.add("/arch/%s/%s/Components-x86_64.xml.gz" % (VER, repo), x)

    def run_icons(self, mode, *extra, sums=None, env=None):
        e = self.pin_env(sums or [sha256(b"\x00")] * 12)
        e["ARCH_BASE"] = self.srv.url("/arch")
        if env:
            e.update(env)
        p = subprocess.run(
            ["bash", ICONS, mode, os.path.join(self.root, "cache")] + list(extra),
            capture_output=True, text=True, timeout=90, env=e)
        return p.returncode, p.stdout, p.stderr

    def test_icons_checksum_mismatch_refused(self):
        # Served archive does not match the immutable pin -> refused, not parsed.
        tar = make_evil_icons_tar()
        sums = make_sums(b"different-archive", b"ignored")
        self.serve_arch({"core": tar})
        rc, out, err = self.run_icons("ensure", sums=sums)
        self.assertNotEqual(rc, 0)
        self.assertFalse(os.path.exists(
            os.path.join(self.root, "cache", "catalog", VER)))

    def test_icons_traversal_symlink_rejected(self):
        tar = make_evil_icons_tar()
        sums = make_sums(tar, b"ignored")
        self.serve_arch({"core": tar})
        rc, out, err = self.run_icons("ensure", sums=sums)
        self.assertNotEqual(rc, 0)
        self.assertFalse(os.path.exists(
            os.path.join(self.root, "cache", "catalog", VER)))
        self.assertFalse(os.path.exists(os.path.join(self.root, "..", "evil.png")))

    def test_icons_oversized_rejected(self):
        sums = make_sums(make_valid_icons_tar(), b"ignored")
        self.srv.add("/arch/%s/core/icons-48x48.tar.gz" % VER,
                     b"\x00" * (128 * 1024), no_length=True)
        rc, out, err = self.run_icons("ensure", sums=sums,
                                      env={"FOSSFETCH_MAX_RAW": "65536"})
        self.assertNotEqual(rc, 0)

    def test_icons_valid_extracts_and_resolves(self):
        tar = make_valid_icons_tar()
        sums = make_sums(tar, b"ignored")
        self.serve_arch({"core": tar, "extra": tar, "multilib": tar})
        rc, out, err = self.run_icons("ensure", sums=sums)
        self.assertEqual(rc, 0, err)
        core = os.path.join(self.root, "cache", "catalog", VER, "core")
        self.assertTrue(os.path.exists(os.path.join(core, "gimp_org.gimp.GIMP.png")))
        rc, out, err = self.run_icons("resolve", "gimp", "firefox", sums=sums)
        self.assertEqual(rc, 0)
        lines = [l for l in out.strip().splitlines() if l]
        self.assertEqual(len(lines), 2)
        for l in lines:
            self.assertTrue(l.startswith("I|"), l)
            self.assertTrue(l.endswith(".png"), l)

    # ------------------------------------------------------- appstream groups
    def run_groups(self, mode, *extra, sums=None, env=None):
        e = self.pin_env(sums or [sha256(b"\x00")] * 12)
        e["ARCH_BASE"] = self.srv.url("/arch")
        if env:
            e.update(env)
        p = subprocess.run(
            ["bash", GROUPS, mode, os.path.join(self.root, "cache")] + list(extra),
            capture_output=True, text=True, timeout=90, env=e)
        return p.returncode, p.stdout, p.stderr

    def test_groups_gzip_bomb_rejected(self):
        valid_tar = make_valid_icons_tar()
        bomb = make_gzip_bomb(256)
        sums = make_sums(valid_tar, bomb)
        self.serve_arch({"core": valid_tar, "extra": valid_tar, "multilib": valid_tar},
                        xmls={"core": bomb, "extra": bomb, "multilib": bomb})
        rc, out, err = self.run_groups("ensure", sums=sums,
                                       env={"FOSSFETCH_MAX_XML": "65536"})
        self.assertNotEqual(rc, 0)
        self.assertFalse(os.path.exists(
            os.path.join(self.root, "cache", "catalog", VER, "groups.tsv")))

    def test_groups_oversized_rejected(self):
        valid_tar = make_valid_icons_tar()
        big = b"\x00" * (128 * 1024)
        sums = make_sums(valid_tar, big)
        self.serve_arch({"core": valid_tar, "extra": valid_tar, "multilib": valid_tar},
                        xmls={"core": big, "extra": big, "multilib": big})
        rc, out, err = self.run_groups("ensure", sums=sums,
                                       env={"FOSSFETCH_MAX_RAW": "65536"})
        self.assertNotEqual(rc, 0)
        self.assertFalse(os.path.exists(
            os.path.join(self.root, "cache", "catalog", VER, "groups.tsv")))

    def test_groups_valid_network(self):
        valid_tar = make_valid_icons_tar()
        xml = gzip.compress(make_xml([("org.example.App", "Example", ["Audio"])]))
        sums = make_sums(valid_tar, xml)
        self.serve_arch({"core": valid_tar, "extra": valid_tar, "multilib": valid_tar},
                        xmls={"core": xml, "extra": xml, "multilib": xml})
        rc, out, err = self.run_groups("ensure", sums=sums)
        self.assertEqual(rc, 0, err)
        self.assertTrue(os.path.exists(
            os.path.join(self.root, "cache", "catalog", VER, "groups.tsv")))

    # ------------------------------------------- local (pacman-verified) source
    def test_local_swcatalog_used_offline(self):
        sw = os.path.join(self.root, "swcatalog")
        for repo in ("core", "extra", "multilib"):
            d = os.path.join(sw, "icons", "archlinux-arch-%s" % repo, "48x48")
            os.makedirs(d)
            with open(os.path.join(d, "gimp_org.gimp.GIMP.png"), "wb") as fh:
                fh.write(b"\x89PNG-fake")
        os.makedirs(os.path.join(sw, "xml"))
        for repo in ("core", "extra", "multilib"):
            with open(os.path.join(sw, "xml", "%s.xml.gz" % repo), "wb") as fh:
                fh.write(gzip.compress(
                    make_xml([("org.example.App", "Example", ["Audio"])])))
        e = self.env()
        e["FOSSFETCH_SWCATALOG"] = sw
        e["FOSSFETCH_SWCATALOG_VER"] = "20260101-1"
        e["ARCH_BASE"] = self.srv.url("/arch")
        p = subprocess.run(
            ["bash", ICONS, "ensure", os.path.join(self.root, "cache")],
            capture_output=True, text=True, timeout=90, env=e)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(os.path.exists(
            os.path.join(self.root, "cache", "catalog", "20260101-1", "core",
                        "gimp_org.gimp.GIMP.png")))
        p = subprocess.run(
            ["bash", ICONS, "resolve", os.path.join(self.root, "cache"), "gimp"],
            capture_output=True, text=True, timeout=90, env=e)
        self.assertEqual(p.returncode, 0)
        self.assertIn("I|gimp|", p.stdout)
        p = subprocess.run(
            ["bash", GROUPS, "ensure", os.path.join(self.root, "cache")],
            capture_output=True, text=True, timeout=90, env=e)
        self.assertEqual(p.returncode, 0, p.stderr)
        with open(os.path.join(
                self.root, "cache", "catalog", "20260101-1", "groups.tsv"),
                encoding="utf-8") as fh:
            self.assertIn("Audio\torg.example.App", fh.read())
        self.assertEqual(self.srv.requests, [],
                         "local source must not hit the network at all")

    def test_catalog_preserved_when_version_indeterminate(self):
        # A sealed local source with no derivable version used to compute an
        # empty `want`, which then reached `prune "$cache" ""` — an empty keep
        # value matches no entry, so the entire catalog was deleted before the
        # swap failed on the empty path component. The contract that matters is
        # simple: a build that does not succeed must not destroy the last good
        # catalog, whatever the reason.
        sw = os.path.join(self.root, "swcatalog")
        for repo in ("core", "extra", "multilib"):
            d = os.path.join(sw, "icons", "archlinux-arch-%s" % repo, "48x48")
            os.makedirs(d)
            with open(os.path.join(d, "gimp_org.gimp.GIMP.png"), "wb") as fh:
                fh.write(b"\x89PNG-fake")
        os.makedirs(os.path.join(sw, "xml"))

        cache = os.path.join(self.root, "cache")
        keeper = os.path.join(cache, "catalog", VER, "core", "gimp_org.gimp.GIMP.png")
        os.makedirs(os.path.dirname(keeper))
        with open(keeper, "wb") as fh:
            fh.write(b"PRESERVED")
        with open(os.path.join(cache, "catalog", "current"), "w") as fh:
            fh.write(VER + "\n")

        # A pacman that exists but fails the query => no derivable local version
        # (FOSSFETCH_SWCATALOG is set, FOSSFETCH_SWCATALOG_VER is not).
        e = self.env()
        e["PATH"] = self.fake_bin("pacman", "exit 1\n")
        e["FOSSFETCH_SWCATALOG"] = sw
        e["ARCH_BASE"] = self.srv.url("/arch")
        p = subprocess.run(
            ["bash", ICONS, "ensure", cache],
            capture_output=True, text=True, timeout=90, env=e)
        # The build fails (nothing is served for the pinned version) ...
        self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        # ... but the previously built catalog is still there.
        self.assertTrue(os.path.exists(keeper),
                        "a failed build destroyed the existing catalog")

    def test_groups_rejects_unusable_date_dir(self):
        # The catalog version is read back from the `current` marker and used
        # to build a path, so a corrupted/hand-edited marker must be refused
        # rather than steering the build outside the catalog root.
        cache = os.path.join(self.root, "cache")
        os.makedirs(os.path.join(cache, "catalog"))
        with open(os.path.join(cache, "catalog", "current"), "w") as fh:
            fh.write("../../../etc\n")
        e = self.env()
        e["ARCH_BASE"] = self.srv.url("/arch")
        p = subprocess.run(
            ["bash", GROUPS, "ensure", cache],
            capture_output=True, text=True, timeout=90, env=e)
        self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)

    # ---------------------------------------------- hardened state transactions
    def test_symlinked_cache_root_refused(self):
        # An attacker-preplanted symlink in the cache chain must be refused and
        # never followed into a write or recursive delete.
        victim = os.path.join(self.root, "victim")
        os.makedirs(victim)
        sentinel = os.path.join(victim, "sentinel.txt")
        with open(sentinel, "w") as fh:
            fh.write("do not delete")
        cache = os.path.join(self.root, "cache")
        os.symlink(victim, cache)
        probes = [
            ["python3", STATE, "ensure", cache],
            ["python3", STATE, "tmpdir", cache],
            ["python3", STATE, "prune", cache, "x"],
        ]
        for cmd in probes:
            p = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=60, env=self.env())
            self.assertNotEqual(p.returncode, 0, cmd)
        # The symlink in the chain is refused: nothing may be created inside
        # the victim directory via the cache path.
        self.assertFalse(os.path.exists(os.path.join(victim, "catalog")))

    def test_options_write_is_atomic_and_no_follow(self):
        path = os.path.join(self.root, ".local/state/omarchy/settings",
                            "davedes.fossfetch.json")
        os.makedirs(os.path.dirname(path))
        # Pre-plant a symlink at the destination: writes must replace the entry,
        # never write through the link.
        target = os.path.join(self.root, "hostage.json")
        with open(target, "w") as fh:
            fh.write("hostage")
        os.symlink(target, path)
        p = subprocess.run(
            ["python3", STATE, "write-options", path],
            input='{"showCoffee": false}\n', capture_output=True, text=True,
            timeout=60, env=self.env())
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse(os.path.islink(path),
                         "symlink destination must be replaced, not followed")
        with open(path, encoding="utf-8") as fh:
            self.assertEqual('{"showCoffee": false}\n', fh.read())
        with open(target, encoding="utf-8") as fh:
            self.assertEqual("hostage", fh.read())

    # ------------------------------------------------------------ pin sanity
    def test_pins_wellformed_and_used_slots_distinct(self):
        # The pin array IS the trust anchor for the network download path, so a
        # hand-typing slip must not survive review. Read the committed values by
        # sourcing the file in a bash subshell (it is pure data).
        p = subprocess.run(
            ["bash", "-c",
             '. "$1"; printf "%s\\n" "$PINNED_PKGVER"; printf "%s\\n" "${PINNED_SHA256SUMS[@]}"',
             "_", PINS],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        lines = p.stdout.strip().splitlines()
        self.assertGreaterEqual(len(lines), 2, p.stdout)
        ver, pins = lines[0], lines[1:]

        self.assertRegex(ver, r"^\d{8}$")
        self.assertEqual(len(pins), 12, pins)
        for pin in pins:
            self.assertRegex(pin, r"^[0-9a-f]{64}$")

        # Slots 0 (xml) and 1 (48x48) are the only ones read at runtime, and
        # they must differ per repo — a copy-paste between them would let a
        # mismatched archive verify against the wrong trust anchor. (Slots 2/3
        # are NOT required to be distinct: upstream genuinely publishes some
        # icon sizes with identical bytes, e.g. core 48x48 == 128x128 at
        # pkgver 20260821. Asserting uniqueness there would fail on correct
        # data, so do not.)
        for i, repo in enumerate(("core", "extra", "multilib")):
            with self.subTest(repo=repo):
                self.assertNotEqual(pins[i * 4], pins[i * 4 + 1],
                                    "xml and 48x48 pins must differ for " + repo)

    # ------------------------------------------------ search backend STATUS
    def run_backend(self, script, argv, path=None, env_extra=None):
        e = self.env()
        if path is not None:
            e["PATH"] = path
        if env_extra:
            e.update(env_extra)
        # Invoke via an absolute interpreter path: these tests deliberately set a
        # minimal PATH (to control which backends resolve), which would
        # otherwise hide `sh` itself from subprocess.
        p = subprocess.run(
            ["/bin/sh", script] + list(argv), capture_output=True, text=True,
            timeout=60, env=e)
        return p

    def test_flatpak_backend_no_match_is_not_an_error(self):
        # `flatpak search` exits 1 when it matches nothing, which is the common
        # case for a query that finds no app. Treating any non-zero exit as a
        # failure reported every legitimate miss as "Lookup failed".
        path = self.fake_bin("flatpak", "exit 1\n")
        stub = os.path.join(self.root, "groups_stub.py")
        with open(stub, "w") as fh:
            fh.write("#!/usr/bin/env python3\npass\n")
        p = self.run_backend(
            BACKEND_FLATPAK, ["nosuchapp-xyz", os.path.join(self.root, "cache"),
                               stub], path=path)
        self.assertIn("STATUS|ok|flatpak", p.stdout, p.stdout + p.stderr)
        self.assertNotIn("STATUS|error", p.stdout)

    def test_flatpak_backend_binary_missing_is_an_error(self):
        stub = os.path.join(self.root, "groups_stub.py")
        with open(stub, "w") as fh:
            fh.write("#!/usr/bin/env python3\npass\n")
        # A PATH with no flatpak at all.
        empty = os.path.join(self.root, "emptybin")
        os.makedirs(empty, exist_ok=True)
        p = self.run_backend(
            BACKEND_FLATPAK, ["gimp", os.path.join(self.root, "cache"), stub],
            path=empty)
        self.assertIn("STATUS|error|flatpak binary missing", p.stdout, p.stdout)

    def test_flatpak_backend_rows_and_ok(self):
        # A match: the row is passed through and the frame is still ok.
        path = self.fake_bin(
            "flatpak",
            'printf "GIMP\\tGNU Image Manipulation\\torch.gimp.GIMP\\t2.10.38\\n"\n')
        stub = os.path.join(self.root, "groups_stub.py")
        with open(stub, "w") as fh:
            fh.write("#!/usr/bin/env python3\npass\n")
        p = self.run_backend(
            BACKEND_FLATPAK, ["gimp", os.path.join(self.root, "cache"), stub],
            path=path)
        self.assertIn("orch.gimp.GIMP", p.stdout, p.stdout)
        self.assertTrue(p.stdout.rstrip().endswith("STATUS|ok|flatpak"), p.stdout)

    def test_pacman_backend_status_frames(self):
        stub = os.path.join(self.root, "groups_stub.sh")
        with open(stub, "w") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        os.chmod(stub, 0o755)
        cache = os.path.join(self.root, "cache")

        # no match: rc 1, empty stderr -> ok (not an error)
        p = self.run_backend(BACKEND_PACMAN, ["nosuch-xyz", cache, stub],
                             path=self.fake_bin("pacman", "exit 1\n"))
        self.assertTrue(p.stdout.rstrip().endswith("STATUS|ok|pacman"), p.stdout)

        # genuine failure: rc 1 with an error line on stderr -> error frame
        p = self.run_backend(
            BACKEND_PACMAN, ["gimp", cache, stub],
            path=self.fake_bin("pacman",
                               'echo "error: database missing" >&2\nexit 1\n'))
        self.assertIn("STATUS|error|pacman: error: database missing",
                      p.stdout, p.stdout)

    # ------------------------------------------------------------ QML static
    def test_qml_hardening(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # URL scheme allowlist gates the metadata website link.
        self.assertIn("function isSafeWebUrl", src)
        self.assertNotIn(
            "onClicked: Qt.openUrlExternally(delegateRoot.website)", src)
        self.assertIn("root.isSafeWebUrl(delegateRoot.website)", src)
        # Every metadata / user-input text sink is plain text. Assert on the
        # specific sinks that receive remote data rather than a global count,
        # so an unrelated refactor cannot silently change the guarantee.
        for probe in (
            'id: descText',        # package description
            'root.detailPoints(',  # version/repo/arch/license
            'FitText: Text {',     # component base (name + install labels)
        ):
            self.assertIn(probe, src)
        # The rich-text sinks are the ones that matter: assert no Text element
        # that binds remote metadata defaults to a rich-text format.
        self.assertNotIn("textFormat: Text.RichText", src)
        self.assertNotIn("textFormat: Text.AutoText", src)
        self.assertNotIn("textFormat: Text.StyledText", src)

    def test_qml_uses_extracted_backends(self):
        # The pacman/flatpak STATUS|-frame logic lives in bundled scripts now,
        # so it is directly testable (see the flatpak/pacman backend tests).
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        self.assertNotIn("sh\", \"-c\", pacmanScript", src)
        self.assertNotIn("sh\", \"-c\", flatpakScript", src)
        self.assertIn("root.pacmanBackendScript", src)
        self.assertIn("root.flatpakBackendScript", src)


def json_dumps(obj):
    import json
    return json.dumps(obj)


def main():
    # The scripts are invoked explicitly as `bash <script>` / `sh <script>`,
    # so no execute bit is required and the suite never mutates file modes in
    # the source tree.
    unittest.main(verbosity=2)


if __name__ == "__main__":
    main()