#!/usr/bin/env python3
"""Compile a local renderer around actual SwiftUI views, then save the sample view."""
from pathlib import Path
import subprocess

REPO = Path(__file__).resolve().parents[1]
binary = REPO / '.build/landing-result-renderer'
binary.parent.mkdir(exist_ok=True)
sources = sorted(str(path) for path in (REPO / 'Sources/StudyLens').rglob('*.swift') if path.name != 'StudyLensApp.swift')
subprocess.run(['swiftc', '-parse-as-library', '-o', str(binary), *sources, str(REPO / 'brand/render-app-result.swift')], check=True)
subprocess.run([str(binary), str(REPO / 'brand/result-example.txt'), str(REPO / 'brand/app-result.png')], check=True)
