#!/usr/bin/env python3
"""Test spoken ReGlass addresses against the production parser, without audio services or network access."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='reglass-addressing-') as scratch:
    binary = str(Path(scratch) / 'tests')
    subprocess.run(['swiftc', '-parse-as-library',
                    str(root / 'ReGlassAssistant/Sources/ReGlassAssistant/Brain/Addressing.swift'),
                    str(Path(__file__).with_suffix('.swift')), '-o', binary], check=True)
    subprocess.run([binary], check=True)
