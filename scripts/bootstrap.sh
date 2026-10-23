#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p third_party
[ -d third_party/reaper-sdk ] || git clone --depth 1 https://github.com/justinfrankel/reaper-sdk.git third_party/reaper-sdk
[ -d third_party/WDL ] || git clone --depth 1 https://github.com/justinfrankel/WDL.git third_party/WDL
[ -e third_party/reaper-sdk/WDL ] || ln -s ../WDL/WDL third_party/reaper-sdk/WDL
