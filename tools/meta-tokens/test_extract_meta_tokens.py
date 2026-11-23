#!/usr/bin/env python3
"""Tests for extract_meta_tokens.py. Synthetic data only: fake apps, fake tokens, throwaway certificates.

Run: python3 tools/meta-tokens/test_extract_meta_tokens.py  (no network; real apksigner/openssl/git are optional)
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import shutil
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import zipfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bloks_table  # noqa: E402
import extract_meta_tokens as tool  # noqa: E402


def fake_token(prefix: str, app_id: str, label: str) -> str:
    return f"{prefix}|{app_id}|{hashlib.sha256(('reglass-test-' + label).encode()).hexdigest()[:32]}"


HW = fake_token("HW", "1000000000000001", "hw")        # length 52, like the real one
AR = fake_token("AR", "200000000000002", "ar")         # length 51
FRL = fake_token("FRL", "300000000000003", "frl")      # length 52
HW_OTHER = fake_token("HW", "1000000000000009", "hw-other")
ALL_FAKES = (HW, AR, FRL, HW_OTHER)
LOOK_ALIKES = (
    "HW|SW",
    "CAR|1234567|0123456789abcdef0123456789abcdef",    # a letter right before the prefix
    "FRL|300000000000003|" + "ab" * 17,                # 34 hex digits: another shape
)
V2, V3 = 0x7109871A, 0xF05368C0
CANNED_CERT = bytes.fromhex("3010") + b"reglass  test!!"  # stands in for a DER certificate: only its SHA-256 counts
FUNCTIONS = [(701, "bk.action.test.FakeFirst"), (4, "local.test.Fake"), (55, "bk.action.test.FakeSecond")]
FUNCTION_TEXT = "4 local.test.Fake\n55 bk.action.test.FakeSecond\n701 bk.action.test.FakeFirst\n"

_real_fetch_assetlinks = tool.fetch_assetlinks
_network_guard = mock.patch.object(tool, "fetch_assetlinks", side_effect=AssertionError("tests must stay offline"))


def setUpModule():
    _network_guard.start()


def tearDownModule():
    _network_guard.stop()


# MARK: Builders


def uleb128(n: int) -> bytes:
    out = bytearray()
    while True:
        byte, n = n & 0x7F, n >> 7
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def fake_dex(*strings: str) -> bytes:
    """Shaped like a dex file: a header, then string data items (ULEB128 length, MUTF-8 bytes, NUL)."""
    items = b"".join(uleb128(len(s)) + s.encode() + b"\0" for s in ("Lcom/example/Fake;", "access_token", *strings))
    dex = bytearray(112) + items + bytes(32)
    finish_dex_header(dex)
    return bytes(dex)


def finish_dex_header(dex: bytearray) -> None:
    dex[:8] = b"dex\n035\0"
    struct.pack_into("<III", dex, 32, len(dex), 112, 0x12345678)


def fake_table_dex(forward=FUNCTIONS, inverse=None) -> bytes:
    """A minimal DEX with two static HashMaps and an arbitrary, obfuscated-style class name."""
    if inverse is None:
        inverse = forward
    types = ["Lexample/Z;", "Lexample/Factory;", "Ljava/lang/Integer;", "Ljava/util/HashMap;",
             "Ljava/util/AbstractMap;", "Ljava/lang/Object;", "I", "V"]
    owner, factory, integer, hashmap, abstract_map, object_, int_, void = range(len(types))
    strings = list(dict.fromkeys(types + ["<clinit>", "valueOf", "put", "make", "a", "b", "L", "LI", "LLL"]
                                 + [name for _, name in (*forward, *inverse)]))
    string_ids = {name: index for index, name in enumerate(strings)}
    dex = bytearray(112 + 4 * len(strings))

    def section(count_at, fmt, rows):
        struct.pack_into("<II", dex, count_at, len(rows), len(dex))
        dex.extend(b"".join(struct.pack(fmt, *row) for row in rows))

    struct.pack_into("<II", dex, 56, len(strings), 112)
    section(64, "<I", [(string_ids[descriptor],) for descriptor in types])
    proto_at = len(dex)
    section(72, "<III", [(string_ids[short], result, 0)
                         for short, result in [("V", void), ("LI", integer), ("LLL", object_), ("LI", hashmap)]])
    section(80, "<HHI", [(owner, hashmap, string_ids["a"]), (owner, hashmap, string_ids["b"])])
    section(88, "<HHI", [(cls, proto, string_ids[name]) for cls, proto, name in
                         [(owner, 0, "<clinit>"), (integer, 1, "valueOf"),
                          (abstract_map, 2, "put"), (factory, 3, "make")]])
    class_at = len(dex)
    section(96, "<8I", [(owner, 1, object_, 0, 0xFFFFFFFF, 0, 0, 0)])
    for index, params in [(1, (int_,)), (2, (object_, object_)), (3, (int_,))]:
        struct.pack_into("<I", dex, proto_at + 12 * index + 8, len(dex))
        dex.extend(struct.pack(f"<I{len(params)}H", len(params), *params))
        dex.extend(bytes(-len(dex) % 4))
    for index, name in enumerate(strings):
        struct.pack_into("<I", dex, 112 + 4 * index, len(dex))
        dex.extend(uleb128(len(name)) + name.encode("ascii") + b"\0")

    code = []
    for field, entries in enumerate((forward, inverse)):
        code.extend([0x0113, len(entries), 0x0177, 3, 1, 0x000C])  # allocate via invoke-static/range, result v0
        for id_, name in entries:
            code.extend([
                0x0113, id_, 0x1071, 1, 1, 0x010C,       # const/16 v1; Integer.valueOf(v1); result v1
                0x021B, string_ids[name], 0,               # const-string/jumbo v2, name
                0x0009, 256, 2, 0x0208, 256,              # move-object/16 and move-object/from16
                0x306E, 2, 0x0120 if field == 0 else 0x0210,  # put(v0, v2, v1) or put(v0, v1, v2)
            ])
        code.extend([0x0069, field])  # sput-object v0, field
    code.append(0x000E)  # return-void
    dex.extend(bytes(-len(dex) % 4))
    code_at = len(dex)
    dex.extend(struct.pack("<HHHHII", 257, 0, 3, 0, 0, len(code)))
    dex.extend(struct.pack(f"<{len(code)}H", *code))
    struct.pack_into("<I", dex, class_at + 24, len(dex))
    dex.extend(b"\x02\x00\x01\x00"            # two static fields, one direct method
               b"\x00\x08\x01\x08"            # static fields 0 and 1, delta-encoded
               b"\x00" + uleb128(0x10008) + uleb128(code_at))  # static constructor method 0
    finish_dex_header(dex)
    return bytes(dex)


def _chunk(kind: int, header_size: int, payload: bytes) -> bytes:
    return struct.pack("<HHI", kind, header_size, 8 + len(payload)) + payload


def _string_pool(strings: list[str], utf8: bool) -> bytes:
    data, offsets = bytearray(), []
    for s in strings:
        offsets.append(len(data))
        if utf8:
            raw = s.encode()
            data += bytes([len(s), len(raw)]) + raw + b"\0"
        else:
            data += struct.pack("<H", len(s)) + s.encode("utf-16-le") + b"\0\0"
    data += bytes(-len(data) % 4)
    header = struct.pack("<IIIII", len(strings), 0, 0x100 if utf8 else 0, 28 + 4 * len(strings), 0)
    return _chunk(0x0001, 28, header + struct.pack(f"<{len(offsets)}I", *offsets) + bytes(data))


def axml_manifest(package: str = "com.facebook.stella", version: str = "1.0.0.0.1",
                  utf8: bool = False, strip_attribute_names: bool = False) -> bytes:
    """A compiled AndroidManifest.xml: <manifest package=... android:versionName=...> with no children."""
    uri = "http://schemas.android.com/apk/res/android"
    strings = ["" if strip_attribute_names else "versionName", "android", uri, "manifest", "package", package, version]
    none = 0xFFFFFFFF
    resource_map = _chunk(0x0180, 8, struct.pack("<I", 0x0101021C))  # string 0 is android:versionName
    namespace = struct.pack("<IIII", 1, none, 1, 2)
    attributes = [(2, 0, 6), (none, 4, 5)]  # (namespace, name, raw value) as string indices
    element = struct.pack("<II", 1, none) + struct.pack("<IIHHHHHH", none, 3, 20, 20, len(attributes), 0, 0, 0)
    element += b"".join(struct.pack("<IIIHBBI", ns, name, raw, 8, 0, 0x03, raw) for ns, name, raw in attributes)
    body = (_string_pool(strings, utf8) + resource_map + _chunk(0x0100, 16, namespace) + _chunk(0x0102, 16, element)
            + _chunk(0x0103, 16, struct.pack("<IIII", 1, none, none, 3)) + _chunk(0x0101, 16, namespace))
    return struct.pack("<HHI", 0x0003, 8, 8 + len(body)) + body


def make_apk(entries: dict, manifest: bytes | None = None, stored: tuple = ()) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("AndroidManifest.xml", axml_manifest() if manifest is None else manifest)
        for name, data in entries.items():
            archive.writestr(name, data, compress_type=zipfile.ZIP_STORED if name in stored else None)
    return buffer.getvalue()


def make_zip(entries: dict) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_STORED) as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
    return buffer.getvalue()


def lp(data: bytes) -> bytes:
    return struct.pack("<I", len(data)) + data


def scheme_block(certificate: bytes, v3: bool = False) -> bytes:
    """A structurally valid v2 or v3 signer block. Digest, signature and key are dummies (they're never checked)."""
    sdk = struct.pack("<II", 24, 0x7FFFFFFF) if v3 else b""
    digests = lp(lp(struct.pack("<I", 0x0103) + lp(bytes(32))))
    signed_data = digests + lp(lp(certificate)) + sdk + lp(b"")
    signatures = lp(lp(struct.pack("<I", 0x0103) + lp(b"not a signature")))
    signer = lp(signed_data) + sdk + signatures + lp(b"not a public key")
    return lp(lp(signer))


def with_signing_block(apk: bytes, *pairs: tuple[int, bytes]) -> bytes:
    """Insert an APK Signing Block before the central directory, as apksigner does, and fix the EOCD offset."""
    eocd = apk.rfind(b"PK\x05\x06")
    central_directory = struct.unpack_from("<I", apk, eocd + 16)[0]
    body = b"".join(struct.pack("<QI", len(value) + 4, block_id) + value for block_id, value in pairs)
    size = len(body) + 24
    block = struct.pack("<Q", size) + body + struct.pack("<Q", size) + tool.APK_SIG_BLOCK_MAGIC
    out = bytearray(apk[:central_directory] + block + apk[central_directory:])
    struct.pack_into("<I", out, eocd + len(block) + 16, central_directory + len(block))
    return bytes(out)


def tlv(tag: int, content: bytes) -> bytes:
    n = len(content)
    length = bytes([n]) if n < 0x80 else bytes([0x80 | ((n.bit_length() + 7) // 8)]) + n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([tag]) + length + content


def pkcs7_with(certificate: bytes) -> bytes:
    """PKCS#7 SignedData carrying one certificate, no signer infos (enough for reading certificates)."""
    data_oid = tlv(0x06, bytes.fromhex("2a864886f70d010701"))
    signed = tlv(0x30, tlv(0x02, b"\x01") + tlv(0x31, b"") + tlv(0x30, data_oid) + tlv(0xA0, certificate) + tlv(0x31, b""))
    return tlv(0x30, tlv(0x06, bytes.fromhex("2a864886f70d010702")) + tlv(0xA0, signed))


def _openssl(*args: str, cwd: Path) -> bool:
    openssl = shutil.which("openssl")
    if not openssl:
        return False
    return subprocess.run([openssl, *args], cwd=cwd, capture_output=True).returncode == 0


def throwaway_certificate(folder: Path) -> tuple[bytes, bool]:
    """(DER, made by openssl). A fresh self-signed test certificate, or the canned blob if openssl isn't there."""
    ok = (_openssl("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", "key.pem", cwd=folder)
          and _openssl("req", "-new", "-x509", "-key", "key.pem", "-out", "cert.pem", "-days", "2",
                       "-subj", "/CN=ReGlass test only", cwd=folder)
          and _openssl("x509", "-in", "cert.pem", "-outform", "DER", "-out", "cert.der", cwd=folder))
    return ((folder / "cert.der").read_bytes(), True) if ok else (CANNED_CERT, False)


def colon_fingerprint(certificate: bytes) -> str:
    return ":".join(f"{b:02X}" for b in hashlib.sha256(certificate).digest())


def write_assetlinks(path: Path, *certificates: bytes, package: str = "com.facebook.stella") -> Path:
    relation = ["delegate_permission/common.handle_all_urls"]
    statements = [
        {"relation": relation, "target": {"namespace": "android_app", "package_name": package,
                                          "sha256_cert_fingerprints": [colon_fingerprint(c) for c in certificates]}},
        {"relation": relation, "target": {"namespace": "android_app", "package_name": "com.example.other",
                                          "sha256_cert_fingerprints": [colon_fingerprint(b"some other app")]}},
        {"relation": relation, "target": {"namespace": "web", "site": "https://example.com"}},
    ]
    path.write_text(json.dumps(statements))
    return path


# MARK: Base


class ToolTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._certificates = tempfile.TemporaryDirectory()
        cls.cert, cls.cert_from_openssl = throwaway_certificate(Path(cls._certificates.name))
        cls.cert_folder = Path(cls._certificates.name)

    @classmethod
    def tearDownClass(cls):
        cls._certificates.cleanup()

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.links = write_assetlinks(self.tmp / "assetlinks.json", self.cert)
        self.out = self.tmp / "out" / "Secrets.xcconfig"
        self.out.parent.mkdir()
        self.table = self.out.with_name(tool.TABLE_NAME)
        min_functions = mock.patch.object(bloks_table, "MIN_FUNCTIONS", len(FUNCTIONS))
        min_functions.start()
        self.addCleanup(min_functions.stop)

    def tearDown(self):
        self._tmp.cleanup()

    def signed_apk(self, entries: dict, manifest: bytes | None = None, certificate: bytes | None = None) -> bytes:
        certificate = certificate or self.cert
        return with_signing_block(make_apk(entries, manifest),
                                  (V3, scheme_block(certificate, v3=True)), (V2, scheme_block(certificate)))

    def base_entries(self) -> dict:
        return {"classes.dex": fake_dex("one", AR, *LOOK_ALIKES), "classes2.dex": fake_dex(FRL),
                "classes7.dex": fake_dex(HW, AR), "classes8.dex": fake_table_dex(), "res/raw/notes.txt": b"nothing here"}

    def write(self, name: str, data: bytes) -> Path:
        path = self.tmp / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def run_tool(self, *argv: str, builtin: bool = True) -> tuple[int, str, str]:
        args = list(argv)
        if builtin:
            args += ["--no-apksigner", "--assetlinks", str(self.links)]
        if "--out" not in args:
            args += ["--out", str(self.out)]
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = tool.main(args)
        self.assertNoTokenValues(stdout.getvalue() + stderr.getvalue())
        return code, stdout.getvalue(), stderr.getvalue()

    def assertNoTokenValues(self, text: str):
        for value in ALL_FAKES:
            self.assertNotIn(value, text)
            self.assertNotIn(value.rsplit("|", 1)[1], text)

    def assertWrote(self, path: Path | None = None):
        path = path or self.out
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        lines = path.read_text().splitlines()
        self.assertEqual([line for line in lines if not line.startswith("//")],
                         ["", f"REGLASS_META_HW_TOKEN = {HW}", f"REGLASS_META_AR_TOKEN = {AR}",
                          f"REGLASS_META_FRL_TOKEN = {FRL}"])
        self.assertTrue(lines[0].startswith("// ReGlass"))
        self.assertTrue(any("PRIVATE" in line and "git-ignored" in line for line in lines))


# MARK: Token shapes


class TokenShapeTests(unittest.TestCase):
    def strict(self, data: bytes) -> set:
        return {value for _, value, strict in tool.find_candidates(data) if strict}

    def test_finds_tokens_in_dex_string_data(self):
        dex = fake_dex(HW, AR, FRL)
        self.assertEqual(dex[dex.index(HW.encode()) - 1:dex.index(HW.encode())], b"4")  # ULEB128 52 is ASCII "4"
        self.assertEqual(self.strict(dex), {HW, AR, FRL})

    def test_rejects_look_alikes(self):
        secret = "0123456789abcdef" * 2
        cases = {
            f"CAR|1234567|{secret}": None, f"XHW|1234567|{secret}": None, f"_AR|1234567|{secret}": None,
            f"HW|12345|{secret}": None,                       # app ID too short
            f"HW|1234567|{secret}a": False,                   # 33 hex digits
            f"HW|1234567|{secret}|x": False,                  # followed by "|"
            f"HW|1234567|{secret}-x": False,                  # something glued on
            f"HW|1234567|{'g' * 32}": False,                  # not hex
            f"HW|1234567|{secret}": True, f"HW|1234567|{secret.upper()}": True,
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                found = [strict for _, _, strict in tool.find_candidates(b"\0" + text.encode() + b"\0")]
                self.assertEqual(found, [] if expected is None else [expected])

    def test_mask_never_shows_the_value(self):
        masked = tool.mask(HW)
        self.assertEqual(masked, f"HW|10...{HW[-2:]} (length 52)")
        self.assertNotIn(HW.rsplit("|", 1)[1], masked)

    def test_values_are_xcconfig_safe(self):
        for value in (HW, AR, FRL):
            self.assertTrue(tool.TOKEN_SHAPE.fullmatch(value))
            self.assertNotIn("//", value)
            self.assertNotIn("$", value)


# MARK: Manifest


class ManifestTests(unittest.TestCase):
    def test_reads_package_and_version(self):
        for utf8 in (False, True):
            with self.subTest(utf8=utf8):
                attributes = tool.manifest_attributes(axml_manifest(utf8=utf8))
                self.assertEqual(attributes["package"], "com.facebook.stella")
                self.assertEqual(attributes["versionName"], "1.0.0.0.1")

    def test_version_name_through_resource_id(self):
        attributes = tool.manifest_attributes(axml_manifest(strip_attribute_names=True))
        self.assertEqual(attributes["versionName"], "1.0.0.0.1")

    def test_unreadable_manifest(self):
        apk = tool.Apk("x.apk", make_apk({}, manifest=b"<manifest/>"))
        self.assertIsNone(tool.manifest_info(apk))


# MARK: Signatures without apksigner


class SigningBlockTests(ToolTestCase):
    def test_v2_block(self):
        apk = tool.Apk("base.apk", with_signing_block(make_apk({"classes.dex": fake_dex()}), (V2, scheme_block(self.cert))))
        scheme, certificates = tool.builtin_signer_certificates(apk)
        self.assertEqual(scheme, "APK Signature Scheme v2")
        self.assertEqual([hashlib.sha256(c).hexdigest() for c in certificates], [hashlib.sha256(self.cert).hexdigest()])
        self.assertEqual(apk.zip.read("classes.dex"), fake_dex())  # zip readers still see the entries

    def test_v3_and_v2_blocks(self):
        other = CANNED_CERT + b"rotated"
        apk = tool.Apk("base.apk", with_signing_block(make_apk({}), (V3, scheme_block(other, v3=True)),
                                                      (V2, scheme_block(self.cert))))
        scheme, certificates = tool.builtin_signer_certificates(apk)
        self.assertEqual(scheme, "APK Signature Scheme v3, v2")
        self.assertEqual(certificates, [other, self.cert])

    def test_v1_signature_fallback(self):
        apk = tool.Apk("old.apk", make_apk({"META-INF/CERT.RSA": pkcs7_with(self.cert), "META-INF/CERT.SF": b"x"}))
        self.assertEqual(tool.builtin_signer_certificates(apk), ("v1 JAR signature", [self.cert]))

    def test_v1_signature_made_by_openssl(self):
        if not self.cert_from_openssl:
            self.skipTest("openssl not available")
        self.assertTrue(_openssl("crl2pkcs7", "-nocrl", "-certfile", "cert.pem", "-outform", "DER", "-out", "p7.der",
                                 cwd=self.cert_folder))
        self.assertEqual(tool.pkcs7_certificates((self.cert_folder / "p7.der").read_bytes()), [self.cert])

    def test_unsigned_and_damaged(self):
        with self.assertRaises(tool.Failure) as unsigned:
            tool.builtin_signer_certificates(tool.Apk("u.apk", make_apk({})))
        self.assertEqual(unsigned.exception.code, tool.EXIT_SIGNATURE)
        damaged = bytearray(with_signing_block(make_apk({}), (V2, scheme_block(self.cert))))
        at = damaged.index(tool.APK_SIG_BLOCK_MAGIC) - 8
        struct.pack_into("<Q", damaged, at, 1 << 40)
        with self.assertRaises(tool.Failure):
            tool.builtin_signer_certificates(tool.Apk("d.apk", bytes(damaged)))


class AssetlinksTests(unittest.TestCase):
    def test_only_meta_ai_fingerprints(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_assetlinks(Path(tmp) / "a.json", b"first", b"second")
            found = tool.published_fingerprints(str(path))
        self.assertEqual(found, {hashlib.sha256(b"first").hexdigest(), hashlib.sha256(b"second").hexdigest()})

    def test_refuses_lists_without_meta_ai(self):
        for text in ("not json", "{}", json.dumps([{"target": {"namespace": "android_app", "package_name": "x",
                                                                    "sha256_cert_fingerprints": ["AA"]}}])):
            with self.subTest(text=text), self.assertRaises(tool.Failure):
                tool.parse_assetlinks(text)


class FetchTests(unittest.TestCase):
    """The fetch itself, with the network replaced: no request leaves the machine."""

    def test_retries_with_the_macos_bundle_after_a_certificate_error(self):
        contexts = []

        def fake_get(request, context=None):
            self.assertEqual(request.full_url, "https://www.meta.ai/.well-known/assetlinks.json")
            contexts.append(context)
            if context is None:
                raise urllib.error.URLError(ssl.SSLCertVerificationError("unable to get local issuer certificate"))
            return b"[]"

        with mock.patch.object(tool, "_get", fake_get), \
                mock.patch.object(tool.os.path, "isfile", return_value=True), \
                mock.patch.object(tool.ssl, "create_default_context", return_value="macOS bundle") as create:
            self.assertEqual(_real_fetch_assetlinks(), "[]")
        create.assert_called_once_with(cafile="/etc/ssl/cert.pem")
        self.assertEqual(contexts, [None, "macOS bundle"])

    def test_offline_fails_clearly(self):
        with mock.patch.object(tool, "_get", side_effect=urllib.error.URLError("offline")), \
                self.assertRaises(tool.Failure) as failure:
            _real_fetch_assetlinks()
        self.assertEqual(failure.exception.code, tool.EXIT_SIGNATURE)
        self.assertIn("--assetlinks", str(failure.exception))

    def test_redirects_are_refused(self):
        self.assertIsNone(tool._NoRedirects().redirect_request(None, None, 302, "Found", {}, "https://example.com/"))


# MARK: End to end (built-in certificate reader)


class EndToEndTests(ToolTestCase):
    def test_single_apk(self):
        apk = self.write("meta-ai.apk", self.signed_apk(self.base_entries()))
        code, stdout, stderr = self.run_tool(str(apk))
        self.assertEqual(code, 0, stderr)
        self.assertIn("Signature check: built-in certificate reader", stdout)
        self.assertIn("Signature check: built-in certificate reader (--no-apksigner).", stdout)
        self.assertIn("meta-ai.apk: com.facebook.stella 1.0.0.0.1, signer certificate is one Meta publishes"
                      " (APK Signature Scheme v3, v2).", stdout)
        self.assertIn("signature itself was NOT verified", stdout)
        for line in ("found HW token (length 52)", "found AR token (length 51)", "found FRL token (length 52)"):
            self.assertIn(line, stdout)
        self.assertIn(f"Wrote {self.out} (mode 0600).", stdout)
        self.assertEqual(self.table.read_text(), FUNCTION_TEXT)
        self.assertEqual(stat.S_IMODE(self.table.stat().st_mode), 0o600)
        self.assertWrote()
        self.assertIn("from Meta AI 1.0.0.0.1 (com.facebook.stella)", self.out.read_text())

    def test_split_bundles(self):
        base = self.signed_apk(self.base_entries())
        split = make_apk({"lib/arm64-v8a/libfake.so": b"\0native\0"})  # no dex, no signature: not checked, not scanned
        layouts = {
            "meta-ai.xapk": {"com.facebook.stella.apk": base, "config.arm64_v8a.apk": split, "manifest.json": b"{}"},
            "meta-ai.apkm": {"base.apk": base, "split_config.arm64_v8a.apk": split, "info.json": b"{}"},
            "meta-ai.apks": {"toc.pb": b"", "splits/base-master.apk": base, "splits/base-arm64_v8a.apk": split},
        }
        for name, entries in layouts.items():
            with self.subTest(bundle=name):
                if self.out.exists():
                    self.out.unlink()
                    self.table.unlink()
                code, stdout, stderr = self.run_tool(str(self.write(name, make_zip(entries))))
                self.assertEqual(code, 0, stderr)
                self.assertWrote()

    def test_folder_of_split_apks(self):
        folder = self.tmp / "pulled"
        folder.mkdir()
        (folder / "base.apk").write_bytes(self.signed_apk(self.base_entries()))
        (folder / "split_config.arm64_v8a.apk").write_bytes(make_apk({"lib/arm64-v8a/libx.so": b"x"}))
        (folder / "notes.txt").write_text("ignored")
        code, _, stderr = self.run_tool(str(folder))
        self.assertEqual(code, 0, stderr)
        self.assertWrote()

    def test_out_folder(self):
        apk = self.write("a.apk", self.signed_apk(self.base_entries()))
        code, _, stderr = self.run_tool(str(apk), "--out", str(self.out.parent))
        self.assertEqual(code, 0, stderr)
        self.assertWrote(self.out.parent / "Secrets.xcconfig")

    def test_none_found(self):
        apk = self.write("a.apk", self.signed_apk({"classes.dex": fake_dex(AR, *LOOK_ALIKES)}))
        code, stdout, stderr = self.run_tool(str(apk))
        self.assertEqual(code, tool.EXIT_TOKENS)
        self.assertIn("HW: none found.", stderr)
        self.assertIn("FRL: none found. 1 string(s) start like a FRL token but have another shape (a.apk:classes.dex)",
                      stderr)
        self.assertNotIn("found AR token", stdout)
        self.assertFalse(self.out.exists())

    def test_ambiguous_with_masked_candidates(self):
        entries = self.base_entries()
        entries["classes3.dex"] = fake_dex(HW_OTHER)
        apk = self.write("a.apk", self.signed_apk(entries))
        code, stdout, stderr = self.run_tool(str(apk), "--show-candidates")
        self.assertEqual(code, tool.EXIT_TOKENS)
        self.assertIn("HW: 2 different values (value 1 in a.apk:classes7.dex; value 2 in a.apk:classes3.dex)", stderr)
        self.assertIn(f"  {tool.mask(HW)}  in a.apk:classes7.dex", stdout)
        self.assertIn(f"  {tool.mask(HW_OTHER)}  in a.apk:classes3.dex", stdout)
        self.assertIn(f"  {tool.mask(AR)}  in a.apk:classes.dex, a.apk:classes7.dex", stdout)
        self.assertIn("other shape, not used", stdout)
        self.assertFalse(self.out.exists())

    def test_no_overwrite_without_force(self):
        apk = self.write("a.apk", self.signed_apk(self.base_entries()))
        self.out.write_text("placeholder\n")
        os.chmod(self.out, 0o644)
        code, _, stderr = self.run_tool(str(apk))
        self.assertEqual(code, tool.EXIT_OUTPUT)
        self.assertIn("already exists", stderr)
        self.assertEqual(self.out.read_text(), "placeholder\n")
        code, _, stderr = self.run_tool(str(apk), "--force")
        self.assertEqual(code, 0, stderr)
        self.assertWrote()
        self.assertEqual(sorted(p.name for p in self.out.parent.iterdir()), ["Secrets.xcconfig", tool.TABLE_NAME])

    def test_written_with_0600_despite_umask(self):
        apk = self.write("a.apk", self.signed_apk(self.base_entries()))
        previous = os.umask(0o277)  # would leave 0400 without the explicit chmod
        try:
            code, _, stderr = self.run_tool(str(apk))
        finally:
            os.umask(previous)
        self.assertEqual(code, 0, stderr)
        self.assertWrote()

    def test_wrong_certificate_is_refused(self):
        apk = self.write("a.apk", self.signed_apk(self.base_entries(), certificate=CANNED_CERT + b"stranger"))
        code, _, stderr = self.run_tool(str(apk))
        self.assertEqual(code, tool.EXIT_SIGNATURE)
        self.assertIn("is not signed with a certificate Meta publishes", stderr)
        self.assertIn(hashlib.sha256(CANNED_CERT + b"stranger").hexdigest(), stderr)
        self.assertFalse(self.out.exists())

    def test_wrong_package_is_refused(self):
        apk = self.write("a.apk", self.signed_apk(self.base_entries(), manifest=axml_manifest("com.facebook.katana")))
        code, _, stderr = self.run_tool(str(apk))
        self.assertEqual(code, tool.EXIT_SIGNATURE)
        self.assertIn("is the app com.facebook.katana, not Meta AI", stderr)

    def test_skip_signature_check_is_loud(self):
        apk = self.write("a.apk", make_apk(self.base_entries()))  # unsigned
        code, stdout, stderr = self.run_tool(str(apk), "--skip-signature-check", builtin=False)
        self.assertEqual(code, 0, stderr)
        self.assertIn("WARNING: --skip-signature-check. The app check did NOT run.", stderr)
        self.assertNotIn("Signature check:", stdout)
        self.assertWrote()

    def test_only_a_split_without_code(self):
        apk = self.write("config.apk", make_apk({"lib/arm64-v8a/libx.so": HW.encode()}))
        code, _, stderr = self.run_tool(str(apk))
        self.assertEqual(code, tool.EXIT_INPUT)
        self.assertIn("No app code (classes.dex)", stderr)

    def test_not_an_app(self):
        code, _, stderr = self.run_tool(str(self.write("x.apk", b"plain text")))
        self.assertEqual(code, tool.EXIT_INPUT)
        self.assertIn("isn't a zip file", stderr)

    def test_secondary_dex_in_assets(self):
        entries = {"classes.dex": fake_dex(AR, FRL),
                   "assets/secondary-program-dex-jars/secondary-1.dex.jar":
                       make_zip({"classes.dex": fake_dex(HW), "classes2.dex": fake_table_dex()})}
        code, _, stderr = self.run_tool(str(self.write("a.apk", self.signed_apk(entries))))
        self.assertEqual(code, 0, stderr)
        self.assertWrote()
        self.assertEqual(self.table.read_text(), FUNCTION_TEXT)

    def test_native_library_only_with_scan_all(self):
        entries = {"classes.dex": fake_dex(AR, FRL), "classes2.dex": fake_table_dex(),
                   "lib/arm64-v8a/libfake.so": b"\x7fELF\0" + HW.encode() + b"\0"}
        apk = str(self.write("a.apk", self.signed_apk(entries)))
        code, _, stderr = self.run_tool(apk)
        self.assertEqual(code, tool.EXIT_TOKENS)
        self.assertIn("HW: none found.", stderr)
        code, _, stderr = self.run_tool(apk, "--scan-all")
        self.assertEqual(code, 0, stderr)
        self.assertWrote()


class FunctionTableTests(ToolTestCase):
    def test_table_only_never_reads_or_writes_tokens(self):
        apk = self.write("a.apk", self.signed_apk(self.base_entries()))
        self.out.write_text("existing config\n")
        with mock.patch.object(tool, "find_candidates", side_effect=AssertionError("must skip token extraction")):
            code, stdout, stderr = self.run_tool(str(apk), "--sign-in-table-only", "--out", str(self.out.parent))
        self.assertEqual(code, 0, stderr)
        self.assertIn("Found 3 sign-in functions.", stdout)
        self.assertEqual(self.out.read_text(), "existing config\n")
        self.assertEqual(self.table.read_text(), FUNCTION_TEXT)

    def test_default_paths_write_table_in_package_resources(self):
        apk = self.write("a.apk", self.signed_apk(self.base_entries()))
        with mock.patch.object(tool, "default_out", return_value=self.out):
            args = tool.parse_args([str(apk), "--no-apksigner", "--assetlinks", str(self.links)])
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(tool.run(args), 0)
        self.assertNoTokenValues(stdout.getvalue() + stderr.getvalue())
        self.assertWrote()
        self.assertEqual((self.out.parent / tool.TABLE_RESOURCE).read_text(), FUNCTION_TEXT)

    def test_invalid_table_prevents_both_outputs(self):
        cases = [
            ("Couldn't find the sign-in function table", fake_dex()),
            ("has only 2 entries", fake_table_dex(FUNCTIONS[:2])),
            ("duplicate IDs", fake_table_dex(FUNCTIONS + [(4, "bk.action.test.AnotherFake")])),
            ("duplicate names", fake_table_dex(FUNCTIONS + [(900, FUNCTIONS[0][1])])),
            ("maps .* disagree", fake_table_dex(FUNCTIONS, FUNCTIONS[:-1])),
            ("invalid ID or name", fake_table_dex(FUNCTIONS + [(0, "bk.action.test.BadID")])),
            ("Couldn't read DEX code", fake_table_dex()[:112]),
        ]
        for message, dex in cases:
            with self.subTest(message=message):
                entries = self.base_entries()
                entries["classes8.dex"] = dex
                apk = self.write("a.apk", self.signed_apk(entries))
                code, _, stderr = self.run_tool(str(apk))
                self.assertEqual(code, tool.EXIT_TABLE)
                self.assertRegex(stderr, message)
                self.assertFalse(self.out.exists())
                self.assertFalse(self.table.exists())

    def test_multiple_tables_are_ambiguous(self):
        entries = self.base_entries()
        entries["classes9.dex"] = fake_table_dex()
        apk = self.write("a.apk", self.signed_apk(entries))
        code, _, stderr = self.run_tool(str(apk))
        self.assertEqual(code, tool.EXIT_TABLE)
        self.assertIn("Found more than one sign-in function table", stderr)
        self.assertFalse(self.table.exists())

    def test_existing_table_blocks_writing_a_new_config(self):
        apk = self.write("a.apk", self.signed_apk(self.base_entries()))
        self.table.write_text("old table\n")
        code, _, stderr = self.run_tool(str(apk))
        self.assertEqual(code, tool.EXIT_OUTPUT)
        self.assertIn(f"{self.table} already exists", stderr)
        self.assertFalse(self.out.exists())
        self.assertEqual(self.table.read_text(), "old table\n")


class XcconfigTests(unittest.TestCase):
    def test_format(self):
        text = tool.xcconfig_text({"HW": HW, "AR": AR, "FRL": FRL}, "1.0.0.0.1")
        self.assertTrue(text.endswith(f"REGLASS_META_FRL_TOKEN = {FRL}\n"))
        for line in text.splitlines():
            if line and not line.startswith("//"):
                self.assertRegex(line, r"^REGLASS_META_(HW|AR|FRL)_TOKEN = (HW|AR|FRL)\|[0-9]+\|[0-9a-f]{32}$")

    def test_refuses_unsafe_values(self):
        for bad in ("HW|1234567|0123456789abcdef//23456789abcdef", "HW|1234567|$(OTHER)", HW + "\nEXTRA = 1", AR):
            with self.subTest(bad=bad), self.assertRaises(tool.Failure):
                tool.xcconfig_text({"HW": bad, "AR": AR, "FRL": FRL}, None)

    def test_odd_version_stays_out_of_the_file(self):
        text = tool.xcconfig_text({"HW": HW, "AR": AR, "FRL": FRL}, "1.0\nEVIL = 1")
        self.assertNotIn("EVIL", text)
        self.assertIn("from com.facebook.stella.", text)

    def test_default_out_is_the_repo_root(self):
        root = Path(tool.__file__).resolve().parents[2]
        self.assertEqual(tool.default_out(), root / "Secrets.xcconfig")  # computed only; nothing is read or written


# MARK: Signatures with apksigner


class ApksignerTests(ToolTestCase):
    def fake_apksigner(self, output: str, code: int = 0) -> Path:
        script = self.tmp / "bin" / "apksigner"
        script.parent.mkdir(exist_ok=True)
        (self.tmp / "bin" / "output.txt").write_text(output)
        script.write_text(f"#!/bin/sh\ncat '{self.tmp / 'bin' / 'output.txt'}'\nexit {code}\n")
        script.chmod(0o755)
        return script

    def signer_output(self, digest: str, stamp: str = "00" * 32) -> str:
        return ("Verifies\nVerified using v2 scheme (APK Signature Scheme v2): true\nNumber of signers: 1\n"
                f"Signer #1 certificate DN: CN=Test\nSigner #1 certificate SHA-256 digest: {digest}\n"
                f"Signer #1 public key SHA-256 digest: {'11' * 32}\n"
                f"Source Stamp Signer certificate SHA-256 digest: {stamp}\n")

    def run_with(self, apksigner: Path, *argv: str):
        apk = self.write("a.apk", make_apk(self.base_entries()))  # the fake apksigner decides; no block needed
        return self.run_tool(str(apk), "--apksigner", str(apksigner), "--assetlinks", str(self.links), *argv,
                             builtin=False)

    def test_matching_signer(self):
        code, stdout, stderr = self.run_with(self.fake_apksigner(self.signer_output(hashlib.sha256(self.cert).hexdigest())))
        self.assertEqual(code, 0, stderr)
        self.assertIn("Signature check: apksigner (full cryptographic verification)", stdout)
        self.assertIn("signed with Meta's published certificate (verified by apksigner).", stdout)
        self.assertNotIn("NOT verified", stdout)
        self.assertWrote()

    def test_source_stamp_does_not_count(self):
        output = self.signer_output("22" * 32, stamp=hashlib.sha256(self.cert).hexdigest())
        code, _, stderr = self.run_with(self.fake_apksigner(output))
        self.assertEqual(code, tool.EXIT_SIGNATURE)
        self.assertIn("22" * 32, stderr)

    def test_failed_verification(self):
        code, _, stderr = self.run_with(self.fake_apksigner("DOES NOT VERIFY\nERROR: APK Signature Scheme v2 signer #1:"
                                                            " APK integrity check failed.\n", code=1))
        self.assertEqual(code, tool.EXIT_SIGNATURE)
        self.assertIn("signature is NOT valid", stderr)
        self.assertNotIn("--no-apksigner", stderr)
        self.assertFalse(self.out.exists())

    def test_apksigner_that_cannot_run(self):
        code, _, stderr = self.run_with(self.fake_apksigner("Unable to locate a Java Runtime.\n", code=1))
        self.assertEqual(code, tool.EXIT_SIGNATURE)
        self.assertIn("--no-apksigner", stderr)

    def test_discovery(self):
        for version in ("30.0.3", "34.0.0", "9.0.0"):
            tool_path = self.tmp / "sdk" / "build-tools" / version / "apksigner"
            tool_path.parent.mkdir(parents=True)
            tool_path.write_text("#!/bin/sh\n")
            tool_path.chmod(0o755)
        environment = {"PATH": str(self.tmp / "empty"), "HOME": str(self.tmp / "home"),
                       "ANDROID_HOME": str(self.tmp / "sdk")}
        with mock.patch.dict(os.environ, environment, clear=False):
            os.environ.pop("ANDROID_SDK_ROOT", None)
            self.assertEqual(tool.find_apksigner(None, False), str(self.tmp / "sdk/build-tools/34.0.0/apksigner"))
            self.assertIsNone(tool.find_apksigner(None, True))
        with self.assertRaises(tool.Failure):
            tool.find_apksigner(str(self.tmp / "missing"), False)


class RealApksignerTests(ToolTestCase):
    """Signs a synthetic APK with a throwaway key using the real apksigner, then checks both signature paths agree."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.apksigner = tool.find_apksigner(None, False)
        if not cls.apksigner or not cls.cert_from_openssl:
            raise unittest.SkipTest("needs apksigner (Android SDK build-tools) and openssl")
        if subprocess.run([cls.apksigner, "version"], capture_output=True).returncode != 0:
            raise unittest.SkipTest("apksigner can't run here (Java missing?)")
        if not _openssl("pkcs8", "-topk8", "-nocrypt", "-in", "key.pem", "-outform", "DER", "-out", "key.pk8",
                        cwd=cls.cert_folder):
            raise unittest.SkipTest("openssl can't convert the throwaway key")

    def sign(self, entries: dict, stored: tuple = ()) -> Path:
        unsigned = self.write("unsigned.apk", make_apk(entries, stored=stored))
        signed = self.tmp / "signed.apk"
        run = subprocess.run([self.apksigner, "sign", "--key", str(self.cert_folder / "key.pk8"),
                              "--cert", str(self.cert_folder / "cert.pem"), "--v4-signing-enabled", "false",
                              "--in", str(unsigned), "--out", str(signed)], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        return signed

    def test_apksigner_and_builtin_reader_agree(self):
        entries = self.base_entries()
        entries["assets/note.txt"] = b"untouched note"
        signed = self.sign(entries, stored=("assets/note.txt",))
        apk = tool.Apk("signed.apk", signed.read_bytes(), signed)
        digest = hashlib.sha256(self.cert).hexdigest()
        self.assertEqual(set(tool.apksigner_digests(self.apksigner, apk)), {digest})
        scheme, certificates = tool.builtin_signer_certificates(apk)
        self.assertIn("v2", scheme)
        self.assertEqual({hashlib.sha256(c).hexdigest() for c in certificates}, {digest})
        v1 = [n for n in apk.zip.namelist() if tool._V1_SIGNATURE.fullmatch(n)]
        self.assertEqual(tool.pkcs7_certificates(apk.zip.read(v1[0])), [self.cert])

        code, stdout, stderr = self.run_tool(str(signed), "--apksigner", self.apksigner,
                                             "--assetlinks", str(self.links), builtin=False)
        self.assertEqual(code, 0, stderr)
        self.assertIn("full cryptographic verification", stdout)
        self.assertWrote()

        # Change one stored byte. apksigner catches it; the built-in reader can't (which is why it warns).
        tampered = self.write("tampered.apk", signed.read_bytes().replace(b"untouched note", b"tampered  note"))
        self.out.unlink()
        self.table.unlink()
        code, _, stderr = self.run_tool(str(tampered), "--apksigner", self.apksigner,
                                        "--assetlinks", str(self.links), builtin=False)
        self.assertEqual(code, tool.EXIT_SIGNATURE)
        self.assertIn("signature is NOT valid", stderr)
        code, stdout, stderr = self.run_tool(str(tampered))
        self.assertEqual(code, 0, stderr)
        self.assertIn("signature itself was NOT verified", stdout)


class GitIgnoreTests(ToolTestCase):
    def test_warns_when_not_ignored(self):
        if not shutil.which("git"):
            self.skipTest("git not available")
        subprocess.run(["git", "init", "-q", str(self.out.parent)], check=True, capture_output=True)
        apk = str(self.write("a.apk", self.signed_apk(self.base_entries())))
        code, _, stderr = self.run_tool(apk)
        self.assertEqual(code, 0, stderr)
        self.assertIn("git does not ignore", stderr)
        (self.out.parent / ".gitignore").write_text(f"Secrets.xcconfig\n{tool.TABLE_NAME}\n")
        code, _, stderr = self.run_tool(apk, "--force")
        self.assertEqual(code, 0, stderr)
        self.assertNotIn("git does not ignore", stderr)


if __name__ == "__main__":
    unittest.main()
