#!/usr/bin/env python3
"""Security regression tests for the fossfetch plugin.

Covers the review findings:
  * oversize / no-Content-Length responses  (flathub groups, AUR)
  * gzip bombs                                (flathub groups, arch groups)
  * tar path traversal                        (appstream icons)
  * tar symlink / hardlink members            (appstream icons)
  * checksum binding before use               (appstream icons + groups)
  * QML Text.PlainText sinks + URL allowlist  (static scan of Panel.qml)

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
        self.thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self.thread.start()

    class _Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def do_GET(self):
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


def make_pkgbuild(ver, sums):
    lines = ["# fixture PKGBUILD", "pkgver=%s" % ver]
    lines.append("sha256sums=(" + " ".join("'%s'" % s for s in sums) + ")")
    return ("\n".join(lines) + "\n").encode()


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
            "<name>%s</name><summary>S</summary>%s</component>"
            % (cid, name, catxml)
        )
    return ("<?xml version=\"1.0\"?><components>%s</components>" % "".join(comps)).encode()


def make_gzip_bomb(kb=1024):
    return gzip.compress(b"\x00" * (kb * 1024))


class FossFetchTests(unittest.TestCase):
    def setUp(self):
        self.srv = FixtureServer()
        self.root = tempfile.mkdtemp(prefix="fossfetch-test-")

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
        self.assertEqual(p.stdout.strip(), "")

    # ------------------------------------------------------- appstream icons
    def serve_arch(self, pkgbuild, arts, xmls=None):
        xmls = xmls or {}
        self.srv.add("/pkgbuild", pkgbuild)
        for repo, tar in arts.items():
            self.srv.add("/arch/%s/%s/icons-48x48.tar.gz" % (VER, repo), tar)
        for repo, x in xmls.items():
            self.srv.add("/arch/%s/%s/Components-x86_64.xml.gz" % (VER, repo), x)

    def run_icons(self, mode, *extra):
        e = self.env()
        e["ARCH_BASE"] = self.srv.url("/arch")
        e["ARCH_PKGBUILD_URL"] = self.srv.url("/pkgbuild")
        p = subprocess.run(
            ["bash", ICONS, mode, os.path.join(self.root, "cache")] + list(extra),
            capture_output=True, text=True, timeout=90, env=e)
        return p.returncode, p.stdout, p.stderr

    def test_icons_checksum_mismatch_refused(self):
        # Even with a matching-sha fixture the PKGBUILD lists the WRONG sha:
        # extraction must be refused.
        tar = make_evil_icons_tar()
        pkb = make_pkgbuild(VER, [sha256(b"something-else")] * 12)
        self.serve_arch(pkb, {"core": tar})
        rc, out, err = self.run_icons("ensure")
        self.assertNotEqual(rc, 0)
        self.assertFalse(os.path.exists(
            os.path.join(self.root, "cache", "catalog", VER)))

    def test_icons_traversal_symlink_rejected(self):
        tar = make_evil_icons_tar()
        pkb = make_pkgbuild(VER, [sha256(tar)] * 12)
        self.serve_arch(pkb, {"core": tar})
        rc, out, err = self.run_icons("ensure")
        self.assertNotEqual(rc, 0)
        # Nothing extracted into the catalog, and nothing escaped our tmpdir.
        self.assertFalse(os.path.exists(
            os.path.join(self.root, "cache", "catalog", VER)))
        self.assertFalse(os.path.exists(
            os.path.join(self.root, "cache", "catalog", "..", "evil.png")))
        self.assertFalse(os.path.exists(os.path.join(self.root, "..", "evil.png")))

    def test_icons_valid_extracts_and_resolves(self):
        tar = make_valid_icons_tar()
        pkb = make_pkgbuild(VER, [sha256(tar)] * 12)
        self.serve_arch(pkb, {"core": tar, "extra": tar, "multilib": tar})
        rc, out, err = self.run_icons("ensure")
        self.assertEqual(rc, 0, err)
        core = os.path.join(self.root, "cache", "catalog", VER, "core")
        self.assertTrue(os.path.exists(os.path.join(core, "gimp_org.gimp.GIMP.png")))
        rc, out, err = self.run_icons("resolve", "gimp", "firefox")
        self.assertEqual(rc, 0)
        lines = [l for l in out.strip().splitlines() if l]
        self.assertEqual(len(lines), 2)
        for l in lines:
            self.assertTrue(l.startswith("I|"), l)
            self.assertTrue(l.endswith(".png"), l)

    # ------------------------------------------------------- appstream groups
    def run_groups(self, mode, *extra):
        e = self.env()
        e["ARCH_BASE"] = self.srv.url("/arch")
        e["ARCH_PKGBUILD_URL"] = self.srv.url("/pkgbuild")
        p = subprocess.run(
            ["bash", GROUPS, mode, os.path.join(self.root, "cache")] + list(extra),
            capture_output=True, text=True, timeout=90, env=e)
        return p.returncode, p.stdout, p.stderr

    def test_groups_gzip_bomb_rejected(self):
        valid_tar = make_valid_icons_tar()
        bomb = make_gzip_bomb(256)
        normal_xml = gzip.compress(make_xml([("org.a.App", "A", ["Audio"])]))
        sums = [sha256(bomb)] + [sha256(valid_tar)] * 3 \
            + [sha256(normal_xml)] + [sha256(valid_tar)] * 3 \
            + [sha256(normal_xml)] + [sha256(valid_tar)] * 3
        pkb = make_pkgbuild(VER, sums)
        self.serve_arch(pkb, {"core": valid_tar, "extra": valid_tar, "multilib": valid_tar},
                        xmls={"core": bomb, "extra": normal_xml, "multilib": normal_xml})
        e = self.env()
        e["ARCH_BASE"] = self.srv.url("/arch")
        e["ARCH_PKGBUILD_URL"] = self.srv.url("/pkgbuild")
        e["FOSSFETCH_MAX_XML"] = "65536"
        p = subprocess.run(
            ["bash", GROUPS, "ensure", os.path.join(self.root, "cache")],
            capture_output=True, text=True, timeout=90, env=e)
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse(os.path.exists(
            os.path.join(self.root, "cache", "catalog", VER, "groups.tsv")))

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