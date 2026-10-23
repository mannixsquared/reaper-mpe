Native per-note pitch editing inside REAPER's existing MIDI editor.

- Freehand and smooth curves, draggable handles, double-click insertion and Alt/Option-click deletion.
- Natural vibrato with adjustable depth/rate, gentle fade-in/out and subtle variation.
- Independent member-channel allocation and standard MIDI pitch-bend events with undo.
- Dense multichannel MIDI buffer handling, validated snapshots and bounded curve sampling.

Downloads:

- **macOS universal:** Intel and Apple Silicon, macOS 11+. Install `reaper_mpe_editor.dylib` in REAPER's `UserPlugins` folder. Requires js_ReaScriptAPI.
- **Windows x64 preview:** Windows 10+ and 64-bit REAPER. Install `reaper_mpe_editor.dll` in `UserPlugins`. The Windows overlay is newly ported; CI verifies the build and shared core tests, but live Windows REAPER interaction still needs testing.

Restart REAPER, open a MIDI item, and run **MPE: Toggle per-note pitch editing**. Use an MPE lower-zone instrument with a **+/-48 semitone member-channel pitch-bend range**.

This is an early preview. See the included README for current limitations. SHA-256 checksum files accompany both ZIP archives. The macOS binary is ad-hoc signed, not Apple-notarized; Windows binaries are unsigned.
