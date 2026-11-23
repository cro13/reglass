#!/usr/bin/env python3
"""Offline tests of the production Swift factory downloader; creates only synthetic fixtures.

Compiles FactoryWakeWordDownload.swift with the real ReGlassKit files it needs (no stand-ins) and checks the
constellation queries, the language offer, the prompts read from a language pack, the Hey Meta model search, the CDN
URL check and fetch's input checks. It makes no network request and needs no Meta file or login.

The optional --firmware argument also searches a Meta firmware image you already hold locally for the real
"Hey Meta" model. The image is only read in place; it is never copied into the repository or uploaded.
Requires macOS and Xcode command-line tools (CryptoKit, Compression).
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile
import zipfile

# The real ReGlassKit files the downloader needs to compile, relative to ReGlassKit/Sources/ReGlassKit.
SOURCES = [
    'WakeWord/FactoryWakeWordDownload.swift', 'WakeWord/ZipArchive.swift', 'WakeWord/WakeWordSet.swift',
    'WakeWord/ResourceOtaMessages.swift', 'WakeWord/WakeWordFault.swift', 'Firmware/FirmwareOffer.swift',
    'Firmware/FirmwareImageDownload.swift', 'Protocol/Wire.swift', 'Protocol/ProtocolConstants.swift',
    'Support/Bytes.swift', 'Support/Log.swift', 'Support/ReGlassError.swift', 'Support/Async.swift',
]
# The language variant every factory download takes its prompts from.
VARIANT = 'en_US.mai_03'
OTHER = 'en_US.mai_02'


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def variant(name, prompts):
    """One manifest variant, as Meta's schema 2 lists it: variants[].files[].path and checksum "sha256:…"."""
    return dict(id=name, files=[dict(path=f'{name}/{n}', size=len(d), checksum='sha256:' + sha256(d))
                                for n, d in prompts.items()])


def write_pack(path, manifest, files):
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        if manifest is not None:
            archive.writestr('manifest.json', json.dumps(manifest))
        for name, data in files.items():
            archive.writestr(name, data)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--firmware', type=pathlib.Path, help='a Meta firmware image held locally (read only)')
    args = parser.parse_args()
    if args.firmware and not args.firmware.is_file():
        parser.error(f'no file at {args.firmware}')
    root = pathlib.Path(__file__).resolve().parents[2]
    source = root / 'ReGlassKit/Sources/ReGlassKit'

    # The seven prompt names come from the real ResourceOta table (the eighth file, the model, is in the firmware).
    table = (source / 'WakeWord/ResourceOtaMessages.swift').read_text().split('static let filenames', 1)[1]
    names = re.findall(r'"([A-Z0-9_]+)"', table.split(']', 1)[0])
    assert len(names) == 8 and 'WAKE_WORD_MODEL' in names, names
    prompts = {n: (n + ':test-prompt\n').encode() * 40 for n in sorted(names) if n != 'WAKE_WORD_MODEL'}
    # A second voice with different bytes, so picking the wrong variant shows.
    other = {n: b'other-voice:' + d for n, d in prompts.items()}
    files = {f'{OTHER}/{n}': d for n, d in other.items()}
    files[VARIANT + '/'] = b''
    files.update({f'{VARIANT}/{n}': d for n, d in prompts.items()})
    good = dict(schema_version=2, locale='en_US', variants=[variant(OTHER, other), variant(VARIANT, prompts)])
    first = next(iter(prompts))

    with tempfile.TemporaryDirectory(prefix='reglass-factory-tests-') as work:
        work = pathlib.Path(work)
        (work / 'expected.json').write_text(json.dumps({n: sha256(d) for n, d in prompts.items()}))
        write_pack(work / 'pack.zip', good, files)
        # Each broken pack differs from the good one in one way.
        write_pack(work / 'pack-bad-sha.zip', good, {**files, f'{VARIANT}/{first}': b'changed' + prompts[first]})
        write_pack(work / 'pack-missing.zip', good, {k: v for k, v in files.items() if k != f'{VARIANT}/{first}'})
        unlisted = variant(VARIANT, {n: d for n, d in prompts.items() if n != first})
        write_pack(work / 'pack-unlisted.zip', {**good, 'variants': [variant(OTHER, other), unlisted]}, files)
        write_pack(work / 'pack-no-variant.zip', {**good, 'variants': [variant(OTHER, other)]}, files)
        write_pack(work / 'pack-schema-3.zip', {**good, 'schema_version': 3}, files)
        write_pack(work / 'pack-no-manifest.zip', None, files)

        binary = work / 'tests'
        subprocess.run(['swiftc', '-parse-as-library', *(str(source / s) for s in SOURCES),
                        str(pathlib.Path(__file__).with_suffix('.swift')), '-o', str(binary)], check=True)
        command = [str(binary), str(work)]
        if args.firmware:
            command.append(str(args.firmware.resolve()))
        subprocess.run(command, check=True)


if __name__ == '__main__':
    main()
