#!/usr/bin/env python3
"""Dependency-free sanity check for AeroStudio website/release kit structure."""
from html.parser import HTMLParser
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {
    'AeroRoom-Windows.zip', 'AeroFilm-Windows.zip', 'AeroPhoto-Windows.zip',
    'AeroStudio-Launcher-Windows.zip',
    'AeroRoom-Launcher-Windows.zip', 'AeroFilm-Launcher-Windows.zip',
    'AeroPhoto-Launcher-Windows.zip'
}

class DownloadParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.assets = []
        self.scripts = []
        self.ids = []
        self.sources = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'data-asset' in attrs:
            self.assets.append(attrs['data-asset'])
        if 'id' in attrs:
            self.ids.append(attrs['id'])
        if tag == 'script' and 'src' in attrs:
            self.scripts.append(attrs['src'])
        if tag == 'img' and 'src' in attrs:
            self.sources.append(attrs['src'])

page = DownloadParser()
page.feed((ROOT/'docs/index.html').read_text(encoding='utf-8'))
assert len(page.assets) == 7 and set(page.assets) == EXPECTED, page.assets
assert {'downloads', 'download-room', 'download-film', 'download-photo', 'download-suite'} <= set(page.ids)
assert set(page.scripts) == {'config.js', 'app.js'}
for local in page.scripts + page.sources + ['styles.css', 'assets/favicon.svg']:
    assert (ROOT/'docs'/local).is_file(), f'Missing asset {local}'
for app in ('AeroRoom','AeroFilm','AeroPhoto'):
    for fname in ('LICENSE-MIT','LICENSE-APACHE'):
        assert (ROOT/'licenses'/app/fname).is_file(), f'Missing upstream {app} {fname}'
for local in ('launcher-template/AeroStudio.cmd',
              'launcher-template/Launcher/AeroStudio-Launcher.ps1',
              'launcher-template/Launcher/AeroStudio-Single.ps1',
              'launcher-template/scripts/Install-App.ps1',
              'tools/Make-Windows-Release.ps1',
              '.github/workflows/pages.yml'):
    assert (ROOT/local).is_file(), f'Missing {local}'
js=(ROOT/'docs/app.js').read_text(encoding='utf-8')
assert 'releases/tags/' in js and 'assets' in js and 'disabled-download' in js
script=(ROOT/'tools/Make-Windows-Release.ps1').read_text(encoding='utf-8')
assert 'AeroStudio-Launcher-Windows.zip' in script
assert '"$($app.Id)-Windows.zip"' in script
assert '"$($app.Id)-Launcher-Windows.zip"' in script
assert 'SHA256' in script
print('PASS: site assets, 7 download options, launcher templates, licensing and packaging inputs found.')
print('Note: this does NOT compile the Windows apps or execute PowerShell on Windows.')
