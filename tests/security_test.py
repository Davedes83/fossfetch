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
import socket
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
                self.send_response(404)
                self.end_headers()
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
        e = os.environ.copy()
        e["HOME"] = self.root
        return e

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
        # An unreachable endpoint (no route added -> 404, and the server keeps
        # the connection open per HTTP/1.1) surfaces as an explicit error frame
        # rather than a silent empty result set.
        e = self.env()
        e["AUR_RPC_URL"] = self.srv.url("/aur-does-not-exist?y=1")
        p = subprocess.run(
            [sys.executable, AUR, "coolapp"],
            capture_output=True, text=True, timeout=60, env=e)
        self.assertEqual(p.returncode, 0)
        self.assertTrue(p.stdout.startswith("STATUS|error|network:"), p.stdout)

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

    # ------------------------------------------------------------ QML static
    def test_qml_hardening(self):
        with open(PANEL, encoding="utf-8") as fh:
            src = fh.read()
        # URL scheme allowlist gates the metadata website link.
        self.assertIn("function isSafeWebUrl", src)
        self.assertNotIn(
            "onClicked: Qt.openUrlExternally(delegateRoot.website)", src)
        self.assertIn("root.isSafeWebUrl(delegateRoot.website)", src)
        # Every metadata / user-input text sink is plain text.
        self.assertGreaterEqual(src.count("textFormat: Text.PlainText"), 10)
        for probe in (
            'id: descText',        # package description
            'root.detailPoints(',  # version/repo/arch/license
            'FitText: Text {',     # component base (name + install labels)
        ):
            self.assertIn(probe, src)


def json_dumps(obj):
    import json
    return json.dumps(obj)


def main():
    import hashlib  # noqa: F401 (kept for parity with sha256 helper)
    # Ensure the scripts exist and are executable.
    for f in (ICONS, GROUPS):
        if not os.access(f, os.X_OK):
            os.chmod(f, 0o755)
    unittest.main(verbosity=2)


if __name__ == "__main__":
    main()