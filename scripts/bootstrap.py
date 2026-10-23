#!/usr/bin/env python3
"""Fetch the exact SDK/WDL revisions used by development and CI."""
import os
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parent.parent
DEPENDENCIES = [
    ('reaper-sdk', 'https://github.com/justinfrankel/reaper-sdk.git', 'c0eafe87863b2bf69c5c822760f1b32a753b211b'),
    ('WDL', 'https://github.com/justinfrankel/WDL.git', '61c5553aad0d257775a4dd7bf36b8be617ec8281'),
]
for name, url, commit in DEPENDENCIES:
    path = ROOT / 'third_party' / name
    path.mkdir(parents=True, exist_ok=True)
    def git(*args):
        return subprocess.run(['git', '-C', str(path), *args], check=True, capture_output=True, text=True)
    if not (path / '.git').exists():
        git('init')
        git('remote', 'add', 'origin', url)
    result = subprocess.run(['git', '-C', str(path), 'rev-parse', 'HEAD'], capture_output=True, text=True)
    current = result.stdout.strip() if result.returncode == 0 else ''
    if current != commit:
        git('fetch', '--depth', '1', 'origin', commit)
        git('checkout', '--detach', commit)
    print(f'{name}: {commit}')
if os.name != 'nt':
    link = ROOT / 'third_party/reaper-sdk/WDL'
    if not link.exists():
        link.symlink_to('../WDL/WDL', target_is_directory=True)
