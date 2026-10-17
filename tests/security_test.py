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
FLATPAK_ICON = os.path.join(PLUGIN, "flatpak_icon.py")
AUR = os.path.join(PLUGIN, "aur_search.py")
PANEL = os.path.join(PLUGIN, "Panel.qml")
BARWIDGET = os.path.join(PLUGIN, "BarWidget.qml")
PINS = os.path.join(PLUGIN, "appstream_pins.sh")
BACKEND_PACMAN = os.path.join(PLUGIN, "backend_pacman.sh")
BACKEND_FLATPAK = os.path.join(PLUGIN, "backend_flatpak.sh")
UPDATE_SCAN = os.path.join(PLUGIN, "update_scan.sh")
UPDATE_SCAN_QML = os.path.join(PLUGIN, "UpdateScan.qml")
HOTKEY = os.path.join(PLUGIN, "install_hotkey.sh")

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

    # ---------------------------------------------------------- QML stdin EOF
    def test_qml_options_writer_closes_stdin(self):
        # appstream_state.py's write-options reads stdin to EOF before it writes
        # anything, and Quickshell only closes the child's write channel when
        # stdinEnabled goes false. A writer that misses the close blocks in
        # read() forever: the options file is never written and every setting
        # silently reverts on shell reset. The script-level test above cannot
        # catch this because subprocess `input=` does close stdin.
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        block = re.search(r"Process \{\s*\n\s*id: optionsWriter\b.*?\n  \}",
                          src, re.S)
        self.assertIsNotNone(block, "optionsWriter Process not found in Panel.qml")
        body = block.group(0)
        write = body.find("optionsWriter.write(")
        close = body.find("optionsWriter.stdinEnabled = false")
        self.assertNotEqual(write, -1, "optionsWriter never writes its payload")
        self.assertNotEqual(close, -1,
                            "optionsWriter never closes stdin: write-options "
                            "would block forever and options would not persist")
        self.assertLess(write, close, "stdin must be closed after the write")

        # persistOptions has to reopen the channel before restarting the helper,
        # or every save after the first would write nothing at all.
        fn = re.search(r"function persistOptions\(\) \{.*?\n  \}", src, re.S)
        self.assertIsNotNone(fn, "persistOptions not found in Panel.qml")
        fbody = fn.group(0)
        self.assertIn("optionsWriter.stdinEnabled = true", fbody)
        self.assertLess(fbody.find("optionsWriter.stdinEnabled = true"),
                        fbody.find("optionsWriter.running = false"),
                        "stdin must be reopened before the helper is restarted")

    # ------------------------------------------------- native editable inputs
    def test_no_native_editable_text_input(self):
        """The query line must not be a native editable text input.

        An editable native text item makes the Qt Wayland path treat the
        shared shell process as a clipboard consumer: on the packaged Qt
        6.12.0, a clipboard change is read synchronously inside the shell —
        foreign text, no byte cap, no overall deadline, without any paste
        (the review hold that drove this). The plugin is built from a
        key-buffered Item instead; none of the native text-input types may
        come back by accident.
        """
        for name in (PANEL, BARWIDGET, UPDATE_SCAN_QML):
            with open(name, encoding="utf-8") as fh:
                src = fh.read()
            for token in ("TextField", "TextArea", "TextEdit", "TextInput",
                          "selectByMouse"):
                self.assertNotIn(token, src,
                                 "%s must not host a native editable text input"
                                 % os.path.basename(name))

    def test_panel_does_not_shadow_the_base_opened_property(self):
        """Panel.qml must not redeclare `opened`.

        The shell's Panel base type exposes `opened` as a readonly alias of its
        PanelController, and that is the whole open/close mechanism:
        controller.show() flips the controller, the alias follows, and
        KeyboardPanel.open is bound to it.

        A same-typed `property bool opened: false` in the derived panel
        silently shadows that alias with a plain property nothing ever writes.
        controller.show() then does nothing at all: the panel stays at zero
        implicit size, the bar button appears dead, and nothing is logged. The
        KeyboardPanel write-back (`onOpenChanged: root.opened = open`) exists
        only to feed that dead property and cannot compile against the
        readonly alias, so it goes too -- KeyboardPanel.close() already routes
        through owner.close() -> controller.hide().
        """
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        self.assertNotIn("property bool opened", src,
                         "redeclaring `opened` shadows the shell Panel's readonly "
                         "alias and silently kills the panel's open lifecycle")
        self.assertNotIn("root.opened =", src,
                         "`opened` is a readonly alias of the PanelController "
                         "and must never be assigned")
        # The popup still has to be driven from the controller.
        self.assertIn("open: root.opened", src,
                      "KeyboardPanel must stay bound to the controller's state")
        self.assertIn("root.controller.show()", src)

    def test_panel_loader_is_not_deferred(self):
        """The panel Loader must stay active, not gated on an open request.

        Deferring the panel's construction until the first click was tried and
        reverted. It does not survive contact with the shell: a panel built
        outside shell start-up never finishes wiring its controller, so
        controller.show() is a no-op and the button does nothing. With the
        native text field gone there is no clipboard surface left for deferral
        to keep out of the tree, and a panel that cannot open is worse than one
        that stays loaded.
        """
        with open(BARWIDGET, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn("active: true", src,
                      "the panel Loader must be always-active")
        for token in ("panelRequested", "pendingOpen", "unloadTimer"):
            self.assertNotIn(token, src,
                             "%s only existed to gate the panel Loader"
                             % token)

    def test_query_line_measures_text_without_textinput_only_apis(self):
        """Caret and selection placement must not use TextInput-only methods.

        `positionToRectangle()` reads like the obvious way to map a character
        index to a pixel, but it is declared on TextInput/TextEdit only. Called
        on the plain Text that draws the query it is undefined, so every
        binding that used it threw on each evaluation and the caret and
        selection band were left unplaced. TextMetrics measures the prefix in
        the same font instead, using advanceWidth so a trailing space (which
        `width` drops) still advances the caret.
        """
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # Only comments may mention it, never a call.
        code = "\n".join(line.split("//", 1)[0] for line in src.split("\n"))
        self.assertNotIn("positionToRectangle", code,
                         "positionToRectangle does not exist on Text; measure "
                         "with TextMetrics instead")
        self.assertIn("TextMetrics", src)
        self.assertIn("caretMetrics.advanceWidth", src,
                      "the caret must be placed from a measured prefix")
        self.assertIn("selEndMetrics.advanceWidth", src)

    def test_clipboard_read_is_a_bounded_child(self):
        """The clipboard is read only through a bounded, short-lived child.

        `wl-paste` runs in a separate process, and the command carries the
        bounds in itself: `timeout` as the overall deadline (a stalled
        provider cannot hang the window) and `head -c` as the hard byte cap
        (an oversized payload stops the transfer instead of being read whole
        into memory). And the only in-QML entry point is an explicit paste —
        the clipboard must never be read by QML state changes alone.
        """
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        self.assertRegex(
            src,
            r'"timeout \d+ wl-paste[^\n"]*head -c \d+')
        # The command itself must carry both bounds: a deadline (`timeout`)
        # and a byte cap (`head -c`). A read that misses either is the
        # unbounded surface the review held on.
        # The read has exactly two callers: the explicit paste path and the
        # speculative suggestion. Both type check through the same intent
        # flags, and nothing else starts the child.
        self.assertIn("function pasteQuery()", src)
        self.assertIn("pasteMode", src)
        clip_start = src.index("Process {\n    id: clipProc")
        guard = src[clip_start:src.index("onOpenedChanged")]
        self.assertNotIn("running: true,", guard,
                         "clipProc must never run on its own")

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

    def test_update_scan_frames_and_parses(self):
        """The update scan's output contract.

        Three things have to hold for the badge and the Updates tab to be
        trustworthy:
          * each source emits `UPD|kind|name|<available>` with the AVAILABLE
            version (the panel looks the installed one up itself, from its
            `pacman -Q` snapshot, so the two can never disagree about what is
            installed);
          * only real "name old -> new" rows become UPD lines — a stray
            diagnostic must not be counted as a pending update;
          * the run ends with a single STATUS|ok frame, so an empty result (the
            healthy, common case) is not reported as a failure.
        """
        # repo package + AUR helper + a flatpak, all from one scan
        path = self.fake_bin("checkupdates",
                             'echo "vivaldi 8.2.4133.47-1 -> 8.3.0-1"\n')
        self.fake_bin("yay",
                             'echo "aurtool 1.0-1 -> 1.1-1"\n')
        self.fake_bin("flatpak",
                             'printf "org.vinegarhq.Sober\\t2.0.0\\n"\n')
        p = self.run_backend(UPDATE_SCAN, ["yay"], path=path)
        self.assertIn("UPD|pacman|vivaldi|8.3.0-1", p.stdout, p.stdout)
        self.assertIn("UPD|yay|aurtool|1.1-1", p.stdout, p.stdout)
        self.assertIn("UPD|flatpak|org.vinegarhq.Sober|2.0.0", p.stdout, p.stdout)
        self.assertTrue(p.stdout.rstrip().endswith("STATUS|ok|updates"), p.stdout)

        # No updates anywhere is normal, not an error, and must not fabricate
        # a row out of the empty output.
        path = self.fake_bin("checkupdates", "exit 0\n")
        self.fake_bin("yay", "exit 0\n")
        self.fake_bin("flatpak", "exit 0\n")
        p = self.run_backend(UPDATE_SCAN, ["yay"], path=path)
        self.assertNotIn("UPD|", p.stdout, p.stdout)
        self.assertIn("STATUS|ok|updates", p.stdout)
        self.assertNotIn("STATUS|error", p.stdout)

        # A missing tool is not a scan failure: it contributes no rows, and the
        # other sources still get to report.
        path = self.fake_bin("checkupdates", 'echo "git 2.40-1 -> 2.41-1"\n')
        p = self.run_backend(UPDATE_SCAN, ["definitely-not-installed-helper"],
                             path=path)
        self.assertIn("UPD|pacman|git|2.41-1", p.stdout, p.stdout)
        self.assertIn("STATUS|ok|updates", p.stdout)

        # A warning line that is not "old -> new" must not become an update.
        path = self.fake_bin("checkupdates",
                             'echo "warning: database is out of date"\n'
                             'echo "gimp 2.10.38-5 -> 2.10.38-6"\n')
        p = self.run_backend(UPDATE_SCAN, [""], path=path)
        self.assertIn("UPD|pacman|gimp|2.10.38-6", p.stdout, p.stdout)
        self.assertNotIn("warning", p.stdout, p.stdout)

    def test_failed_scan_is_not_reported_as_no_updates(self):
        """A source that could not answer must not look like a clean empty scan.

        `checkupdates` copies the sync databases to a temp dir first, so it
        fails outright while anything holds the pacman lock -- which is exactly
        when the eager post-startup scan runs. Its stderr used to be discarded,
        so that failure produced zero rows and a confident `STATUS|ok|updates`.
        The panel read that as "you have no updates", so the badge and the
        Updates tab vanished and stayed vanished for five minutes while updates
        were waiting.

        So a failure has to be visible as a failure, and the panel has to refuse
        to let an incomplete scan overwrite a known count with zero.
        """
        path = self.fake_bin(
            "checkupdates",
            'echo "==> ERROR: failed to init transaction" >&2\n'
            'echo "==> ERROR: unable to lock database" >&2\n'
            "exit 1\n")
        self.fake_bin("yay", "exit 0\n")
        self.fake_bin("flatpak", "exit 0\n")
        p = self.run_backend(UPDATE_SCAN, ["yay"], path=path)
        self.assertIn("SCANFAIL|checkupdates", p.stdout, p.stdout)
        self.assertIn("STATUS|degraded|updates", p.stdout, p.stdout)
        self.assertNotIn("STATUS|ok|updates", p.stdout,
                         "a scan that failed must not claim to be clean")
        # And the reason has to survive to be diagnosable -- the FIRST error
        # line, which is the one that names the actual failure.
        self.assertIn("failed to init transaction", p.stdout, p.stdout)

        with open(UPDATE_SCAN_QML, encoding="utf-8") as fh:
            src = fh.read()
        # The scan parser lives on the bar widget's UpdateScan object, not the
        # panel: the panel loads only while open, and the badge must stay honest
        # while it is closed, so the parse cannot depend on the panel existing.
        # The scanner keeps `unknown` distinct from `none`.
        self.assertIn("if (degraded && rows.length === 0)", src)
        self.assertIn("scan.updatesDegraded = true", src)
        self.assertIn("updateRetry.start()", src)
        # updateCount is only ever written by a scan that actually completed.
        guard = src[src.index("if (degraded && rows.length === 0)"):]
        guard = guard[:guard.index("scan.updateCount = rows.length")]
        self.assertNotIn("scan.updateCount = 0", guard,
                         "an incomplete scan must never zero the known count")

    def test_checkupdates_exit_two_is_not_a_failure(self):
        """`checkupdates` uses exit 2 to say "up to date", not "failed".

        /usr/bin/checkupdates only reaches `exit 2` from the `else` branch of
        `if (( ${#updates[@]} ))` -- the empty-update case. A genuine failure is
        1, from `die 'Cannot fetch updates'`.

        Treating 2 as a failure made the ordinary case look broken: a machine
        with nothing pending (most machines, most of the time) reported
        `SCANFAIL|checkupdates|exit 2` and `STATUS|degraded`, so the panel showed
        a degraded scan it could never clear. It also kept `updateRetry` armed,
        re-running the whole three-source scan every 25 seconds forever, each
        pass invoking `fakeroot pacman -Sy` against the network.
        """
        # "No updates" is exit 2 with empty output: no SCANFAIL, clean STATUS.
        path = self.fake_bin("checkupdates", "exit 2\n")
        self.fake_bin("yay", "exit 0\n")
        self.fake_bin("flatpak", "exit 0\n")
        p = self.run_backend(UPDATE_SCAN, ["yay"], path=path)
        self.assertNotIn("SCANFAIL|", p.stdout, p.stdout)
        self.assertIn("STATUS|ok|updates", p.stdout, p.stdout)
        self.assertNotIn("UPD|", p.stdout, p.stdout)

        # Exit 1 is still a failure -- the lock case the retry exists for.
        path = self.fake_bin("checkupdates",
                             'echo "error: failed to init transaction" >&2\nexit 1\n')
        self.fake_bin("yay", "exit 0\n")
        self.fake_bin("flatpak", "exit 0\n")
        p = self.run_backend(UPDATE_SCAN, ["yay"], path=path)
        self.assertIn("SCANFAIL|checkupdates", p.stdout, p.stdout)
        self.assertIn("STATUS|degraded|updates", p.stdout, p.stdout)

        # Exit 2 with output is not a thing, but if it ever happened the rows
        # must still be honoured rather than dropped by the success path.
        path = self.fake_bin("checkupdates",
                             'echo "git 2.40-1 -> 2.41-1"\nexit 2\n')
        self.fake_bin("yay", "exit 0\n")
        self.fake_bin("flatpak", "exit 0\n")
        p = self.run_backend(UPDATE_SCAN, ["yay"], path=path)
        self.assertIn("UPD|pacman|git|2.41-1", p.stdout, p.stdout)
        self.assertNotIn("SCANFAIL|", p.stdout, p.stdout)

    def test_aur_helper_failure_is_not_reported_as_no_updates(self):
        """A failing AUR helper is a failed source, exactly like checkupdates.

        `yay -Qua` / `paru -Qua` exit non-zero when the pacman lock is held
        (the seconds right after a shell start, when the eager scan runs) and
        print nothing on stdout. Sending stderr to /dev/null turned that into
        zero rows and a confident `STATUS|ok|updates`, so the panel reported
        "no updates" for a check that never ran.
        """
        path = self.fake_bin(
            "paru",
            'echo "error: failed to init transaction (could not lock database)" >&2\n'
            "exit 1\n")
        self.fake_bin("checkupdates", "exit 0\n")
        self.fake_bin("flatpak", "exit 0\n")
        p = self.run_backend(UPDATE_SCAN, ["paru"], path=path)
        self.assertIn("SCANFAIL|paru", p.stdout, p.stdout)
        self.assertIn("STATUS|degraded|updates", p.stdout, p.stdout)
        self.assertNotIn("STATUS|ok|updates", p.stdout,
                         "a scan whose AUR helper failed must not claim to be clean")
        self.assertIn("could not lock database", p.stdout, p.stdout)

        # A PARTIAL scan degrades too: pacman answered, the helper did not.
        path = self.fake_bin(
            "paru",
            'echo "error: could not lock database" >&2\nexit 1\n')
        self.fake_bin("checkupdates", 'echo "git 2.40-1 -> 2.41-1"\n')
        self.fake_bin("flatpak", "exit 0\n")
        p = self.run_backend(UPDATE_SCAN, ["paru"], path=path)
        self.assertIn("UPD|pacman|git|2.41-1", p.stdout, p.stdout)
        self.assertIn("SCANFAIL|paru", p.stdout, p.stdout)
        self.assertIn("STATUS|degraded|updates", p.stdout, p.stdout)

        # A helper that answers cleanly is still just fine.
        path = self.fake_bin("paru", 'echo "yay-pkg 1.0-1 -> 1.1-1"\n')
        self.fake_bin("checkupdates", "exit 0\n")
        self.fake_bin("flatpak", "exit 0\n")
        p = self.run_backend(UPDATE_SCAN, ["paru"], path=path)
        self.assertIn("UPD|paru|yay-pkg|1.1-1", p.stdout, p.stdout)
        self.assertIn("STATUS|ok|updates", p.stdout, p.stdout)
        self.assertNotIn("SCANFAIL|", p.stdout, p.stdout)

    def test_partial_scan_stays_degraded_in_the_panel(self):
        """A partial scan keeps the rows it found AND stays degraded.

        Only a scan where EVERY source failed was treated as unusable; a scan
        that lost one source cleared the flag and stopped the retry, so the
        missing source never came back until the next five-minute tick.
        """
        with open(UPDATE_SCAN_QML, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn("scan.updatesDegraded = degraded", src)
        # Degraded is driven by the flag, never by "did we get rows".
        self.assertNotIn("scan.updatesDegraded = false", src)
        guard = src[src.index("scan.updatesDegraded = degraded"):]
        guard = guard[:guard.index("scan.updateCount = rows.length")]
        self.assertIn("if (degraded) updateRetry.start()", guard)
        self.assertIn("updateRetry.stop()", guard)

    def test_retry_backs_off_when_a_source_stays_broken(self):
        """A source that stays broken must not be retried every 25s forever.

        The retry exists for the transient pacman lock of a shell start, which
        clears in seconds. A source that is still broken after a few retries --
        a dead AUR helper, a missing binary, a machine that is offline -- is
        not going to heal in 25 seconds, and retrying at that rate for the life
        of the session re-runs the whole three-source scan every 25 seconds,
        each pass invoking `fakeroot pacman -Sy` over the network. The interval
        doubles up to the periodic tick instead, and a clean scan resets it.
        """
        with open(UPDATE_SCAN_QML, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn("property int retryInterval: 25000", src,
                      "the retry cadence must be a tunable property")
        self.assertIn("interval: scan.retryInterval", src,
                      "the timer must follow the backoff, not a fixed 25s")
        self.assertIn("scan.retryInterval * 2, 300000", src,
                      "the retry must back off, capped at the periodic tick")
        # A healthy scan is what proves a source can come back, so it is what
        # earns the fast cadence again.
        self.assertIn("scan.retryInterval = 25000", src)

    def test_state_paths_cannot_climb_out_of_the_catalog(self):
        """rmtree/put/tmpfile validate their path, like swap already did.

        Each of these names is used directly by os.open/os.lstat/os.unlink, so a
        "../" in one lands the operation outside the catalog -- a recursive
        delete reaching into the rest of the cache, or a temp file written
        somewhere else entirely.
        """
        cache = os.path.join(self.root, "state-cache")
        os.makedirs(cache, exist_ok=True)
        self.assertEqual(subprocess.run([sys.executable, STATE, "ensure", cache],
                                        capture_output=True, text=True,
                                        timeout=60).returncode, 0)

        # rmtree with no path at all used to raise ValueError out of a tuple
        # unpack: a usage error reported as a traceback.
        p = subprocess.run([sys.executable, STATE, "rmtree", cache],
                           capture_output=True, text=True, timeout=60)
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("Traceback", p.stderr, p.stderr)
        self.assertIn("usage:", p.stderr, p.stderr)

        # A victim planted outside the catalog must survive every path.
        victim_dir = os.path.join(self.root, "outside")
        os.makedirs(victim_dir, exist_ok=True)
        victim = os.path.join(victim_dir, "precious")
        with open(victim, "w") as fh:
            fh.write("keep me")
        outside = os.path.join(cache, "..", "outside")
        for args in (["rmtree", cache, outside],
                     ["rmtree", cache, "v1/../../outside"],
                     ["put", cache, "../outside/planted"],
                     ["swap", cache, "../outside/precious", "v1"]):
            if args[0] == "put":
                p = subprocess.run([sys.executable, STATE] + args,
                                   input="x", capture_output=True, text=True,
                                   timeout=60)
            else:
                p = subprocess.run([sys.executable, STATE] + args,
                                   capture_output=True, text=True, timeout=60)
            self.assertNotEqual(p.returncode, 0, "%s was accepted" % args)
            self.assertNotIn("Traceback", p.stderr, p.stderr)
        self.assertTrue(os.path.exists(victim), "a traversal deleted a file outside the catalog")
        self.assertFalse(os.path.exists(os.path.join(victim_dir, "planted")))

        # tmpfile's <ver> becomes a directory and <prefix> a file name inside
        # it, so both are single-name checks.
        for ver, prefix in (("../outside", "p"), ("v1", "../p")):
            p = subprocess.run([sys.executable, STATE, "tmpfile", cache, ver, prefix],
                               capture_output=True, text=True, timeout=60)
            self.assertNotEqual(p.returncode, 0, "tmpfile accepted %r/%r" % (ver, prefix))
            self.assertNotIn("Traceback", p.stderr, p.stderr)

        # Legitimate use still works: a real nested path is written and removed.
        os.makedirs(os.path.join(cache, "catalog", "v1"), exist_ok=True)
        p = subprocess.run([sys.executable, STATE, "put", cache, "v1/a.txt"],
                           input="hello", capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(os.path.exists(os.path.join(cache, "catalog", "v1", "a.txt")))
        p = subprocess.run([sys.executable, STATE, "tmpfile", cache, "v1", "pfx"],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        p = subprocess.run([sys.executable, STATE, "rmtree", cache, "v1"],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse(os.path.exists(os.path.join(cache, "catalog", "v1")))

    def test_aur_byte_cap_ignores_a_nonsense_value(self):
        """FOSSFETCH_MAX_AUR is a safety limit, not a setting worth crashing on.

        `int()` at import time turned `FOSSFETCH_MAX_AUR=abc` into an unhandled
        ValueError, and the whole search died before it made a request.
        """
        for bad in ("abc", "", "  ", "-5", "0", "1e6", "8388608x"):
            e = self.env()
            e["FOSSFETCH_MAX_AUR"] = bad
            e["AUR_RPC_URL"] = "http://127.0.0.1:1/rpc/"
            p = subprocess.run([sys.executable, AUR, "gimp"], capture_output=True,
                               text=True, timeout=60, env=e)
            self.assertNotIn("Traceback", p.stderr,
                             "FOSSFETCH_MAX_AUR=%r crashed the search" % bad)
            # The search still RAN and reported its own failure in-band; a bad
            # cap must not stop it from getting that far.
            self.assertIn("STATUS|error|", p.stdout, p.stdout)
        # A real override is still honoured.
        e = self.env()
        e["FOSSFETCH_MAX_AUR"] = "1024"
        e["AUR_RPC_URL"] = "http://127.0.0.1:1/rpc/"
        p = subprocess.run([sys.executable, AUR, "gimp"], capture_output=True,
                           text=True, timeout=60, env=e)
        self.assertIn("STATUS|error|", p.stdout, p.stdout)
        self.assertNotIn("Traceback", p.stderr, p.stderr)

    def test_group_staleness_compares_the_index_it_actually_names(self):
        """`current` is a FILE holding the version, not a directory.

        groups_stale stat'd "$STORE/current/groups.tsv", which never existed, so
        the index mtime was always 0 and the function was always true: every
        search threw away a perfectly fresh index and kicked off a rebuild.
        """
        with open(GROUPS, encoding="utf-8") as fh:
            src = fh.read()
        # Read the version out of the marker, then stat the index it names --
        # never a path built by treating the marker FILE as a directory.
        body = src[src.index("groups_stale() {"):]
        body = body[:body.index("\n}\n")]
        self.assertNotIn('"$STORE/current/groups.tsv"', body,
                         "the marker is a file; its groups.tsv never resolved")
        # The stale check reads the version and stats the index it names.
        self.assertIn('index="$STORE/$date_dir/groups.tsv"', src)
        # ...and a hand-edited marker cannot steer it out of the catalog.
        self.assertIn('valid_version "$date_dir" || return 0', src)

    def test_hotkey_combo_cannot_inject_lua(self):
        """$COMBO is written into hyprland.lua, which is LUA.

        A combo carrying a quote closed the string and appended whatever came
        after it to the user's Hyprland config. A real combo is only modifier
        and key names joined by " + ", so anything outside that alphabet is
        refused outright rather than escaped.
        """
        d = os.path.join(self.root, "hypr")
        os.makedirs(d, exist_ok=True)
        lua = os.path.join(d, "hyprland.lua")
        with open(lua, "w") as fh:
            fh.write("-- user config\n")
        for bad in ('SUPER", os.execute("id"), "',
                    "SUPER + CTRL + SHIFT + F') os.exit() --",
                    "SUPER\nSHIFT"):
            p = subprocess.run(["sh", HOTKEY, d, bad], capture_output=True,
                               text=True, timeout=60)
            self.assertIn("STATUS|bad-combo", p.stdout, p.stdout)
        with open(lua, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "-- user config\n",
                             "a rejected combo still wrote to the config")
        # A real combo is still installed.
        p = subprocess.run(["sh", HOTKEY, d, "SUPER + CTRL + SHIFT + F"],
                           capture_output=True, text=True, timeout=60)
        self.assertIn("STATUS|installed", p.stdout, p.stdout)
        with open(lua, encoding="utf-8") as fh:
            self.assertIn('o.bind("SUPER + CTRL + SHIFT + F"', fh.read())

    def test_enter_installs_a_flatpak_only_row(self):
        """cardInstallSpec covers every InstallButton the card can show.

        The Flathub button shows whenever the row carries an app id, on any
        tab. Without the matching branch, Enter did nothing on a flatpak-only
        row while the card showed a button, and a batch silently dropped it.
        """
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        body = src[src.index("function cardInstallSpec"):]
        body = body[:body.index("\n  }")]
        self.assertIn('kind: "flatpak"', body)
        self.assertIn("e.flatpakPkg", body)
        self.assertIn("root.isFlatpakInstalled", body)
        # And the batch path understands that kind: batchCommand's flatpak arm
        # is the default, so no kind silently falls through to nothing.
        self.assertIn('return ["flatpak", "install", "--assumeyes", "flathub"].concat(pkgs)', src)

    # ------------------------------------------------------------ QML static
    def test_model_js_unit_tests_pass(self):
        """Run tests/model_test.js. The pure logic in Model.js is what the
        panel evaluates on every keystroke; if it is not executed by the suite,
        a refactor can break ranking/escaping/status parsing unnoticed."""
        node = shutil.which("node") or shutil.which("nodejs")
        if node is None:
            self.skipTest("node not available; Model.js tests not run")
        proc = subprocess.run(
            [node, os.path.join(HERE, "model_test.js")],
            capture_output=True, text=True, timeout=120,
        )
        self.assertEqual(proc.returncode, 0,
                         "Model.js unit tests failed:\n%s" % (proc.stdout + proc.stderr))

    def test_bar_icon_uses_the_shell_optical_geometry(self):
        """The magnifier must render on the same geometry as every other bar icon.

        Measured off a real bar capture: as a plain Text at font.caption + 1 the
        glyph's painted centre sat at y=12.0 while its neighbours averaged
        y=13.88 — 1.9px too high, and 2px smaller. Qt centres a Text's LINE BOX,
        and this font's ascent/descent are asymmetric, so the painted shape floats
        above the box centre. Every other bar icon has the identical drift; they
        simply share one font size and one canvas (BarIconButton centres
        OpticalGlyph in a Style.bar.iconCanvas box), so it cancels out visually.

        So the fix is to render through the shell's own OpticalGlyph at
        Style.bar.iconFont inside a Style.bar.iconCanvas box — alignment by
        construction, not by an offset nudge that the next font change undoes.
        """
        with open(os.path.join(PLUGIN, "BarWidget.qml"), encoding="utf-8") as fh:
            src = fh.read()

        self.assertIn("import qs.Ui", src, "BarWidget must import the shell UI types")
        self.assertIn("OpticalGlyph {", src, "the magnifier must render via OpticalGlyph")
        self.assertIn("fontSize: Style.font.body", src,
                      "the magnifier must use the same font size as BarIconButton")
        # Negative assertions run over CODE, not raw text: these token names are
        # also named in the comments explaining WHY they are right, so matching
        # the whole file would fail on its own documentation.
        code = "\n".join(ln.split("//")[0] for ln in src.splitlines())
        self.assertNotIn("Style.bar.iconFont", code,
                         "BarIconButton inherits WidgetButton's `body` size; "
                         "iconFont is a different token and shifts the glyph")
        self.assertNotIn("height: 26", code,
                         "the button must track the bar's slot size, not a literal")
        self.assertIn("root.barSize", code)

        # The bar host sizes each slot from the widget root's implicitHeight
        # (Bar.qml), so the root must forward the button's size. It already did;
        # this pins it, because dropping it silently collapses the slot to zero
        # and re-raises the glyph.
        self.assertIn("implicitHeight: button.height", code)
        self.assertIn("Layout.preferredWidth: Style.bar.iconCanvas", src)
        self.assertIn("Layout.preferredHeight: Style.bar.iconCanvas", src)

        # The regression itself: a bare Text at a caption-derived pixel size is
        # what produced the vertical offset, so it must not come back.
        glyph = src[src.index("OpticalGlyph {"):]
        glyph = glyph[:glyph.index("}")]
        self.assertNotIn("anchors.centerIn: parent", glyph,
                         "centring a Text line box is what skewed the glyph")
        self.assertNotIn("font.caption + 1", glyph)
        self.assertIn("anchors.fill: parent", glyph,
                      "fill the icon canvas exactly as BarIconButton does")
        # The family stays explicitly bound — an unset family silently falls
        # back to whatever the process resolved, which reads as a foreign font.
        self.assertIn("fontFamily: Style.font.resolvedFamily", glyph)

    def test_recents_record_the_search_not_every_typed_prefix(self):
        """Typing a word must file ONE recent, not one per debounced keystroke.

        Live search fires on every debounced prefix, so recording a recent from
        that path meant typing "vivaldi" left via, vial, vival, vivald and
        vivaldi behind as five separate entries — the innards of one search,
        presented to the user as five searches. Those prefixes are never
        something anyone runs.

        The recording therefore waits for the typing to settle, or for an
        explicit commit (Enter, Tab, close) which flushes immediately.
        """
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()

        # The old call site must be gone from the live-search path.
        launch = src[src.index("function launchLiveSearch(q)"):]
        launch = launch[:launch.index("\n  }")]
        self.assertNotIn("rememberSearch(", launch,
                         "live search must not record a recent per keystroke")

        # Settle window, armed from the debounced query path.
        self.assertIn("root.noteSearch(pendingQuery,", src)
        self.assertIn("readonly property int recentSettleMs: 1200", src)

        # Every explicit commit flushes rather than waiting out the window.
        for fn in ("function close()", "function switchTab(t)",
                   "function activateCursor()"):
            body = src[src.index(fn):]
            self.assertIn("root.flushRecent()", body[:body.index("\n  }")],
                          "%s must flush the pending search" % fn)

        # A query too short to be worth keeping must not be armed at all.
        note = src[src.index("function noteSearch(q"):]
        note = note[:note.index("\n  }")]
        self.assertIn("term.length < 3", note)
        self.assertIn("recentSettle.stop()", note)

        # The clipboard is offered speculatively. Filling the field is not
        # typing, so it must arm the pending commit (acting on it still
        # remembers it) WITHOUT starting the settle timer (ignoring it must
        # not). A suggestion in the recents is the same bug as "vial" being in
        # the recents.
        self.assertIn("root.suppressRecentSettle = true", src)
        self.assertIn("root.noteSearch(pendingQuery, !root.suppressRecentSettle)", src)
        self.assertIn("if (armTimer === false)", note)

    def test_reordering_reindexes_the_row_lookup_maps(self):
        """A sort must rebuild pkgIndex/flatpakIndex after reordering.

        QQmlListModel has no move operation, so sorting is implemented by
        reading the rows out, re-appending them and clearing the model. Every
        asynchronous write-back (metadata, icons, licences, AUR/Flathub
        details) re-resolves its row through those key -> index maps at apply
        time rather than holding a captured index — which is exactly why a
        re-sort that skips reindexModel() would let a late `pacman -Si` result
        write an icon or a licence onto whichever unrelated package happened to
        have moved into that slot.
        """
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        start = src.index("function applyView(")
        end = src.index("\n  }", start)
        body = src[start:end]
        self.assertIn("root.reindexModel()", body)
        # And it has to come after the model is repopulated, or it indexes the
        # freshly cleared model instead of the new order.
        self.assertLess(body.index("filteredModel.append"),
                        body.index("root.reindexModel()"),
                        "reindexModel must run after the rows are re-appended")

        # The rows must be SNAPSHOTS. QQmlListModel.get() returns objects bound
        # to the live rows, so `clear()` empties them: re-appending the objects
        # themselves after a sort produced blank cards — name, chips and icon
        # all gone, with no error anywhere. Copying first is the whole fix.
        self.assertIn("root.copyRow(r)", body,
                      "applyView must snapshot rows, not re-append live "
                      "model objects that clear() will empty")
        self.assertLess(body.index("root.copyRow(r)"),
                        body.index("filteredModel.clear()"),
                        "rows must be copied BEFORE the model is cleared")
        self.assertIn("function copyRow(r)", src,
                      "copyRow is the snapshot helper applyView depends on")

    def test_hide_installed_never_empties_the_updates_tab(self):
        """Every Updates row is installed by definition.

        So "hide installed" has to be suppressed on that tab, or the tab the
        user opened to see what needs updating goes blank the moment they filter
        anything. The gate is one property, and the filter and the sort bar both
        read it rather than re-deriving the condition themselves."""
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn("readonly property bool hideInstalledActive: "
                      "root.hideInstalled && !root.isUpdates", src)
        # addRow's gate is the only place rows are admitted, and it must go
        # through the guarded property, not the raw flag.
        start = src.index("function addRow(obj)")
        body = src[start:src.index("\n  }", start)]
        self.assertIn("Model.passesFilter(row, "
                      "{ hideInstalled: root.hideInstalledActive })", body)

    def test_persisted_sort_mode_is_validated(self):
        """The settings file is user-writable, so the stored mode is validated.

        An unrecognised mode would leave the cycle index at -1, so Ctrl+S would
        step from nowhere. (How relevance itself is preserved, and why it has to
        be restorable rather than inert, is covered by
        test_relevance_sorting_is_restorable_not_a_no_op.)"""
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn("property string sortMode: \"relevance\"", src)
        self.assertIn("root.sortMode = root.normalizeSort(data.sortMode)", src)
        self.assertIn("function normalizeSort(m)", src)
        # normalizeSort must fall back rather than trust the file.
        norm = src[src.index("function normalizeSort(m)"):]
        norm = norm[:norm.index("\n  }")]
        self.assertIn("\"relevance\"", norm)
        # The view model is pure logic in Model.js, unit-tested separately; the
        # panel must delegate rather than reimplement a comparator inline.
        # (The pre-existing inline sorts are the relevance rankers and the
        # update-scan row order, which are deliberate and unrelated.)
        # effectiveSortMode(), not sortMode: a stored mode the current results
        # cannot honour falls back to relevance rather than pretending to.
        self.assertIn("Model.sortRows(rows, root.effectiveSortMode())", src)

    def test_sort_and_filter_have_keyboard_reachability(self):
        """The search field owns focus, so the controls need real shortcuts.

        A mouse-only sort would be unreachable for a keyboard-first panel — the
        same reason F2 exists. Both are guarded on isLive so they cannot fire on
        the Updates tab, whose result set is not a search result set."""
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn("Qt.Key_S && (event.modifiers & Qt.ControlModifier)", src)
        self.assertIn("Qt.Key_H && (event.modifiers & Qt.ControlModifier)", src)
        self.assertIn("if (root.isLive) root.cycleSort()", src)
        self.assertIn("if (root.isLive) root.setHideInstalled(!root.hideInstalled)", src)
        # Discovered, not merely present: the shortcut is named in the control's
        # own label and the footer hint stays within the panel width.
        self.assertIn("\"Sort: \" + root.sortLabelFor() + \"  (Ctrl+S)\"", src)

    def test_every_model_reference_exists_in_both_js_and_qml(self):
        """Each `Model.x` the panel uses must resolve in Node AND in QML.

        A `.js` file imported with `import "Model.js" as Model` exposes its
        top-level functions and vars as the namespace. `module.exports` exists
        ONLY for the Node test harness. So a helper that is exported for tests
        but declared in a way QML cannot see is `undefined` at runtime while
        every Node test still passes.

        That is not hypothetical: reading `Model.sortModes` instead of calling
        `Model.sortModes()` left it undefined inside Panel.qml's settings
        loader. The loader wraps its body in a try/catch, so the TypeError was
        swallowed and the panel silently ran with DEFAULT preferences — losing
        recents, sort mode and every other setting, with no error anywhere.
        Node's test suite was green the whole time because Node resolved it
        through module.exports.

        So this asserts against Model.js's own top-level declarations rather
        than against its exports block: anything Panel.qml names must be a
        top-level `function name(` or `var name`.
        """
        with open(PANEL, encoding="utf-8") as fh:
            panel = fh.read()
        with open(os.path.join(PLUGIN, "Model.js"), encoding="utf-8") as fh:
            model = fh.read()

        # Comments are stripped first: both the import statement and the
        # comment above it are the literal text `Model.js`, which the reference
        # pattern happily reads as a member access on a symbol called "js".
        # Nothing in a comment can call anything.
        code_only = "\n".join(ln.split("//")[0] for ln in panel.splitlines())
        code_only = re.sub(r'import\s+"Model\.js"\s+as\s+Model', "", code_only)
        used = set(re.findall(r"\bModel\.([A-Za-z_]\w*)", code_only))
        self.assertTrue(used, "expected Panel.qml to use the Model namespace")

        declared = set(re.findall(r"^function\s+([A-Za-z_]\w*)\s*\(", model, re.M))
        declared |= set(re.findall(r"^var\s+([A-Za-z_]\w*)\s*=", model, re.M))
        declared |= set(re.findall(r"^\s*function\s+([A-Za-z_]\w*)\s*\(", model, re.M))

        missing = sorted(used - declared)
        self.assertEqual(missing, [],
                         "Panel.qml references Model.%s which Model.js does not "
                         "declare at top level -- undefined in QML even if it "
                         "is present in module.exports" % ", ".join(missing))

    def test_settings_load_failures_are_not_silent(self):
        """The options loader must not swallow errors with an empty catch.

        One bad line in that try block silently disables EVERY persisted
        preference at once — the panel just comes up with defaults and no
        complaint anywhere. The catch keeps the defaults (that part is right,
        since the file is user-writable) but it has to say so."""
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        loader = src[src.index("id: optionsFile"):]
        loader = loader[:loader.index("function visibleTabs()")]
        self.assertNotIn("catch (e) { /* keep defaults */ }", loader)
        self.assertIn("catch (e) { console.warn(", loader)

    def test_relevance_sorting_is_restorable_not_a_no_op(self):
        """Relevance must PUT THE BACKEND RANKING BACK, not do nothing.

        The backend's ranking is the only ordering that knows the query, so it
        cannot be re-derived from any field on a row — it has to be preserved as
        an insertion order and restored on demand. Treating "relevance" as "leave
        the list alone" meant that once you sorted by name, switching back to
        Relevance kept the alphabetical order: a mode that silently does nothing,
        which reads as a broken sort.

        And a mode whose field is absent from every row must not reorder at all.
        On Pacman results there is no popularity anywhere, so every pair ties and
        the comparator falls through to the name tiebreak — alphabetical order
        under a popularity label. Relevance and Popularity then produced
        identical output and both looked broken.
        """
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        code = "\n".join(ln.split("//")[0] for ln in src.splitlines())

        # Each row records when it was admitted, so the order can be restored.
        self.assertIn("row._order = root.orderSeq++", code)
        self.assertIn("root.orderSeq = 0", code, "the counter resets per search")
        # Declared as a numeric role default so ListModel sees one type from the
        # first append; ListModel cannot change a role's type later.
        self.assertIn("_order", src)

        # Relevance is applied through the sorter, not used as an early return.
        body = src[src.index("function applyView("):]
        body = body[:body.index("\n  }")]
        self.assertIn("Model.sortRows(rows, root.effectiveSortMode())", body)
        self.assertNotIn('if (root.sortMode === "relevance") return', body,
                         "relevance must be restored, not skipped")

        # The cycle only offers modes the current results can actually order by.
        self.assertIn("function computeSortModes()", src)
        self.assertIn("Model.popularityKey(r.aurPopularity) >= 0", src)
        self.assertIn("Model.updatedKey(r.updated) >= 0", src)
        self.assertIn("root.refreshSortModes()", body)
        self.assertIn("root.availableSortModes = root.computeSortModes()", src)
        self.assertIn("function effectiveSortMode()", src)

    def test_a_new_sort_shows_the_top_card_but_settling_keeps_your_place(self):
        """Selecting a sort resets to the top; a backend landing does not.

        A new sort is a new top: the user asked for a different ordering and
        should see its first card, not the viewport left wherever the previous
        order happened to leave it — which lands them on an unrelated set of rows
        halfway down and reads as the sort having jumped somewhere random.

        applyView() is ALSO called each time a slow backend appends its results.
        Resetting to the top there would yank the user away from wherever they
        had scrolled to while waiting, so those calls must preserve the
        highlighted package instead.
        """
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        body = src[src.index("function applyView("):]
        body = body[:body.index("\n  }")]

        self.assertIn("if (resetView)", body)
        reset = body[body.index("if (resetView)"):]
        self.assertIn("resultsList.positionViewAtBeginning()", reset)
        self.assertIn("resultsList.currentIndex = after.length > 0 ? 0 : -1", reset)
        # And the reset happens before the cursor-preserving branch, so a user
        # change can never fall through into it.
        self.assertLess(body.index("if (resetView)"),
                        body.index("positionViewAtIndex"),
                        "the reset must short-circuit before cursor preservation")
        self.assertIn("resultsList.positionViewAtIndex(at, ListView.Contain)", body)

        # User-initiated changes reset; backend completions do not.
        self.assertIn("root.applyView(true)", src[src.index("function setSortMode(m)"):])
        self.assertIn("root.applyView(true)", src[src.index("function setHideInstalled(v)"):])
        settles = src.count("root.applyView()\n")
        self.assertGreater(settles, 0,
                           "backend completions must call applyView() with no reset")

    def test_alternatives_removed_and_all_is_opt_in(self):
        """Alternatives was dropped; the merged All tab must stay opt-in.

        Regression guard for the settings default: 'All' fans out to three
        backends per keystroke, so shipping it on by default would make the
        launcher noticeably slower for everyone who never asked for it."""
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        self.assertNotIn("alternatives.json", src)
        self.assertNotIn("isAlternatives", src)
        self.assertNotIn("alternativesEnabled", src)
        self.assertFalse(os.path.exists(os.path.join(PLUGIN, "alternatives.json")))
        # Default off, and the tab is only offered when it was switched on.
        self.assertIn("property bool allEnabled: false", src)
        # Still opt-in, and the opt-in is honoured as soon as there are TWO
        # source tabs to merge: the old "> 2" test hid the tab the user had
        # explicitly switched on whenever AUR was disabled (Pacman + Flatpak).
        self.assertIn("if (root.allEnabled && list.length > 1) list.push(3)", src)
        # The segmented control renders visibleTabs() directly, so that list is
        # now the single place the All tab can be shown from - one source of
        # truth, rather than a second visibility test that could disagree.
        self.assertIn("model: root.visibleTabs()", src)
        # Exactly three live backends remain.
        for keep in ("isPacman", "isFlatpak", "isAur"):
            self.assertIn("readonly property bool %s" % keep, src)

    def test_removal_is_not_cascading(self):
        """Removal must never take anything the user did not name.

        A launcher uninstall button is the kind of thing people click without
        reading. `pacman -Rns` would also delete dependencies still needed by
        other installed software and skip the .pacsave safety net, so the
        commands are pinned here to the non-cascading form."""
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        for bad in ('"pacman", "-Rns"', '"pacman", "-R", "-s"', '"paru", "-Rs"',
                    '"yay", "-Rs"', '"pacman", "-Rsc"'):
            # assertTrue rather than assertNotIn: a failure here would otherwise
            # dump the whole 2900-line panel into the test output.
            self.assertTrue(bad not in src,
                            "removal must not cascade: found %r" % bad)
        self.assertIn('args = ["sudo", "pacman", "-R", pkg]', src)
        self.assertIn('args = ["flatpak", "uninstall", pkg]', src)
        # Install and removal share one arm slot, so a card can never be armed
        # for both at once.
        self.assertIn("property var pendingAction: null", src)
        self.assertTrue("pendingInstall" not in src,
                        "the old parallel pendingInstall slot should be gone")
        self.assertIn('actionPending("install"', src)
        self.assertIn('actionPending("remove"', src)

    def test_installed_rows_offer_removal(self):
        """The green tick stays, and the button beside it becomes Remove."""
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # The tick still reports installed state for all three sources.
        self.assertIn('text: "Installed"', src)
        # The tick is a glyph in the shared icon map now, not a literal in the
        # card. It still has to come from that map or it silently reverts to a
        # font the text face may not have.
        self.assertIn("text: root.icons.check", src)
        self.assertIn('delegateRoot.installedPacman === "1"', src)
        self.assertIn('delegateRoot.installedAur === "1"', src)
        self.assertIn('delegateRoot.installedFlatpak === "1"', src)
        # Every install button can also remove.
        for kind in ("pacman", "yay", "paru", "flatpak"):
            self.assertIn('onRemoved: root.startRemove("%s"' % kind, src)
        # Enter on the cursor must do what the button shows.
        self.assertIn('if (spec.mode === "remove") root.startRemove(', src)

    def test_every_required_delegate_role_is_populated(self):
        """Every `required property` in the result delegate must be a role the
        model actually fills.

        A missing one is not a crash and not a lint error — QML logs
        "Required property X was not initialized", refuses to instantiate the
        delegate, and the results list renders blank with no visible cause.
        That is exactly what happened when a ternary lost its else branch and
        row.installedFlatpak became undefined.
        """
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()

        # Only the RESULTS delegate — other delegates (recents, sheet facts)
        # bind to different models and have their own requirements. Bound the
        # region at the next section marker so later delegates are not swept in.
        start = src.index("model: filteredModel")
        end = src.index("recent searches", start)
        results = src[start:end]
        required = set(re.findall(r"required property string (\w+)", results))

        # Keys the model guarantees: the addRow defaults object, plus the
        # properties assigned straight onto the row before it is appended.
        addrow = src[src.index("function addRow(obj)"):]
        addrow = addrow[:addrow.index("filteredModel.append(row)")]
        # The defaults are written as one long comma-separated literal, so they
        # must be read by pattern rather than line by line.
        populated = set(re.findall(r"(\w+):\s*\"\"", addrow))
        populated |= set(re.findall(r"row\.(\w+)\s*=", addrow))

        missing = sorted(required - populated)
        self.assertEqual(missing, [],
                         "delegate declares required roles the model never sets: %s"
                         % missing)

        # And the reverse: a role set but never declared is dead weight.
        # (Only warn-by-test, since a non-required role is legal.)

    def test_role_assignments_are_complete_ternaries(self):
        """`row.x = cond ? "a" :` parses and lints fine, then assigns undefined.

        That is the exact shape of the bug that blanked the results list: the
        delegate declared `required property string installedFlatpak`, the model
        set it to undefined, QML logged "Required property ... was not
        initialized", refused to build the delegate, and the panel rendered
        blank. Nothing else in the toolchain notices, so assert the ternary is
        complete for every conditional assignment into a model role.
        """
        with open(PANEL, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
        bad = []
        for i, line in enumerate(lines, 1):
            code = line.split("//")[0]
            m = re.search(r"row\.(\w+)\s*=.*\?", code)
            if not m:
                continue
            # The ELSE branch must exist and be non-empty. Testing for a ':'
            # after the '?' is not enough — a truncated line *ends* with ':',
            # which satisfies that check while leaving the value undefined.
            tail = code[code.index("?") + 1:]
            if ":" not in tail:
                bad.append((i, code.strip(), "no ':' at all"))
            elif tail.split(":", 1)[1].strip() == "":
                bad.append((i, code.strip(), "empty else branch -> undefined"))
        self.assertEqual(bad, [],
                         "conditional role assignments missing an else branch:\n  "
                         + "\n  ".join("%d: %s  [%s]" % b for b in bad))

    def test_helpers_are_not_called_on_the_listmodel(self):
        """Panel helpers live on `root`; ListModel only holds data.

        `filteredModel.rowIndexForPkg(...)` parses and lints fine and throws at
        runtime, so `Required By` silently never populated and the details sheet
        showed no removal warning. Calls that need a panel helper must go
        through root.
        """
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        helpers = set(re.findall(r"function (\w+)\(", src))
        # filteredModel.<x>( ... ) is only ever legitimate for ListModel's own
        # methods; anything else is a panel helper called on the wrong object.
        model_methods = {"get", "set", "setProperty", "append", "clear",
                         "move", "remove", "find", "count"}
        bad = []
        for m in re.finditer(r"filteredModel\.(\w+)\(", src):
            name = m.group(1)
            # ListModel's own methods are fine. Anything else reached for on
            # filteredModel is a PANEL helper being called on the model, which
            # is undefined at runtime.
            if name in model_methods or name not in helpers:
                continue
            line = src[:m.start()].count("\n") + 1
            bad.append("line %d: filteredModel.%s(...) is a root helper" % (line, name))
        self.assertEqual(bad, [],
                         "panel helpers must be called on root, not filteredModel:\n  "
                         + "\n  ".join(bad))

    def test_qml_parses(self):
        """Panel.qml must have no QML syntax errors.

        A single bad token makes the whole file fail to load, and the symptom is
        not an error message in the panel — it is the panel simply never
        opening, which looks like a click-handler bug and sends you hunting in
        the wrong file. This check exists because a `.import "Model.js" as`
        line (invalid; it must be `import "Model.js" as`) shipped exactly that
        way, past two greps that only looked for the string "Failed to parse".
        """
        qmllint = shutil.which("qmllint") or "/usr/lib/qt6/bin/qmllint"
        if not os.path.exists(qmllint):
            self.skipTest("qmllint not available")
        shell_ui = "/usr/share/omarchy/shell"
        cmd = [qmllint]
        if os.path.isdir(shell_ui):
            cmd += ["-I", shell_ui]
        cmd += [PANEL, os.path.join(PLUGIN, "BarWidget.qml"), UPDATE_SCAN_QML]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        out = proc.stdout + proc.stderr
        # qmllint exits 0 and labels real syntax failures only as "Warning:
        # ... [syntax]", so filter on the diagnostics themselves rather than the
        # exit code or a single phrase.
        bad = [ln for ln in out.splitlines()
               if "[syntax]" in ln or "Failed to parse" in ln
               or ": Error" in ln]
        self.assertEqual(bad, [], "QML syntax errors:\n  " + "\n  ".join(bad))

    def test_js_import_uses_valid_qml_syntax(self):
        """`import "x.js" as N` is valid; `.import "x.js" as N` is not."""
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn('import "Model.js" as Model', src)
        # Match a real statement (line starts with `.import`), not the word
        # appearing inside a comment.
        bad_dot = [ln.strip() for ln in src.splitlines()
                   if ln.strip().startswith(".import")]
        self.assertEqual(bad_dot, [],
                         ".import is not valid QML syntax and fails the whole file")
        self.assertTrue(os.path.exists(os.path.join(PLUGIN, "Model.js")),
                        "Model.js is imported but missing from the repo")
        # The delegate must actually use the namespace, or the import is dead.
        self.assertIn("Model.", src)

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
            'id: cardDescription',  # package description
            'root.detailPoints(',   # version/repo/arch/license
            'FitText: Text {',     # component base (name + install labels)
        ):
            self.assertIn(probe, src)
        # Rich text is banned by default — package names and descriptions come
        # from remote metadata and must never be parsed as markup. There is
        # exactly ONE sanctioned exception, the card title, where the matched
        # run is highlighted; it is safe only because every segment is escaped
        # before the single tag this code adds. Assert the exception stays
        # singular and stays escaped.
        self.assertNotIn("textFormat: Text.AutoText", src)
        self.assertNotIn("textFormat: Text.StyledText", src)
        self.assertEqual(src.count("textFormat: Text.RichText"), 1,
                         "exactly one rich-text sink is allowed (the card title)")
        self.assertIn("text: root.highlightName(delegateRoot.name)", src)
        # The escaping and highlighting logic now lives in Model.js (so it can
        # be unit-tested); Panel.qml must delegate rather than reimplement it,
        # or the tested code and the shipped code drift apart.
        with open(os.path.join(PLUGIN, "Model.js"), encoding="utf-8") as fh:
            model = fh.read()
        self.assertIn("function escapeRich(s) { return Model.escapeRich(s) }", src)
        self.assertIn("return Model.highlightName(name, root.query, root.matchColor)", src)
        # Escaping helper neutralises every HTML metacharacter it could meet in
        # an attribute as well as in text content.
        esc = model[model.index("function escapeRich"):]
        esc = esc[:esc.index("\n}")]
        for ch in ('&', '<', '>', '"', "'"):
            self.assertIn("/%s/g" % ch, esc)
        # ...and highlightName runs every interpolated segment through it.
        hl = model[model.index("function highlightName"):]
        hl = hl[:hl.index("\n}")]
        # Five calls: two early-return guards (empty query, no match) plus the
        # three interpolated segments — before, the match itself, and after.
        self.assertEqual(hl.count("escapeRich("), 5)
        for segment in ("escapeRich(n.slice(0, idx))",
                        "escapeRich(n.slice(idx, idx + q.length))",
                        "escapeRich(n.slice(idx + q.length))"):
            self.assertIn(segment, hl)
        # The query is never concatenated into the output, only used to slice.
        self.assertNotIn("+ q +", hl)
        self.assertNotIn("+ query +", hl)
        self.assertNotIn("+ query.length", hl)
        # The bar widget renders nothing but the user's own label.
        with open(os.path.join(PLUGIN, "BarWidget.qml"), encoding="utf-8") as fh:
            self.assertNotIn("RichText", fh.read())

    def test_qml_uses_extracted_backends(self):
        # The pacman/flatpak STATUS|-frame logic lives in bundled scripts now,
        # so it is directly testable (see the flatpak/pacman backend tests).
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        self.assertNotIn("sh\", \"-c\", pacmanScript", src)
        self.assertNotIn("sh\", \"-c\", flatpakScript", src)
        self.assertIn("root.pacmanBackendScript", src)
        self.assertIn("root.flatpakBackendScript", src)

    # ------------------------------------- argv hardening (package/app-id names)
    def test_qml_never_interpolates_package_names_into_shell_text(self):
        # Package names and Flathub app ids come from remote metadata. They must
        # reach the shell as ARGV, never spliced into a `sh -c` script body.
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        forbidden = [
            'names.join(" ")',      # spliced the whole batch into the script
            '+ pkgs[k] +',          # spliced a package name into the script
            '+ flats[m] +',         # spliced a Flathub app id into the script
        ]
        for needle in forbidden:
            self.assertTrue(needle not in src, "Panel.qml still contains %r" % needle)
        # The two generated scripts must iterate their ARGV...
        required = [
            'for p in \\"$@\\"',            # local icon lookup
            'for e in \\"$@\\"',            # license lookup
            'for e in \\"$@\\"; do',       # license loop head
            '"fossfetch-icons"].concat(names)',      # $0 + real argv
            '"fossfetch-licenses"].concat(args)',
        ]
        for needle in required:
            self.assertTrue(needle in src, "Panel.qml is missing %r" % needle)

    def test_lookup_local_icons_script_argv_is_injection_safe(self):
        # End-to-end proof: a crafted "package name" must come out as data.
        script = ('resolve(){ p="$1"; echo "I|$p|"; }\n'
                  'for p in "$@"; do resolve "$p"; done')
        marker = os.path.join(self.root, "pwned")
        hostile = "evil; touch %s" % marker
        p = subprocess.run(
            ["/bin/sh", "-c", script, "fossfetch-icons", hostile],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(p.stdout.strip(), "I|%s|" % hostile)
        self.assertFalse(os.path.exists(marker), "argv quoting leaked a command")

    # ------------------------------------------------- Flathub name index (B1)
    def test_flatpak_icon_resolves_from_local_index_without_network(self):
        cache = os.path.join(self.root, "cache")
        os.makedirs(os.path.join(cache, "flathub"))
        with open(os.path.join(cache, "flathub", "names.tsv"), "w") as fh:
            fh.write("org.mozilla.firefox\tFirefox\n")
            fh.write("org.libreoffice.LibreOffice\tLibreOffice\n")
            fh.write("com.brave.Browser\tBrave\n")
            fh.write("org.kde.krita.Sdk\tKrita SDK\n")  # a variant: must be skipped
        # No `flatpak` on PATH and no network: everything must come from the
        # index. This is the regression guard for the 6.7 s-per-5-names path.
        p = subprocess.run(
            [sys.executable, FLATPAK_ICON, "--cache", cache, "--",
             "firefox", "firefox-esr", "libreoffice-fresh", "brave", "krita", "bash"],
            capture_output=True, text=True, timeout=30,
            env=dict(self.env(), PATH="/nonexistent"))
        got = {}
        for line in p.stdout.strip().split("\n"):
            parts = line.split("|")
            got[parts[1]] = parts[2]
        self.assertEqual(got["firefox"], "org.mozilla.firefox")
        # Arch renames are stripped before the lookup.
        self.assertEqual(got["firefox-esr"], "org.mozilla.firefox")
        self.assertEqual(got["libreoffice-fresh"], "org.libreoffice.LibreOffice")
        self.assertEqual(got["brave"], "com.brave.Browser")
        self.assertEqual(got["bash"], "")

    def test_flatpak_icon_skips_variant_bundles(self):
        cache = os.path.join(self.root, "cache")
        os.makedirs(os.path.join(cache, "flathub"))
        with open(os.path.join(cache, "flathub", "names.tsv"), "w") as fh:
            fh.write("org.kde.krita.Locale\tKrita\n")
            fh.write("org.gimp.GIMP.Sdk\tGIMP\n")
        p = subprocess.run(
            [sys.executable, FLATPAK_ICON, "--cache", cache, "--", "krita", "gimp"],
            capture_output=True, text=True, timeout=30,
            env=dict(self.env(), PATH="/nonexistent"))
        self.assertEqual(p.stdout.strip(), "N|krita|\nN|gimp|")

    def test_flathub_ensure_writes_complete_name_index(self):
        xml = (b"<components>"
               b'<component type="desktop-application">'
               b"<id>org.categorised.App</id><name>Categorised</name>"
               b"<category>Office</category>"
               b"</component>"
               b'<component type="desktop-application">'
               b"<id>org.plain.App</id><name>Plain</name>"
               b"</component>"
               b"</components>")
        self.srv.add("/flathub/appstream.xml.gz", gzip.compress(xml))
        cache = os.path.join(self.root, "cache")
        rc, out, err = self.run_flathub({
            "FLATHUB_APPSTREAM_URL": self.srv.url("/flathub/appstream.xml.gz")})
        self.assertEqual(rc, 0, err)
        # The uncategorised app must be in names.tsv — groups.tsv cannot hold it,
        # which is exactly why flatpak_icon.py needs a separate index.
        names_path = os.path.join(cache, "flathub", "names.tsv")
        with open(names_path, encoding="utf-8") as fh:
            body = fh.read()
        self.assertIn("org.categorised.App\tCategorised", body)
        self.assertIn("org.plain.App\tPlain", body)
        groups = open(os.path.join(cache, "flathub", "groups.tsv"), encoding="utf-8").read()
        self.assertNotIn("org.plain.App", groups)

    # --------------------------------- non-blocking / backed-off catalog (B2,B3)
    def test_flathub_resolve_serves_stale_index_without_any_download(self):
        cache = os.path.join(self.root, "cache")
        os.makedirs(os.path.join(cache, "flathub"))
        with open(os.path.join(cache, "flathub", "groups.tsv"), "w") as fh:
            fh.write("Office\torg.libreoffice.LibreOffice\tLibreOffice\tSuite\t1.0\t1\n")
        with open(os.path.join(cache, "flathub", "names.tsv"), "w") as fh:
            fh.write("org.libreoffice.LibreOffice\tLibreOffice\n")
        # Make the freshness marker ancient so the index counts as stale.
        old = os.path.join(cache, "flathub", "current")
        open(old, "w").close()
        os.utime(old, (0, 0))
        # No route is registered, so ANY request would 404 and be recorded.
        e = self.env()
        e["FLATHUB_APPSTREAM_URL"] = self.srv.url("/flathub/appstream.xml.gz")
        p = subprocess.run(
            [sys.executable, FLATHUB, "resolve", cache, "office"],
            capture_output=True, text=True, timeout=30, env=e)
        # The stale index is still served...
        self.assertIn("org.libreoffice.LibreOffice", p.stdout)
        # ...and the rebuild ran detached rather than inline, so this call did
        # not wait on it (the fixture would have recorded the attempt here).
        self.assertEqual(self.srv.requests, [],
                         "resolve must not block on a catalog rebuild")

    def test_flathub_ensure_backs_off_after_a_failed_build(self):
        self.srv.add("/flathub/appstream.xml.gz", b"not-gzip-at-all")
        cache = os.path.join(self.root, "cache")
        e = self.env()
        e["FLATHUB_APPSTREAM_URL"] = self.srv.url("/flathub/appstream.xml.gz")
        cmd = [sys.executable, FLATHUB, "ensure", cache]
        first = subprocess.run(cmd, capture_output=True, text=True, timeout=60, env=e)
        self.assertNotEqual(first.returncode, 0, "a bad archive must fail the build")
        after_first = len(self.srv.requests)
        self.assertGreater(after_first, 0)
        second = subprocess.run(cmd, capture_output=True, text=True, timeout=60, env=e)
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("backing off", second.stderr)
        # The retry must not have re-downloaded anything.
        self.assertEqual(len(self.srv.requests), after_first)

    def test_flathub_backoff_is_cleared_by_a_successful_build(self):
        cache = os.path.join(self.root, "cache")
        os.makedirs(os.path.join(cache, "flathub"))
        with open(os.path.join(cache, "flathub", ".failed"), "w") as fh:
            fh.write("")
        self.srv.add("/flathub/appstream.xml.gz",
                     gzip.compress(b"<components/>"))
        # An EMPTY marker is what a pre-backoff version of this plugin left
        # behind; it must not read as a failure and lock the index out.
        rc, out, err = self.run_flathub({
            "FLATHUB_APPSTREAM_URL": self.srv.url("/flathub/appstream.xml.gz"),
            "FOSSFETCH_CATALOG_BACKOFF_SECONDS": "86400",
            "FOSSFETCH_CATALOG_BACKOFF_MAX_SECONDS": "86400"})
        self.assertEqual(rc, 0, err)
        self.assertFalse(os.path.exists(os.path.join(cache, "flathub", ".failed")))

    def test_flathub_backoff_grows_with_repeated_failures(self):
        # A fixed maximum would lock a user out for hours after a 30-second
        # outage; the window must start at the base and double per failure.
        import importlib.util
        spec = importlib.util.spec_from_file_location("flathub_groups", FLATHUB)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        cache = os.path.join(self.root, "cache")
        os.makedirs(os.path.join(cache, "flathub"))
        # No failure recorded yet: nothing to back off from.
        self.assertEqual(mod.backoff_window(cache), 0.0)
        windows = []
        for _ in range(5):
            mod.mark_failed(cache)
            windows.append(mod.backoff_window(cache))
        self.assertEqual(windows[0], 60.0)      # base * 2**0
        self.assertEqual(windows[1], 120.0)
        self.assertEqual(windows[2], 240.0)
        self.assertEqual(windows[4], 960.0)
        # Never above the cap, however many consecutive failures.
        for _ in range(20):
            mod.mark_failed(cache)
        self.assertLessEqual(mod.backoff_window(cache), 21600.0)
        # And a success clears it entirely.
        mod._drop(cache, ".failed")
        self.assertEqual(mod.backoff_window(cache), 0.0)

    def test_flathub_catalogue_shape_is_handled_correctly(self):
        # Guards the streaming parser against the catalogue quirks that a naive
        # element lookup silently gets wrong:
        #   * <name>/<summary> repeat per language as xml:lang — the untranslated
        #     one must win, or an app is indexed under its Arabic name;
        #   * <release> lives inside <releases>, <category> inside <categories>,
        #     so direct-child lookups find nothing;
        #   * entities must be decoded, not written through raw.
        xml = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<components version="0.8" origin="flatpak">'
            '<component type="desktop-application">'
            '<id>com.example.Tools</id>'
            '<name>Example Tools</name>'
            '<name xml:lang="ar">أدوات</name>'
            '<summary>A useful tool</summary>'
            '<summary xml:lang="pl">Narzędzie</summary>'
            '<categories><category>Utility</category>'
            '<category>Development</category></categories>'
            '<releases>'
            '<release timestamp="1700000000" version="1.2.3"/>'
            '<release timestamp="1600000000" version="1.2.2"/>'
            '</releases>'
            '</component>'
            '<component type="desktop">'
            '<id>com.example.Legacy</id>'
            '<name>Rock &amp; Roll</name>'
            '<categories><category>Audio</category></categories>'
            '</component>'
            '</components>'
        ).encode("utf-8")
        self.srv.add("/flathub/appstream.xml.gz", gzip.compress(xml))
        cache = os.path.join(self.root, "cache")
        rc, out, err = self.run_flathub({
            "FLATHUB_APPSTREAM_URL": self.srv.url("/flathub/appstream.xml.gz")})
        self.assertEqual(rc, 0, err)

        def tsv(name):
            path = os.path.join(cache, "flathub", name)
            with open(path, encoding="utf-8") as fh:
                return [line.rstrip("\n").split("\t") for line in fh if line.strip()]

        names = {r[0]: r[1] for r in tsv("names.tsv")}
        self.assertEqual(names["com.example.Tools"], "Example Tools")
        self.assertEqual(names["com.example.Legacy"], "Rock & Roll")

        groups = {(r[0], r[1]): r for r in tsv("groups.tsv")}
        self.assertIn(("Utility", "com.example.Tools"), groups)
        self.assertIn(("Development", "com.example.Tools"), groups)
        self.assertIn(("Audio", "com.example.Legacy"), groups)
        row = groups[("Utility", "com.example.Tools")]
        self.assertEqual(row[2], "Example Tools")     # name, not the translation
        self.assertEqual(row[3], "A useful tool")     # summary, untranslated
        self.assertEqual(row[4], "1.2.3")             # newest release
        self.assertEqual(row[5], "1700000000")        # newest release date

        appids = {r[0]: r[1] for r in tsv("appids.tsv")}
        self.assertEqual(appids["com.example.Tools"], "1700000000")

    def test_flathub_truncated_catalogue_fails_without_writing_an_index(self):
        # A partial download must not leave a half-built index behind that
        # later searches would treat as complete.
        self.srv.add("/flathub/appstream.xml.gz", gzip.compress(
            b'<components><component type="desktop-application">'
            b"<id>com.example.Partial</id>"
            b"<categories><category>Utility</category></categories>"
            b"</component></components>"))
        cache = os.path.join(self.root, "cache")
        rc, out, err = self.run_flathub({
            "FLATHUB_APPSTREAM_URL": self.srv.url("/flathub/appstream.xml.gz")})
        self.assertEqual(rc, 0, err)
        # Rebuild over a deliberately corrupt archive and confirm the previous
        # index is neither replaced nor left half-written.
        self.srv.add("/flathub/appstream.xml.gz", gzip.compress(b"<components><comp"))
        os.utime(os.path.join(cache, "flathub", "current"), (0, 0))
        os.utime(os.path.join(cache, "flathub", "groups.tsv"), (0, 0))
        rc2, out2, err2 = self.run_flathub({
            "FLATHUB_APPSTREAM_URL": self.srv.url("/flathub/appstream.xml.gz")})
        self.assertNotEqual(rc2, 0)
        with open(os.path.join(cache, "flathub", "groups.tsv"), encoding="utf-8") as fh:
            self.assertIn("com.example.Partial", fh.read())

    # ------------------------------------------------------- keyboard / caret
    def test_qml_leaves_left_right_to_the_text_caret(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # Arrow keys were hijacked for tab switching, which made the caret
        # unusable inside the search box.
        self.assertNotIn("Keys.onLeftPressed", src)
        self.assertNotIn("Keys.onRightPressed", src)
        # Tab must still cycle tabs while the search field has focus, which
        # means it is handled on the field itself (the key catcher is blocked).
        self.assertIn("Qt.Key_Tab", src)
        self.assertIn("Qt.Key_Backtab", src)


    def test_batch_installs_one_command_per_source_not_one_per_package(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # A batch that launched a terminal per package would either deadlock on
        # pacman's global database lock or open a dozen windows, so the
        # argument list has to be built per SOURCE and run through one Process.
        self.assertIn("function batchCommand", src)
        self.assertIn('["sudo", "pacman", "-S", "--needed"].concat(pkgs)', src)
        self.assertIn('["flatpak", "install", "--assumeyes", "flathub"].concat(pkgs)', src)
        # The chain keys off an explicit in-flight flag: a single-group batch
        # empties its queue on the first pop, so keying off queue length would
        # stop that batch dead and report it finished before it finished.
        self.assertIn("property bool batchActive: false", src)
        self.assertIn("root.batchActive = false", src)

    def test_batch_removal_stays_non_cascading(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # The single-row path refuses -s for good reasons (dependencies are
        # usually wanted by other installed software). A batch that quietly
        # added it would undo that decision at ten times the blast radius.
        start = src.index("function batchCommand")
        end = src.index("// Start a batch", start)
        body = src[start:end]
        self.assertIn('["sudo", "pacman", "-R"].concat(pkgs)', body)
        self.assertIn('["yay", "-R"].concat(pkgs)', body)
        self.assertNotIn('"-Rs"', body)
        self.assertNotIn('"--recursive"', body)
        self.assertNotIn('"-s"', body.split('// Removal stays non-cascading')[1])

    def test_batch_deduplicates_the_same_package_across_sources(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # A package offered by both a repo and the AUR is one install; handing
        # the installer the same id twice is a re-install at best.
        self.assertIn("if (byKey[key].pkgs.indexOf(pkg) < 0)", src)

    def test_batch_modes_are_counted_in_packages_not_groups(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # batchGroups() returns one entry PER SOURCE, so five pacman packages
        # is a length-1 array. Comparing that against a row count silently made
        # "every selected package is installed" unreachable, and Enter reported
        # there was nothing to install while sitting on two installed packages.
        self.assertIn("function batchPkgCount", src)
        self.assertIn('root.batchPkgCount("remove") === root.selectedCount', src)

    def test_focus_is_deferred_until_the_panel_is_actually_shown(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # controller.show() flips `opened`, and a panel that is not yet visible
        # has no focusable window, so an immediate forceActiveFocus() is
        # dropped and every keystroke goes to whatever is behind the panel --
        # which is why the search box sometimes needed two opens.
        self.assertIn("function focusWhenShown", src)
        start = src.index("function focusWhenShown")
        # Slice to the next TOP-LEVEL definition. Cutting at the next bare
        # "function" would stop inside the callLater callback and miss the
        # retry entirely -- which is the assertion's whole point.
        end = src.index("function ensureFreshScan", start)
        body = src[start:end]
        self.assertIn("if (root.opened)", body)
        # Retried, not just deferred once: the transition is not guaranteed to
        # have landed by the first event-loop turn either.
        self.assertIn("Qt.callLater(root.focusWhenShown)", body)
        self.assertNotIn("refreshFocus()\n    root.ensureFreshScan()", src)

    def test_processes_and_timers_are_reached_by_bare_id(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # `root.actionProc` / `root.confirmResetTimer` resolve to UNDEFINED in
        # this scope and throw on assignment, while the identical single-action
        # code writes the bare id and works. The batch path hit this: it had
        # already set batchActive = true, so the bar showed "Working..." over a
        # process that was never launched, and no terminal ever opened.
        # Matched WITH the trailing dot, i.e. as a property access. The bug is
        # always `root.actionProc.command = ...`; the comment explaining the
        # trap mentions the bare `root.actionProc`, and a test that fails on
        # its own documentation is a test nobody keeps.
        for name in ("actionProc", "confirmResetTimer", "installFinishedTimer",
                     "removeFinishedTimer"):
            self.assertNotIn("root." + name + ".", src,
                             "root.%s. does not resolve; use the bare id" % name)
        # ...and the launch is genuinely still there, routed through the
        # user's own terminal rather than a hard-coded kitty.
        self.assertIn("actionProc.command = root.terminalArgv(", src)
        self.assertIn("actionProc.running = true", src)

    def test_terminal_is_the_users_own_not_a_hard_coded_kitty(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # `TERMINAL` is unset in the Omarchy shell's environment, so the old
        # `if (!term) term = "kitty"` fallback meant every user who was not a
        # kitty user got a window that could not start. xdg-terminal-exec
        # reads ~/.config/xdg-terminals.list, which is where
        # `omarchy default terminal <x>` records the user's choice.
        self.assertIn("function terminalArgv", src)
        self.assertIn("xdg-terminal-exec", src)
        self.assertIn("omarchy-default-terminal", src)
        # kitty survives only as the last resort, inside terminalArgv.
        body = src[src.index("function terminalArgv"):]
        body = body[:body.index("\n  }")]
        self.assertEqual(body.count('\"kitty\"'), 1)

    def test_details_sheet_is_f2_only(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # F2 only. SUPER+CTRL+SHIFT+F also toggles this panel as a Hyprland
        # binding, and Hyprland consumes a bound combo before the focused
        # client sees it -- so binding it here too would be dead code that
        # still looked like a working shortcut, and pressing it inside the
        # panel would toggle the panel shut instead of opening anything.
        self.assertIn("event.key === Qt.Key_F2", src)
        self.assertIn("root.openDetailsCursor()", src)
        self.assertNotIn("detailsModifierMask", src)

    def test_hover_preview_is_gone(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # A hover popup was tried and removed: it had nowhere to go in a
        # three-row panel without covering the card it described, and Ctrl+I
        # reaches the same information on demand.
        for gone in ("hoverPreview", "previewFacts", "noteHover",
                     "hoverOpenTimer", "onHoveredChanged"):
            self.assertNotIn(gone, src, "%s should no longer exist" % gone)

    def test_toolbar_is_icon_only_on_a_first_install(self):
        with open(PANEL, encoding="utf-8") as fh:
            panel = fh.read()
        with open(BARWIDGET, encoding="utf-8") as fh:
            bar = fh.read()
        # Icon-only is the FIRST-INSTALL default, and the two cases are kept
        # apart deliberately: a fresh install has nobody's bar to restyle,
        # while an existing user whose file has no stored choice is on whatever
        # they have been looking at and must not be switched under them.
        self.assertIn('property string panelDesign: "icon"', panel)
        self.assertIn('property string toolbarDesign: "icon"', bar)
        # No settings file -> early return, declared default stands.
        self.assertIn('String(raw).trim() === ""', panel)
        self.assertIn('String(raw).trim() === ""', bar)
        # File present but no usable design -> the historical "pill".
        self.assertIn('return root.designs.indexOf(d) !== -1 ? d : "pill"', bar)
        # Neither may write an options file just because it loaded.
        self.assertNotIn("persistOptions()\n        if (raw", panel)

    def test_support_prompt_rearms_once_per_release(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # Re-armed on every update, untickable until the next one. A stored
        # epoch from an older release -- or none at all, which is every
        # existing install -- means an update happened, so the box comes back.
        self.assertIn("storedEpoch !== root.supportPromptEpoch", src)
        self.assertIn("supportEpoch: root.supportPromptEpoch", src)
        # The epoch is written back immediately, or the stored value would
        # still be stale next launch and the untick could never stick.
        arm = src[src.index("if (storedEpoch !== root.supportPromptEpoch)"):]
        arm = arm[:arm.index("} else if")]
        self.assertIn("root.persistOptions()", arm)
        # Still a plain checkbox: no modal, nothing the user cannot dismiss.
        self.assertIn("property bool showCoffeeButton: true", src)

    def test_five_toolbar_styles_are_offered_and_distinct(self):
        with open(PANEL, encoding="utf-8") as fh:
            panel = fh.read()
        with open(BARWIDGET, encoding="utf-8") as fh:
            bar = fh.read()
        expected = '"pill", "icon", "circle", "text", "brand"'
        # Both files validate the stored value against the same list, so a
        # value one of them does not know about is normalised, not rendered
        # half-styled.
        self.assertIn(expected, bar)
        self.assertIn(expected, panel)
        # Only the bare glyph drops the magnifier's grey circle; the label
        # styles keep it, which is what makes them read as the pill's own
        # control rather than loose text.
        self.assertIn('root.toolbarDesign === "icon" || root.toolbarDesign === "circle"',
                      bar)
        # "brand" is the one style that does not follow the user's buttonLabel:
        # saying what the thing is called is the entire point of it.
        self.assertIn('root.toolbarDesign === "brand" ? "FossFetch" : root.buttonLabel', bar)

    def test_circle_style_is_a_real_circle(self):
        with open(BARWIDGET, encoding="utf-8") as fh:
            bar = fh.read()
        # Equal sides. A baked-in width next to the bar's own slot height
        # squashes the circle into an oval at other font scales.
        # Sized from the SHELL's own bar icon slot, which is what every other
        # circular button in the bar is sized from. Deriving it from the icon
        # canvas instead gave a disc a pixel or two off the icons it sits
        # beside, which reads as a different control in the same bar.
        self.assertIn('root.toolbarDesign === "circle" ? root.circleSize', bar)
        self.assertIn("readonly property int circleSize: Style.bar.iconSlot", bar)
        # The bare glyph uses the same box, so switching between the two
        # compact styles does not resize the button.
        self.assertIn("(root.bareIcon ? root.circleSize :", bar)
        # No optical nudge: the shell centres its own buttons, and a manual
        # offset only re-introduces the misalignment it was meant to fix.
        self.assertNotIn("anchors.verticalCenterOffset", bar)
        # It keeps the pill's edge off, so it is not just the pill again...
        self.assertIn('if (root.toolbarDesign === "circle") return 0', bar)
        # ...but its fill and the chip tint are NOT restated as separate
        # branches: they fall through to the pill's own, so the magnifier sits
        # on the same grey by construction rather than by two values kept in
        # step by hand.
        fill = bar[bar.index("function btnFillTop()"):bar.index("function chipFill()")]
        self.assertNotIn('root.toolbarDesign === "circle"', fill)
        self.assertIn('root.toolbarDesign === "icon") return "transparent"', bar)

    def test_switching_tab_retires_an_in_flight_search(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # rebuildResults() repopulates the Updates tab from the scan's own
        # rows, but a search launched a moment earlier was still running, and
        # its handler only compares its own sequence against searchSeq. With
        # the sequence unchanged the late rows passed the check and were
        # appended to the Updates list -- so searching "firefox" left Datcord
        # and Deckr sitting in Updates beside the one real update.
        switch = src[src.index("function switchTab(t) {"):]
        switch = switch[:switch.index("\n  }")]
        self.assertIn("searchSeq++", switch)
        # Belt and braces, so the tab is safe even if a caller forgets.
        for fn in ("onPacmanResults", "onFlatpakResults", "onAurResults"):
            body = src[src.index("function %s(text) {" % fn):]
            body = body[:body.index("\n  }")]
            self.assertIn("if (root.isUpdates) return", body)

    def test_hotkey_installer_is_idempotent_and_never_rewrites(self):
        script = os.path.join(PLUGIN, "install_hotkey.sh")
        import tempfile, shutil
        with open(script, encoding="utf-8") as fh:
            src = fh.read()
        # Appends only. A user's hyprland.lua is theirs; rewriting one to make
        # room for a plugin's line is not a default, it is a data loss.
        self.assertNotIn("> \"$FILE\"\n", src.replace(">>", "\n>>"))
        self.assertIn(">> \"$FILE\"", src)
        # Checks the whole config dir, so a binding the user already wrote by
        # hand is never duplicated.
        self.assertIn('grep -rqs "omarchy-shell fossfetch toggle" "$DIR"', src)

        # Behaviour, against a real temp config dir.
        d = tempfile.mkdtemp()
        try:
            hypr = os.path.join(d, "hypr")
            os.makedirs(hypr)
            cfg = os.path.join(hypr, "hyprland.lua")
            with open(cfg, "w", encoding="utf-8") as fh:
                fh.write('require("hypr.bindings")\n')

            def run():
                import subprocess
                return subprocess.run(["sh", script, hypr, "SUPER + CTRL + SHIFT + F"],
                                      capture_output=True, text=True).stdout.strip()

            self.assertIn("installed", run())
            with open(cfg, encoding="utf-8") as fh:
                first = fh.read()
            # The user's own content survives.
            self.assertIn('require("hypr.bindings")', first)
            # A second run adds nothing.
            self.assertIn("already", run())
            with open(cfg, encoding="utf-8") as fh:
                self.assertEqual(fh.read(), first, "the installer must be idempotent")
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_hotkey_installer_defuses_itself_without_a_config(self):
        script = os.path.join(PLUGIN, "install_hotkey.sh")
        import tempfile, shutil, subprocess
        # No directory, no file, and a DIRECTORY named hyprland.lua: all three
        # must be reported and left alone rather than created or followed.
        for setup in (lambda p: None,
                      lambda p: open(os.path.join(p, "hyprland.lua"), "w").close(),
                      lambda p: os.makedirs(os.path.join(p, "hyprland.lua"))):
            d = tempfile.mkdtemp()
            try:
                hypr = os.path.join(d, "hypr")
                os.makedirs(hypr)
                setup(hypr)
                out = subprocess.run(["sh", script, hypr, "SUPER + CTRL + SHIFT + F"],
                                     capture_output=True, text=True)
                self.assertEqual(out.returncode, 0)
                self.assertIn("STATUS|", out.stdout)
            finally:
                shutil.rmtree(d, ignore_errors=True)

    def test_details_sheet_is_centred_not_anchored_to_the_bar_button(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # Without centerOnBar, PopupCard anchors BELOW its anchorItem -- and
        # that item is the toolbar button, which sits at the far left of the
        # bar. The sheet therefore opened in the top-left corner while the
        # panel it describes was centred: the same information in two places,
        # one of them nowhere near the rows F2 was pressed on.
        sheet = src[src.index("id: detailsSheet"):]
        sheet = sheet[:sheet.index("\n  }")]
        self.assertIn("centerOnBar: true", sheet)
        self.assertIn("anchorItem: panel.anchorItem", sheet)

    def test_shell_restart_is_updates_only(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # Updates only. An update replaces an app in place and the bar and dock
        # keep serving its cached state until the shell re-reads it; a fresh
        # install has no such problem, and a removal takes an entry away.
        self.assertIn('if (root.lastActionVerb === "update") root.scheduleShellRestart()',
                      src)
        self.assertNotIn('root.lastActionVerb === "install"', src)
        # Called from exactly one place: when a command finishes.
        self.assertEqual(src.count("root.scheduleShellRestart()"), 1)
        # Launched under the user manager, so it is not killed by the cgroup it
        # tears down. Covered in depth by
        # test_shell_restart_survives_the_cgroup_it_kills.
        self.assertIn('"systemd-run", "--user"', src)
        # Guarded, so a batch does not restart the shell once per package.
        self.assertIn("if (root.shellRestartPending) return", src)

    def test_shell_restart_survives_the_cgroup_it_kills(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # NOT setsid. The shell runs under a systemd unit, and `quickshell kill`
        # tears down that whole cgroup -- a setsid child is still inside it and
        # dies with the thing it was meant to outlive. The relaunch then never
        # happened and the session was left with no bar, no dock and no shell.
        # Verified by watching it happen, not predicted.
        self.assertIn('"systemd-run", "--user"', src)
        self.assertNotIn('"setsid", "omarchy", "restart", "shell"', src)
        self.assertIn("restart_shell.sh", src)

    def test_restart_script_will_not_strand_the_session(self):
        import tempfile, shutil, subprocess, os as _os
        script = os.path.join(PLUGIN, "restart_shell.sh")
        with open(script, encoding="utf-8") as fh:
            src = fh.read()
        # It polls for the shell to answer and retries if it does not. This runs
        # unattended off a package update; "the relaunch failed" must not mean
        # "the user's desktop is gone".
        self.assertIn("omarchy-shell shell ping", src)
        self.assertIn("while [ \"$attempt\" -le 3 ]", src)

        # Behaviour, with a stub that never answers.
        d = tempfile.mkdtemp()
        try:
            stub = _os.path.join(d, "omarchy-shell")
            with open(stub, "w", encoding="utf-8") as fh:
                fh.write("#!/bin/sh\nexit 1\n")
            _os.chmod(stub, 0o755)
            restart = _os.path.join(d, "omarchy")
            with open(restart, "w", encoding="utf-8") as fh:
                fh.write('#!/bin/sh\necho restart >> "%s/calls"\nexit 0\n' % d)
            _os.chmod(restart, 0o755)
            env = dict(_os.environ, PATH=d + ":" + _os.environ.get("PATH", ""))
            out = subprocess.run(["/bin/sh", script], capture_output=True,
                                 text=True, env=env, timeout=180)
            with open(_os.path.join(d, "calls"), encoding="utf-8") as fh:
                calls = fh.read().count("restart")
            # It must have tried more than once: a single failed relaunch is
            # exactly the case that left the user with no shell.
            self.assertGreaterEqual(calls, 2, "must retry a failed relaunch")
            self.assertIn("STATUS|failed", out.stdout)
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_selection_is_keyed_not_indexed(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # Indexes renumber on every sort, filter and rebuild, so a selection
        # held as indexes silently drifts onto whatever lands there next.
        self.assertIn("root.selectedKeys[root.rowKey(r)]", src)
        # And rows dropped by a rebuild must leave the selection with it.
        self.assertIn("function pruneSelection", src)
        self.assertIn("root.pruneSelection()", src)


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