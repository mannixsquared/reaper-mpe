#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
clang++ -std=c++17 -O2 -Wall -Wextra -Isrc tests/vibrato_test.cpp -o build/vibrato_test
./build/vibrato_test
clang++ -std=c++17 -O2 -Wall -Wextra -Isrc tests/midi_batch_test.cpp -o build/midi_batch_test
./build/midi_batch_test
clang++ -std=c++17 -fno-objc-arc -Wall -Wextra -Isrc tests/keyboard_gate_test.mm -framework Cocoa -o build/keyboard_gate_test
./build/keyboard_gate_test
clang++ -std=c++17 -Wall -Wextra -Isrc tests/curve_test.cpp -o build/curve_test
./build/curve_test
clang++ -std=c++17 -O2 -fno-objc-arc -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -Ithird_party/reaper-sdk/sdk -Isrc src/plugin.mm -framework Cocoa -o build/reaper_mpe_editor.dylib
codesign --force --sign - build/reaper_mpe_editor.dylib
clang++ -std=c++17 -fno-objc-arc -Wall -Wextra -isystem third_party/reaper-sdk/sdk -Isrc tests/plugin_host_test.mm -framework Cocoa -o build/plugin_host_test
./build/plugin_host_test ./build/reaper_mpe_editor.dylib
printf 'Built and signed build/reaper_mpe_editor.dylib; curve and plugin-host tests passed.\n'
