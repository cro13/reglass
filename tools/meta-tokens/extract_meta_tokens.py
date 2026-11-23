#!/usr/bin/env python3
"""Extract Meta AI's static client tokens and sign-in function table for ReGlass.

You supply the Meta AI Android app (package com.facebook.stella): one .apk, a split bundle (.apks, .xapk, .apkm)
or a folder of split APKs. The script checks that Meta signed it, then writes the tokens to the git-ignored
Secrets.xcconfig and the function table to the ReGlassKit resources.

It never prints a token value, never downloads an app and never uploads anything. Its only network request reads
Meta's public certificate list, https://www.meta.ai/.well-known/assetlinks.json (use --assetlinks FILE to skip it).

Python 3.9+, standard library only. See docs/META-CREDENTIALS.md.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import lzma
import os
import re
import shutil
import ssl
import struct
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
import zlib
from pathlib import Path

from bloks_table import TABLE_NAME, SignInTables, TableError, table_text

PACKAGE = "com.facebook.stella"
ASSETLINKS_URL = "https://www.meta.ai/.well-known/assetlinks.json"
VARIABLES = (
    ("HW", "REGLASS_META_HW_TOKEN"),
    ("AR", "REGLASS_META_AR_TOKEN"),
    ("FRL", "REGLASS_META_FRL_TOKEN"),
)
PREFIXES = tuple(prefix for prefix, _ in VARIABLES)

EXIT_TOKENS = 1     # none, or more than one, value for a prefix
EXIT_INPUT = 2      # unreadable or unsuitable input (argparse errors use 2 as well)
EXIT_SIGNATURE = 3  # not shown to come from Meta
EXIT_OUTPUT = 4     # output file exists or can't be written
EXIT_TABLE = 5      # sign-in function table missing or invalid

TABLE_RESOURCE = Path("ReGlassKit/Sources/ReGlassKit/Resources/Generated") / TABLE_NAME

MAX_ENTRY_BYTES = 1 << 30
MAX_ASSETLINKS_BYTES = 1 << 20


class Failure(Exception):
    """A clear, user-facing refusal. The message never contains a token value."""

    def __init__(self, message: str, code: int):
        super().__init__(message)
        self.code = code


def warn(message: str) -> None:
    sys.stdout.flush()  # keep the order when both streams go to one place
    print(f"warning: {message}", file=sys.stderr)


# MARK: Token shapes
#
# App tokens use the form "<universe>|<numeric app ID>|<client token>". The three token types have a
# 15- or 16-digit app ID and a 32-character hex client token (total lengths 51-52). The app ID range is loose (6-20
# digits); the client token is strict (exactly 32 hex digits, nothing alphanumeric, "_", "-" or "|" glued on).
# Strings with a prefix and an app ID but another tail count as "other shapes": reported, never used.

_CANDIDATE = re.compile(rb"(HW|AR|FRL)\|([0-9]{6,20})\|([0-9A-Za-z_-]{1,128})")
_STRICT_SECRET = re.compile(rb"[0-9a-fA-F]{32}")
# The byte before a token may not be a letter, "_" or "|", so "CAR|..." or "XHW|..." don't count. Digits are allowed:
# in a dex string table the byte before a string is its length (ULEB128), and 51 and 52 are the ASCII digits 3 and 4.
_NOT_BEFORE = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_|")
TOKEN_SHAPE = re.compile(r"(HW|AR|FRL)\|[0-9]{6,20}\|[0-9a-fA-F]{32}")


def find_candidates(data: bytes):
    """Yield (prefix, value, strict) for each token-like string in data."""
    for match in _CANDIDATE.finditer(data):
        start, end = match.span()
        if start and data[start - 1] in _NOT_BEFORE:
            continue
        strict = _STRICT_SECRET.fullmatch(match.group(3)) is not None and (end == len(data) or data[end] != 0x7C)
        yield match.group(1).decode("ascii"), match.group(0).decode("ascii"), strict


def mask(value: str) -> str:
    """Prefix, first and last two characters after it, and the length. Never the full value."""
    prefix, _, rest = value.partition("|")
    return f"{prefix}|{rest[:2]}...{rest[-2:]} (length {len(value)})"


def _file_list(files: list[str], limit: int = 6) -> str:
    shown = ", ".join(files[:limit])
    return shown + (f" and {len(files) - limit} more" if len(files) > limit else "")


class Findings:
    """Distinct values per prefix, and the files each came from."""

    def __init__(self) -> None:
        self.strict: dict[str, dict[str, list[str]]] = {prefix: {} for prefix in PREFIXES}
        self.other: dict[str, dict[str, list[str]]] = {prefix: {} for prefix in PREFIXES}

    def add(self, where: str, data: bytes) -> None:
        for prefix, value, strict in find_candidates(data):
            files = (self.strict if strict else self.other)[prefix].setdefault(value, [])
            if where not in files:
                files.append(where)

    def masked_report(self) -> list[str]:
        lines = []
        for prefix in PREFIXES:
            for value, files in self.strict[prefix].items():
                lines.append(f"  {mask(value)}  in {_file_list(files)}")
            for value, files in self.other[prefix].items():
                lines.append(f"  {mask(value)}  other shape, not used; in {_file_list(files)}")
        return lines or ["  (none)"]

    def choose(self) -> dict[str, str]:
        chosen, problems = {}, []
        for prefix in PREFIXES:
            values = self.strict[prefix]
            if len(values) == 1:
                chosen[prefix] = next(iter(values))
                continue
            if values:
                parts = [f"value {n} in {_file_list(files)}" for n, files in enumerate(values.values(), 1)]
                problems.append(f"{prefix}: {len(values)} different values ({'; '.join(parts)}).")
            else:
                text = f"{prefix}: none found."
                others = self.other[prefix]
                if others:
                    files = sorted({f for fs in others.values() for f in fs})
                    text += (f" {len(others)} string(s) start like a {prefix} token but have another shape"
                             f" ({_file_list(files)}).")
                problems.append(text)
        if problems:
            raise Failure(
                "Couldn't find exactly one value for each token:\n  " + "\n  ".join(problems)
                + "\nRun again with --show-candidates to see masked forms. If nothing was found, pass the base APK"
                " or the whole bundle, try --scan-all, or try another Meta AI version."
                " Never post the full values anywhere.",
                EXIT_TOKENS,
            )
        return chosen


# MARK: Input


class Apk:
    """One APK held in memory. `path` is set when it is a file of its own on disk (apksigner can read it there)."""

    def __init__(self, name: str, data: bytes, path: Path | None = None):
        self.name = name
        self.data = data
        self.path = path
        try:
            self.zip = zipfile.ZipFile(io.BytesIO(data))
        except zipfile.BadZipFile:
            raise Failure(f"{name} is not a valid APK (it isn't a zip file).", EXIT_INPUT) from None


def _read_entry(archive: zipfile.ZipFile, info: zipfile.ZipInfo, where: str) -> bytes:
    if info.file_size > MAX_ENTRY_BYTES:
        raise Failure(f"{where}:{info.filename} is larger than {MAX_ENTRY_BYTES >> 20} MB. Not reading it.", EXIT_INPUT)
    try:
        return archive.read(info)
    except (RuntimeError, NotImplementedError, zipfile.BadZipFile, zlib.error, EOFError, OSError) as error:
        raise Failure(f"Couldn't read {where}:{info.filename} ({error}).", EXIT_INPUT) from None


def _load_file(path: Path) -> list[Apk]:
    try:
        outer = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError):
        raise Failure(f"{path.name} is not an APK or an APK bundle (it isn't a zip file).", EXIT_INPUT) from None
    with outer:
        if "AndroidManifest.xml" in outer.namelist():
            return [Apk(path.name, path.read_bytes(), path)]
        members = [info for info in outer.infolist() if not info.is_dir() and info.filename.lower().endswith(".apk")]
        if not members:
            raise Failure(f"{path.name} is neither an APK nor a bundle of APKs.", EXIT_INPUT)
        return [Apk(f"{path.name}:{info.filename}", _read_entry(outer, info, path.name)) for info in members]


def load_apks(inputs: list[str]) -> list[Apk]:
    apks: list[Apk] = []
    for raw in inputs:
        path = Path(raw).expanduser()
        if path.is_dir():
            files = sorted(p for p in path.iterdir() if p.is_file() and p.suffix.lower() == ".apk")
            if not files:
                raise Failure(f"No .apk files in the folder {path}.", EXIT_INPUT)
            for file in files:
                apks.extend(_load_file(file))
        elif path.is_file():
            apks.extend(_load_file(path))
        else:
            raise Failure(f"Not found: {path}", EXIT_INPUT)
    return apks


# MARK: What gets scanned
#
# Scan the DEX string tables in classes*.dex for Java string constants. Apps can also ship secondary DEX under
# assets/ as plain .dex files, DEX jars or XZ-compressed .xzs files. Those are scanned by default too.
# Use --scan-all to include native libraries, resources and other assets. Scanning more files can find unrelated
# strings that make token selection ambiguous.

_NESTED = (".jar", ".zip", ".apk")
_XZ = (".xz", ".xzs")


def _default_target(name: str) -> bool:
    lower = name.lower()
    return lower.endswith(".dex") or (lower.startswith("assets/") and lower.endswith(_NESTED + _XZ))


def has_targets(apk: Apk, scan_all: bool) -> bool:
    return any(not info.is_dir() and (scan_all or _default_target(info.filename)) for info in apk.zip.infolist())


def _unxz(data: bytes, where: str) -> bytes | None:
    decompressor = lzma.LZMADecompressor()
    try:
        out = decompressor.decompress(data, max_length=MAX_ENTRY_BYTES)
    except lzma.LZMAError:
        warn(f"couldn't decompress {where}; skipped it.")
        return None
    if not decompressor.eof and not decompressor.needs_input:
        warn(f"{where} decompresses to more than {MAX_ENTRY_BYTES >> 20} MB; skipped it.")
        return None
    return out


def scan_entries(apk: Apk, scan_all: bool):
    """Yield (where, bytes) for each file to scan in one APK."""
    for info in apk.zip.infolist():
        if info.is_dir() or not (scan_all or _default_target(info.filename)):
            continue
        where = f"{apk.name}:{info.filename}"
        data = _read_entry(apk.zip, info, apk.name)
        lower = info.filename.lower()
        if lower.endswith(_XZ):
            data = _unxz(data, where)
            if data is not None:
                yield where, data
        elif lower.endswith(_NESTED):
            try:
                nested = zipfile.ZipFile(io.BytesIO(data))
            except zipfile.BadZipFile:
                if scan_all:
                    yield where, data
                continue
            with nested:
                for inner in nested.infolist():
                    if not inner.is_dir() and (scan_all or inner.filename.lower().endswith(".dex")):
                        yield f"{where}:{inner.filename}", _read_entry(nested, inner, where)
        else:
            yield where, data


# MARK: Binary AndroidManifest.xml (package name and version only)

_ANDROID_ATTRIBUTE_IDS = {0x0101021B: "versionCode", 0x0101021C: "versionName"}


def _pool_length(buffer: bytes, pos: int, wide: bool) -> tuple[int, int]:
    if wide:
        (n,) = struct.unpack_from("<H", buffer, pos)
        pos += 2
        if n & 0x8000:
            n = ((n & 0x7FFF) << 16) | struct.unpack_from("<H", buffer, pos)[0]
            pos += 2
        return n, pos
    n = buffer[pos]
    pos += 1
    if n & 0x80:
        n = ((n & 0x7F) << 8) | buffer[pos]
        pos += 1
    return n, pos


def _string_pool(buffer: bytes, chunk: int) -> list[str]:
    header_size = struct.unpack_from("<H", buffer, chunk + 2)[0]
    count, _styles, flags, strings_start = struct.unpack_from("<IIII", buffer, chunk + 8)
    if count > 1_000_000:
        raise ValueError("implausible string pool")
    offsets = struct.unpack_from(f"<{count}I", buffer, chunk + header_size)
    base = chunk + strings_start
    strings = []
    for offset in offsets:
        pos = base + offset
        if flags & 0x100:  # UTF-8: UTF-16 length, then byte length, then bytes
            _, pos = _pool_length(buffer, pos, wide=False)
            n, pos = _pool_length(buffer, pos, wide=False)
            strings.append(buffer[pos:pos + n].decode("utf-8", "replace"))
        else:
            n, pos = _pool_length(buffer, pos, wide=True)
            strings.append(buffer[pos:pos + 2 * n].decode("utf-16-le", "replace"))
    return strings


def manifest_attributes(axml: bytes) -> dict:
    """The attributes of the <manifest> element of a compiled AndroidManifest.xml."""
    if len(axml) < 8 or struct.unpack_from("<H", axml, 0)[0] != 0x0003:
        raise ValueError("not a compiled XML file")
    pos = struct.unpack_from("<H", axml, 2)[0]
    end = min(len(axml), struct.unpack_from("<I", axml, 4)[0])
    strings: list[str] = []
    resource_ids: list[int] = []

    def text(index: int) -> str | None:
        return strings[index] if 0 <= index < len(strings) else None

    while pos + 8 <= end:
        kind, header_size, size = struct.unpack_from("<HHI", axml, pos)
        if size < 8 or pos + size > end:
            raise ValueError("bad chunk")
        if kind == 0x0001:
            strings = _string_pool(axml, pos)
        elif kind == 0x0180:
            resource_ids = list(struct.unpack_from(f"<{(size - header_size) // 4}I", axml, pos + header_size))
        elif kind == 0x0102:
            ext = pos + header_size
            _ns, name, attribute_start, attribute_size, count = struct.unpack_from("<IIHHH", axml, ext)
            if text(name) != "manifest":
                raise ValueError("first element is not <manifest>")
            attributes = {}
            for i in range(count):
                at = ext + attribute_start + i * attribute_size
                _ans, key_index, raw, _size, _res0, data_type, data = struct.unpack_from("<IIIHBBI", axml, at)
                key = text(key_index)
                if not key and key_index < len(resource_ids):
                    key = _ANDROID_ATTRIBUTE_IDS.get(resource_ids[key_index])
                if not key:
                    continue
                if raw != 0xFFFFFFFF:
                    attributes[key] = text(raw)
                elif data_type == 0x03:
                    attributes[key] = text(data)
                else:
                    attributes[key] = data
            return attributes
        pos += size
    raise ValueError("no <manifest> element")


def manifest_info(apk: Apk) -> tuple[str | None, str | None] | None:
    """(package, versionName) from the APK's manifest, or None if it can't be read."""
    try:
        attributes = manifest_attributes(apk.zip.read("AndroidManifest.xml"))
    except (KeyError, ValueError, struct.error, IndexError, zipfile.BadZipFile, RuntimeError):
        return None
    package, version = attributes.get("package"), attributes.get("versionName")
    return (package if isinstance(package, str) else None, version if isinstance(version, str) else None)


# MARK: Meta's published certificates


def _normalise_fingerprint(value) -> str | None:
    if not isinstance(value, str):
        return None
    digest = value.replace(":", "").strip().lower()
    return digest if re.fullmatch(r"[0-9a-f]{64}", digest) else None


def parse_assetlinks(text: str) -> set[str]:
    """SHA-256 certificate fingerprints (lower-case hex, no colons) that Meta publishes for com.facebook.stella."""
    try:
        statements = json.loads(text)
    except ValueError:
        raise Failure("Meta's certificate list isn't valid JSON.", EXIT_SIGNATURE) from None
    if not isinstance(statements, list):
        raise Failure("Meta's certificate list has an unexpected format.", EXIT_SIGNATURE)
    found = set()
    for statement in statements:
        target = statement.get("target") if isinstance(statement, dict) else None
        if isinstance(target, dict) and target.get("namespace") == "android_app" \
                and target.get("package_name") == PACKAGE:
            for value in target.get("sha256_cert_fingerprints") or []:
                digest = _normalise_fingerprint(value)
                if digest:
                    found.add(digest)
    if not found:
        raise Failure(f"Meta's certificate list has no certificate for {PACKAGE}.", EXIT_SIGNATURE)
    return found


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # urllib then raises HTTPError: the list is read from www.meta.ai or not at all


# python.org's macOS builds have no CA certificates until "Install Certificates.command" runs. macOS's own bundle is
# then used instead: TLS is still fully verified, against Apple's list.
_MACOS_CA_BUNDLE = "/etc/ssl/cert.pem"


def _get(request: urllib.request.Request, context: ssl.SSLContext | None = None) -> bytes:
    handlers = [_NoRedirects()] + ([urllib.request.HTTPSHandler(context=context)] if context else [])
    with urllib.request.build_opener(*handlers).open(request, timeout=30) as reply:
        return reply.read(MAX_ASSETLINKS_BYTES + 1)


def fetch_assetlinks() -> str:
    """The only network request this script makes: a read of Meta's public certificate list."""
    request = urllib.request.Request(
        ASSETLINKS_URL, headers={"Accept": "application/json", "User-Agent": "reglass-meta-tokens"})
    try:
        try:
            body = _get(request)
        except urllib.error.URLError as error:
            if not (isinstance(error.reason, ssl.SSLCertVerificationError) and os.path.isfile(_MACOS_CA_BUNDLE)):
                raise
            body = _get(request, ssl.create_default_context(cafile=_MACOS_CA_BUNDLE))
    except (urllib.error.URLError, OSError, ValueError) as error:
        reason = getattr(error, "reason", None) or error
        raise Failure(
            f"Couldn't read Meta's certificate list from {ASSETLINKS_URL} ({reason}).\n"
            f"Check the connection, or download that file yourself (for example with curl -fsSO {ASSETLINKS_URL})"
            " and pass --assetlinks assetlinks.json.",
            EXIT_SIGNATURE,
        ) from None
    if len(body) > MAX_ASSETLINKS_BYTES:
        raise Failure("Meta's certificate list is unexpectedly large.", EXIT_SIGNATURE)
    return body.decode("utf-8", "replace")


