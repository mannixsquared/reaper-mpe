#!/usr/bin/env python3
"""Package only the built plugin, installation instructions and SDK notices."""
import argparse
import hashlib
from pathlib import Path
import zipfile
ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--platform', choices=['macos-universal', 'windows-x64'], required=True)
args = parser.parse_args()
output = ROOT / 'dist'
output.mkdir(exist_ok=True)
name = f'reaper-mpe-{args.platform}'
archive = output / f'{name}.zip'
install = ('Copy reaper_mpe_editor.dylib to REAPER > Options > Show REAPER resource path > UserPlugins.\n'
           'Install js_ReaScriptAPI (for native piano-roll lookup) if missing.\n'
           'Supports Apple Silicon and Intel; macOS 11 or later.\n') if args.platform == 'macos-universal' else (
           'Copy reaper_mpe_editor.dll to REAPER > Options > Show REAPER resource path > UserPlugins.\n'
           'Requires 64-bit REAPER on Windows 10 or later. No separate Visual C++ runtime is needed.\n'
           'Windows overlay is a preview: built/tested in CI; live REAPER UI testing is still needed.\n')
install += ('Restart REAPER. Open a MIDI item and run MPE: Toggle per-note pitch editing.\n'
            'Use an MPE lower-zone instrument with member-channel bend range +/-48 semitones.\n'
            'See README.md for tools, limitations, and uninstall instructions.\n')
if not args.binary.is_file():
    parser.error(f'Plugin binary missing: {args.binary}')
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as bundle:
    bundle.write(args.binary, f'{name}/{args.binary.name}')
    bundle.write(ROOT / 'README.md', f'{name}/README.md')
    bundle.writestr(f'{name}/INSTALL.txt', install)
    for source in (ROOT / 'third_party/reaper-sdk/sdk/reaper_plugin.h', ROOT / 'third_party/WDL/WDL/swell/swell.h'):
        bundle.write(source, f'{name}/third-party-notices/{source.name}')
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
(archive.with_suffix('.zip.sha256')).write_text(f'{checksum}  {archive.name}\n')
print(archive)
