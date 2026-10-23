#!/usr/bin/env python3
"""Run only the isolated test instance; never connect to an existing REAPER."""
import subprocess
import time
from pathlib import Path
root = Path(__file__).resolve().parent.parent
resource = root / 'build/native-test'
log = resource / 'probe.log'
log.unlink(missing_ok=True)
process = subprocess.Popen([
    '/Applications/REAPER.app/Contents/MacOS/REAPER', '-newinst',
    '-cfgfile', str(resource / 'reaper.ini'), '-new', '-nosplash',
    '-ApplePersistence', 'NO'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(300):
        if log.exists() and any(marker in log.read_text() for marker in ('PASS:', 'FAIL:', 'REFUSED:')):
            break
        if process.poll() is not None:
            break
        time.sleep(.1)
    result = log.read_text() if log.exists() else f'No result; exit={process.poll()}'
    lines = result.splitlines()
    print("\n".join(lines[:5] + ["..."] + lines[-3:]) if "PASS:" in result else result)
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