def published_fingerprints(assetlinks: str | None) -> set[str]:
    if assetlinks:
        try:
            text = Path(assetlinks).expanduser().read_text("utf-8")
        except (OSError, UnicodeDecodeError) as error:
            raise Failure(f"Couldn't read {assetlinks} ({error}).", EXIT_INPUT) from None
        return parse_assetlinks(text)
    return parse_assetlinks(fetch_assetlinks())


# MARK: Signature check with apksigner (full cryptographic verification)


def _version_key(name: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", name))


def find_apksigner(explicit: str | None, disabled: bool) -> str | None:
    """--apksigner, else apksigner on PATH, else the newest Android SDK build-tools copy."""
    if disabled:
        return None
    if explicit:
        path = Path(explicit).expanduser()
        if not (path.is_file() and os.access(path, os.X_OK)):
            raise Failure(f"--apksigner {explicit}: not an executable file.", EXIT_INPUT)
        return str(path)
    on_path = shutil.which("apksigner")
    if on_path:
        return on_path
    roots = [os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"), "~/Library/Android/sdk", "~/Android/Sdk"]
    for root in roots:
        if not root:
            continue
        build_tools = Path(root).expanduser() / "build-tools"
        if not build_tools.is_dir():
            continue
        found = [d / "apksigner" for d in build_tools.iterdir() if os.access(d / "apksigner", os.X_OK)]
        if found:
            return str(max(found, key=lambda tool: _version_key(tool.parent.name)))
    return None


_APKSIGNER_DIGEST = re.compile(r"^(?P<who>.*?)certificate SHA-256 digest:\s*(?P<hex>[0-9a-fA-F]{64})\s*$", re.M)


def apksigner_digests(apksigner: str, apk: Apk) -> list[str]:
    """Run `apksigner verify --print-certs`; return the signers' certificate SHA-256 digests (not the source stamp's)."""
    with tempfile.TemporaryDirectory(prefix="reglass-apk-") as scratch:
        target = apk.path
        if target is None:
            target = Path(scratch) / "app.apk"
            target.write_bytes(apk.data)
        try:
            run = subprocess.run([apksigner, "verify", "--print-certs", str(target)],
                                 capture_output=True, text=True, timeout=900)
        except (OSError, subprocess.SubprocessError) as error:
            raise Failure(f"apksigner couldn't run ({error}). Fix it, or pass --no-apksigner for the weaker"
                          " built-in check.", EXIT_SIGNATURE) from None
    output = f"{run.stdout}\n{run.stderr}"
    if run.returncode != 0:
        detail = next((line.strip() for line in output.splitlines() if line.startswith("ERROR")), "")
        if "DOES NOT VERIFY" in output:
            raise Failure(f"{apk.name}: apksigner says its signature is NOT valid. The file was changed or damaged."
                          f" Don't use it.{(' ' + detail) if detail else ''}", EXIT_SIGNATURE)
        first = detail or next((line.strip() for line in output.splitlines() if line.strip()), "no output")
        raise Failure(f"apksigner failed on {apk.name} (exit {run.returncode}: {first}). Fix it, or pass"
                      " --no-apksigner for the weaker built-in check.", EXIT_SIGNATURE)
    digests = [m.group("hex").lower() for m in _APKSIGNER_DIGEST.finditer(run.stdout)
               if not m.group("who").strip().lower().startswith("source stamp")]
    if not digests:
        raise Failure(f"apksigner verified {apk.name} but printed no signer certificate.", EXIT_SIGNATURE)
    return digests


# MARK: Signature check without apksigner (reads the signer certificate; doesn't verify the signature)

APK_SIG_BLOCK_MAGIC = b"APK Sig Block 42"
SCHEME_BLOCKS = ((0x1B93AD61, "v3.1"), (0xF05368C0, "v3"), (0x7109871A, "v2"))
_OID_SIGNED_DATA = bytes.fromhex("2a864886f70d010702")  # 1.2.840.113549.1.7.2


class ApkFormatError(ValueError):
    pass


def _eocd_offset(data: bytes) -> int:
    floor = max(0, len(data) - 22 - 0xFFFF)
    at = data.rfind(b"PK\x05\x06", floor)
    while at >= 0:
        if at + 22 <= len(data) and at + 22 + struct.unpack_from("<H", data, at + 20)[0] == len(data):
            return at
        at = data.rfind(b"PK\x05\x06", floor, at)
    raise ApkFormatError("no end of central directory")


def apk_signing_block(data: bytes) -> dict[int, list[bytes]]:
    """ID -> values of the APK Signing Block, which sits just before the central directory. Empty if there is none."""
    eocd = _eocd_offset(data)
    central_directory = struct.unpack_from("<I", data, eocd + 16)[0]
    if central_directory == 0xFFFFFFFF or central_directory > eocd or central_directory < 32:
        return {}
    size, magic = struct.unpack_from("<Q16s", data, central_directory - 24)
    if magic != APK_SIG_BLOCK_MAGIC:
        return {}
    start = central_directory - size - 8
    if size < 24 or start < 0 or struct.unpack_from("<Q", data, start)[0] != size:
        raise ApkFormatError("damaged APK Signing Block")
    pairs: dict[int, list[bytes]] = {}
    pos, end = start + 8, central_directory - 24
    while pos < end:
        if pos + 12 > end:
            raise ApkFormatError("damaged APK Signing Block entry")
        length, block_id = struct.unpack_from("<QI", data, pos)
        if length < 4 or pos + 8 + length > end:
            raise ApkFormatError("damaged APK Signing Block entry")
        pairs.setdefault(block_id, []).append(data[pos + 12:pos + 8 + length])
        pos += 8 + length
    return pairs


def _length_prefixed(buffer: bytes, pos: int) -> tuple[bytes, int]:
    if pos + 4 > len(buffer):
        raise ApkFormatError("truncated signature data")
    (n,) = struct.unpack_from("<I", buffer, pos)
    pos += 4
    if pos + n > len(buffer):
        raise ApkFormatError("truncated signature data")
    return buffer[pos:pos + n], pos + n


def _length_prefixed_items(buffer: bytes):
    pos = 0
    while pos < len(buffer):
        item, pos = _length_prefixed(buffer, pos)
        yield item


def scheme_signer_certificates(value: bytes) -> list[bytes]:
    """The signer certificate (DER) of each signer in a v2, v3 or v3.1 block.

    Block: length-prefixed sequence of signers. Signer: length-prefixed signed data first. Signed data starts with
    length-prefixed digests, then a length-prefixed sequence of length-prefixed certificates; the first is the signer's.
    """
    signers, _ = _length_prefixed(value, 0)
    certificates = []
    for signer in _length_prefixed_items(signers):
        signed_data, _ = _length_prefixed(signer, 0)
        _digests, pos = _length_prefixed(signed_data, 0)
        chain, _ = _length_prefixed(signed_data, pos)
        first = next(_length_prefixed_items(chain), None)
        if first:
            certificates.append(first)
    return certificates


def _der(buffer: bytes, pos: int) -> tuple[int, int, int]:
    """(tag, content start, end) of the DER element at pos."""
    if pos + 2 > len(buffer):
        raise ApkFormatError("truncated DER")
    tag, first = buffer[pos], buffer[pos + 1]
    pos += 2
    if tag & 0x1F == 0x1F or first == 0x80:
        raise ApkFormatError("unsupported DER")
    if first & 0x80:
        count = first & 0x7F
        if count > 4 or pos + count > len(buffer):
            raise ApkFormatError("bad DER length")
        length = int.from_bytes(buffer[pos:pos + count], "big")
        pos += count
    else:
        length = first
    if pos + length > len(buffer):
        raise ApkFormatError("truncated DER")
    return tag, pos, pos + length


def pkcs7_certificates(der: bytes) -> list[bytes]:
    """The certificates (DER) in a v1 signature file: PKCS#7 ContentInfo { signedData, [0] SignedData }."""
    tag, start, end = _der(der, 0)
    if tag != 0x30:
        raise ApkFormatError("not PKCS#7")
    tag, oid_start, oid_end = _der(der, start)
    if tag != 0x06 or der[oid_start:oid_end] != _OID_SIGNED_DATA:
        raise ApkFormatError("not PKCS#7 signed data")
    tag, explicit, explicit_end = _der(der, oid_end)
    if tag != 0xA0:
        raise ApkFormatError("not PKCS#7 signed data")
    tag, pos, signed_end = _der(der, explicit)
    if tag != 0x30:
        raise ApkFormatError("not PKCS#7 signed data")
    certificates = []
    while pos < signed_end:
        tag, content, element_end = _der(der, pos)
        if tag == 0xA0:  # [0] IMPLICIT SET OF Certificate
            inner = content
            while inner < element_end:
                cert_tag, _, cert_end = _der(der, inner)
                if cert_tag == 0x30:
                    certificates.append(der[inner:cert_end])
                inner = cert_end
        pos = element_end
    return certificates


_V1_SIGNATURE = re.compile(r"META-INF/[^/]+\.(RSA|EC|DSA)", re.I)


def builtin_signer_certificates(apk: Apk) -> tuple[str, list[bytes]]:
    """(scheme names, signer certificates). v2/v3/v3.1 blocks first; the v1 JAR signature only if there are none."""
    try:
        pairs = apk_signing_block(apk.data)
        schemes, certificates = [], []
        for block_id, label in SCHEME_BLOCKS:
            for value in pairs.get(block_id, []):
                found = scheme_signer_certificates(value)
                if found:
                    certificates.extend(found)
                    if label not in schemes:
                        schemes.append(label)
        if certificates:
            return "APK Signature Scheme " + ", ".join(schemes), certificates
        for name in apk.zip.namelist():
            if _V1_SIGNATURE.fullmatch(name):
                certificates.extend(pkcs7_certificates(apk.zip.read(name)))
    except (ApkFormatError, struct.error, KeyError, zipfile.BadZipFile, RuntimeError) as error:
        raise Failure(f"Couldn't read the signature of {apk.name} ({error}).", EXIT_SIGNATURE) from None
    if certificates:
        return "v1 JAR signature", certificates
    raise Failure(f"{apk.name} has no signature. A real Meta AI APK is always signed.", EXIT_SIGNATURE)


# MARK: The app check


def check_app(apks: list[Apk], args) -> None:
    """Refuse unless every APK to be scanned is com.facebook.stella, signed with a certificate Meta publishes for it."""
    if args.skip_signature_check:
        sys.stdout.flush()
        print("!" * 78, file=sys.stderr)
        print("!!! WARNING: --skip-signature-check. The app check did NOT run.", file=sys.stderr)
        print("!!! Nothing shows that this file comes from Meta. The values may be wrong or planted.", file=sys.stderr)
        print("!" * 78, file=sys.stderr)
        return
    published = published_fingerprints(args.assetlinks)
    apksigner = find_apksigner(args.apksigner, args.no_apksigner)
    if apksigner:
        print(f"Signature check: apksigner (full cryptographic verification), {apksigner}")
    else:
        why = "--no-apksigner" if args.no_apksigner else "apksigner not found"
        print(f"Signature check: built-in certificate reader ({why}).")
    for apk in apks:
        info = manifest_info(apk)
        if info is None or info[0] is None:
            warn(f"couldn't read the package name in {apk.name}; relying on the certificate alone.")
        elif info[0] != PACKAGE:
            raise Failure(f"{apk.name} is the app {info[0]}, not Meta AI ({PACKAGE}).", EXIT_SIGNATURE)
        if apksigner:
            how, digests = "signed with Meta's published certificate (verified by apksigner)", \
                apksigner_digests(apksigner, apk)
        else:
            scheme, certificates = builtin_signer_certificates(apk)
            how = f"signer certificate is one Meta publishes ({scheme})"
            digests = [hashlib.sha256(certificate).hexdigest() for certificate in certificates]
        if not any(digest in published for digest in digests):
            raise Failure(
                f"{apk.name} is not signed with a certificate Meta publishes for {PACKAGE}. Don't use this file;"
                f" get the app from another source.\n  Its signer certificate SHA-256: {', '.join(sorted(set(digests)))}",
                EXIT_SIGNATURE,
            )
        version = f" {info[1]}" if info and info[1] else ""
        print(f"  {apk.name}: {PACKAGE}{version}, {how}.")
    if not apksigner:
        print("  WARNING: only the signer certificate was compared. The signature itself was NOT verified")
        print("  cryptographically, so a changed file that kept Meta's certificate would pass. For the full check,")
        print("  install Android SDK build-tools (apksigner) or pass --apksigner PATH.")


# MARK: Output


def xcconfig_text(tokens: dict[str, str], version: str | None) -> str:
    for prefix, variable in VARIABLES:
        value = tokens[prefix]
        # Values go into the file unquoted. The token shape allows only letters, digits and "|", so no "//" (which
        # starts an xcconfig comment), no "$(" (a build-setting reference) and no line break. Refuse anything else.
        if not TOKEN_SHAPE.fullmatch(value) or not value.startswith(prefix + "|"):
            raise Failure(f"The {prefix} value has characters an xcconfig file can't hold as is. Not writing it.",
                          EXIT_TOKENS)
    source = f"Meta AI {version} ({PACKAGE})" if version and re.fullmatch(r"[0-9A-Za-z._-]{1,64}", version) else PACKAGE
    lines = [
        "// ReGlass: Meta AI's static client tokens (HW|, AR|, FRL|), used by setup to sign in and hand over ownership.",
        "// PRIVATE. This file is git-ignored. Never commit or share it, and never paste these values anywhere.",
        f"// Written by tools/meta-tokens/extract_meta_tokens.py from {source}. See docs/META-CREDENTIALS.md.",
        "",
    ]
    lines += [f"{variable} = {tokens[prefix]}" for prefix, variable in VARIABLES]
    return "\n".join(lines) + "\n"


def default_out() -> Path:
    root = Path(__file__).resolve().parents[2]
    if not ((root / "project.yml").is_file() or (root / "Secrets.xcconfig.example").is_file()):
        raise Failure("Couldn't find the ReGlass folder two levels above this script. Pass --out PATH.", EXIT_OUTPUT)
    return root / "Secrets.xcconfig"


def resolve_out(raw: str, filename: str) -> Path:
    path = Path(raw).expanduser()
    return path / filename if path.is_dir() else path


def write_private(path: Path, text: str, force: bool) -> None:
    """Write with mode 0600. Without force, never touch an existing file; with force, replace it atomically."""
    if not path.parent.is_dir():
        raise Failure(f"The folder {path.parent} doesn't exist.", EXIT_OUTPUT)
    data = text.encode("utf-8")
    try:
        if not force:
            try:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
            except FileExistsError:
                raise Failure(f"{path} already exists. Not touching it; pass --force to replace it.",
                              EXIT_OUTPUT) from None
            try:
                with os.fdopen(fd, "wb") as handle:
                    os.fchmod(handle.fileno(), 0o600)
                    handle.write(data)
            except BaseException:
                path.unlink()
                raise
            return
        if path.is_dir():
            raise Failure(f"{path} is a folder.", EXIT_OUTPUT)
        fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
        try:
            with os.fdopen(fd, "wb") as handle:
                os.fchmod(handle.fileno(), 0o600)
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
        except BaseException:
            if os.path.lexists(temporary):
                os.unlink(temporary)
            raise
    except OSError as error:
        raise Failure(f"Couldn't write {path} ({error.strerror or error}).", EXIT_OUTPUT) from None


def git_ignores(path: Path) -> bool | None:
    """True or False if path is inside a git work tree, None if it isn't or git isn't available."""
    git = shutil.which("git")
    if not git:
        return None
    try:
        run = subprocess.run([git, "-C", str(path.parent), "check-ignore", "-q", "--", path.name],
                             capture_output=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    return {0: True, 1: False}.get(run.returncode)


# MARK: Command line


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="extract_meta_tokens.py",
        description="Find Meta AI's static client tokens and sign-in function table and write them to"
                    " ReGlass's local build files. Checks first that Meta signed the app. Never prints a"
                    " token value; its only network request reads Meta's public certificate list.",
        epilog="examples:\n"
               "  %(prog)s ~/Downloads/meta-ai.apkm\n"
               "  %(prog)s ~/meta-ai-apks/            (base.apk and split_config.*.apk from adb pull)\n"
               "  %(prog)s base.apk --assetlinks assetlinks.json --out /tmp/Secrets.xcconfig\n"
               "  %(prog)s base.apk --sign-in-table-only\n\n"
               "exit codes: 0 written, 1 tokens missing or ambiguous, 2 bad input, 3 app check failed,"
               " 4 output not written, 5 sign-in function table missing or invalid\n"
               "guide: docs/META-CREDENTIALS.md",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("inputs", nargs="+", metavar="INPUT",
                        help="the Meta AI app: an .apk, a bundle (.apks, .xapk, .apkm) or a folder of split APKs")
    parser.add_argument("--out", metavar="PATH",
                        help="write Secrets.xcconfig to PATH and the table beside it (a folder receives both files);"
                             " with --sign-in-table-only, PATH is the file or folder for the table")
    parser.add_argument("--force", action="store_true", help="replace existing output files")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--show-candidates", action="store_true",
                      help="list what was found, masked: prefix, first and last 2 characters, length")
    mode.add_argument("--sign-in-table-only", action="store_true",
                      help="extract only the sign-in function table and leave Secrets.xcconfig alone")
    parser.add_argument("--scan-all", action="store_true",
                        help="scan every file in the app (native libraries, resources, assets), not only its code")
    parser.add_argument("--assetlinks", metavar="FILE",
                        help="a saved copy of " + ASSETLINKS_URL + " instead of reading it online")
    parser.add_argument("--apksigner", metavar="PATH",
                        help="apksigner from Android SDK build-tools (default: PATH, $ANDROID_HOME, ~/Library/Android/sdk)")
    parser.add_argument("--no-apksigner", action="store_true",
                        help="use the built-in certificate reader even if apksigner is installed")
    parser.add_argument("--skip-signature-check", action="store_true",
                        help="don't check that Meta signed the app (not recommended)")
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> int:
    if args.out is None:
        config = default_out()
        table = config.parent / TABLE_RESOURCE
        if args.sign_in_table_only:
            config = None
    elif args.sign_in_table_only:
        config = None
        table = resolve_out(args.out, TABLE_NAME)
    else:
        config = resolve_out(args.out, "Secrets.xcconfig")
        table = config.with_name(TABLE_NAME)
        if config == table:
            raise Failure(f"Choose a different --out filename for the client tokens. {TABLE_NAME} is the table.",
                          EXIT_OUTPUT)
    for path in (config, table):
        if path is not None and os.path.lexists(path):
            if path.is_dir():
                raise Failure(f"{path} is a folder.", EXIT_OUTPUT)
            if not args.force:
                raise Failure(f"{path} already exists. Not touching it; pass --force to replace it.", EXIT_OUTPUT)
    apks = load_apks(args.inputs)
    targets = [apk for apk in apks if has_targets(apk, args.scan_all)]
    if not targets:
        raise Failure("No app code (classes.dex) in " + ", ".join(apk.name for apk in apks) + ". Pass the base APK,"
                      " the whole bundle, or the folder with all the split APKs.", EXIT_INPUT)
    check_app(targets, args)
    findings = Findings() if config is not None else None
    tables = SignInTables()
    for apk in targets:
        for where, data in scan_entries(apk, args.scan_all):
            if findings is not None:
                findings.add(where, data)
            tables.add(where, data)
    outputs = {}
    if config is not None:
        if args.show_candidates:
            print("Candidates (masked):")
            print("\n".join(findings.masked_report()))
        tokens = findings.choose()
        for prefix in PREFIXES:
            print(f"found {prefix} token (length {len(tokens[prefix])})")
        info = manifest_info(targets[0])
        outputs[config] = xcconfig_text(tokens, info[1] if info else None)
    entries = tables.choose()
    print(f"Found {len(entries)} sign-in functions.")
    outputs[table] = table_text(entries)
    if args.out is None:
        try:
            table.parent.mkdir(parents=True, exist_ok=True)
        except OSError as error:
            raise Failure(f"Couldn't create {table.parent} ({error.strerror or error}).", EXIT_OUTPUT) from None
    for path in outputs:
        if not path.parent.is_dir():
            raise Failure(f"The folder {path.parent} doesn't exist.", EXIT_OUTPUT)
    for path, contents in outputs.items():
        write_private(path, contents, args.force)
        print(f"Wrote {path} (mode 0600).")
        if git_ignores(path) is False:
            warn(f"git does not ignore {path}. Add it to .gitignore before you commit anything.")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        return run(args)
    except Failure as failure:
        sys.stdout.flush()
        print(f"error: {failure}", file=sys.stderr)
        return failure.code
    except TableError as error:
        sys.stdout.flush()
        print(f"error: {error}", file=sys.stderr)
        return EXIT_TABLE
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
