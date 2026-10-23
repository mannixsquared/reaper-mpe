# REAPER MPE Editor

A C++ REAPER extension for macOS and Windows (Windows UI preview) that draws per-note pitch curves inside REAPER's **existing MIDI editor**. Edit mode stays on across strokes and note selections. No replacement editor or audio effect is involved.

## Try it

1. Restart REAPER after installation. For a first test, use a MIDI item containing a few overlapping notes.
2. Set the instrument to MPE lower zone (manager channel 1, members 2–16), with **±48 semitone member-channel pitch bend range**. The extension does not configure the synth.
3. Open the built-in MIDI editor in standard piano-roll mode with all pitch rows visible. Show all MIDI channels.
4. Run **MPE: Toggle per-note pitch editing** from the **MIDI Editor** or **Main** action list. It can be assigned to a shortcut or toolbar button; the button reflects whether editing is on. The old prototype action ID is preserved in Main, so existing shortcuts still work.
5. Pitch curves appear on every visible note in the active take. Notes without pitch data have horizontal lines. All pitch curves are black. The selected curve shows white-filled handles outlined in black. Click a note or its selected curve to select it.
6. Drag a selected curve’s handle to reshape it, or draw away from the handles to replace the curve. Release to commit. Up raises pitch, down lowers it: **one piano-roll row = one semitone**, following vertical zoom. The overlay stays on, so select another note and continue.
7. Click **Off**, press **Escape**, or run the toggle action again to return to native note editing. Pitch data remains ordinary MIDI and plays without the extension.

The small toolbar in the MIDI ruler has these controls:

| Control | Shortcut | Behaviour |
| --- | --- | --- |
| Freehand | F | Follow the drawn stroke, including intermediate rises and falls. |
| Smooth | S | Draw a smooth cubic transition from the stroke's starting pitch to its ending pitch; intermediate mouse movement is ignored. |
| Flat | 0 | Reset the selected note's pitch to a horizontal, unbent line. |
| Off | Escape | Leave edit mode. |
| Vibrato | V | Click a note to add natural vibrato; drag vertically for depth and horizontally for rate. |

Drag handles vertically to change pitch and horizontally to move the control point in time. Endpoints stay fixed to the note boundaries; interior points cannot cross neighbouring points. Flat, straight and simple eased curves use just two endpoint handles. Double-click the selected curve to add an interior handle; it commits on release even without dragging. You can also keep dragging after the double-click to place it. **Alt/Option-click an interior handle to delete it** and reconnect its neighbours. Each addition or deletion is one undoable edit. The two endpoint handles are retained. Smooth mode interpolates handles with a cubic curve without pitch overshoot; Freehand mode joins them with straight segments. Moving a handle resamples the curve into normal MIDI with one undo step. Handles are reconstructed from existing MIDI, so opening a project or undoing an edit also restores editable handles. Extraction is cached and bounded to 64 controls; smooth curves use a fixed sampling budget rather than multiplying samples on each edit. Very dense imported shapes may be approximated when edited through handles.

Each drawing stroke replaces the selected note's whole curve. The first and last drawn values extend to the note boundaries. Drawing can move vertically or backwards: moving over an earlier time repaints that section with the newest stroke. Dragging beyond the right edge keeps the endpoint following the mouse vertically. Click without dragging only selects. Playback audition is available after releasing the stroke; drawing does not stream live MIDI.

In edit mode the piano roll uses a **crosshair drawing cursor**. The plugin filters F, S, V, 0 and Escape at the macOS application’s `sendEvent:` entry, before REAPER/SWELL translates native shortcuts; S changes tools without slicing, and Escape disables MPE editing while keeping the MIDI editor open. Modified shortcuts such as Cmd-S remain available to REAPER, and text fields retain normal typing.

**Vibrato:** select the Vibrato tool (or press V), then click a note to add a default **5.5 Hz / 35-cent peak** vibrato over its existing pitch curve. For a preview, drag up/down to increase/decrease depth and right/left to increase/decrease rate. The toolbar shows the current values; depth is limited to 0–200 cents and rate to 2–10 Hz. Values carry over to the next note. Release commits in one undo step. Vibrato eases in after a short delay, varies gently in depth/rate, and fades back to the underlying pitch at the end. Timing is in seconds, so tempo and editor zoom do not change the rate. Clicking again adds another pass; undo first to replace a pass. Switch to F or S to edit the resulting ordinary pitch curve through handles. Samples are capped at 4,096 intervals per note to keep long-note edits bounded.

**Undo:** Cmd-Z undoes the last edit; Cmd-Shift-Z redoes it while edit mode is on. Each committed curve is one undo step. Native edits, undo, and redo are re-read so displayed curves reflect the MIDI take rather than a separate saved drawing.

## Mapping and channels

The overlay reads the active take's editor zoom and scroll state and attaches to the piano-roll child view. It follows scroll/zoom with a 60 Hz common-run-loop viewport timer, a coalesced update immediately after native wheel/trackpad delivery. Layout refresh is separate from MIDI-content polling. Per-channel binary-search lookups avoid rescanning all bend events for each rendered pixel. A view change during a stroke cancels that stroke. Scrolling passes to the native editor. Changing the active editor, take, or project closes edit mode.

The implementation uses the undocumented `CFGEDITVIEW`/`CFGEDIT` item-chunk layout fields, following the approach used by [js_Mouse editing scripts](https://github.com/ReaTeam/ReaScripts/blob/master/MIDI%20Editor/js_Mouse%20editing%20-%20Slice%20notes.lua). It requires the **js_ReaScriptAPI** extension to locate piano-roll child 1001. It does not use that extension to create a separate editor. Both beats and seconds timebases map stroke samples back to PPQ; tempo changes in a seconds view are handled through REAPER's time conversion APIs.

A note already on a member channel retains that channel when it has no overlapping note on the same channel. Otherwise the extension allocates a member channel containing no notes or channel events anywhere in this take. Repeated edits reuse the assigned channel. When no safe channel remains, the edit is refused. Only pitch bend messages within the selected note's interval on its destination channel are replaced, using one bulk raw-MIDI write. Unrelated event bytes and flags are retained, and associated Bezier metadata is removed only with a replaced pitch event. A complete raw MIDI snapshot is validated against the note count before any mutation. The reader grows its reusable buffer whenever REAPER leaves the output size equal to capacity—even if the API reports success. This native behaviour occurs when a buffer is too small; accepting that buffer caused the earlier size-dependent failure. Both the generated stream and post-write note count are checked, and only a validated snapshot may be used for rollback.

MIDI sorting is disabled during the edit batch and performed once after the bulk write. Undo capture is limited to item changes. The released frame reuses the edited controls and updates the in-memory model directly rather than reconstructing handles or enumerating all MIDI again. Handle clicks use cached state when the project revision is unchanged; painting and active gestures do not serialize the take.

Calls exceeding 16 ms are recorded by operation name and elapsed time in `/tmp/reaper_mpe_performance.log`. This log contains no MIDI or project contents.


## Current limitations

- The active take is rendered; other takes visible behind it are not overlaid. Repeated loop-source occurrences, drum/notation modes, hidden/folded rows and scale-remapped rows are not supported. Use a standard piano roll with every pitch row visible.
- Allocation checks this take, not other items, pooled-source instances, sustain pedal state, or instrument release tails. It reserves at most 15 newly allocated member channels. It does not redistribute existing shared-channel pressure, CC74 or other expression when a note is moved to a new channel.
- Pitch rendering uses MIDI's channel state. If existing notes share a channel, their bends are shared until independently edited onto separate channels. Muted notes' curves are shown dimmed.
- Existing native Bezier curves are approximated visually; newly drawn smooth curves are sampled into standard 14-bit pitch-bend events. Events at the same MIDI tick are coalesced. Curve endpoints stay before note-off so redraws do not leave stray events on the next note.
- Later native move/copy/resize operations do not automatically carry attached expression: these are channel MIDI events. Turn edit mode off for native note manipulation. Re-enable it to see the resulting MIDI.
- The plugin-host integration tests cover native overlay attachment and editing against a mock host, not live REAPER window layout or instrument playback. The updated layout needs interactive testing in REAPER.

## Build and install

Requires macOS 11+, Apple Command Line Tools, REAPER, and js_ReaScriptAPI. Produces an ad-hoc signed universal Apple Silicon/Intel dylib.

```sh
./scripts/bootstrap.sh
./scripts/build.sh
./scripts/install.sh
```

Install defaults to `~/Library/Application Support/REAPER/UserPlugins/reaper_mpe_editor.dylib`. A custom UserPlugins directory can be passed as the first install argument. The previous dylib is backed up with a `.previous` suffix. Restart REAPER after installing/updating. To uninstall, quit REAPER and remove the dylib.

`build.sh` runs mathematical regression tests, builds/signs the plugin, then loads that actual dylib into an in-memory host for integration tests:

- Curve mapping, pitch saturation, freehand and cubic interpolation, tick coalescing.
- Vibrato fade-in/out, peak depth, cycle rate, deterministic variation and bounded event count.
- Three-semitone joins in both directions at five vertical zoom levels, in both drawing modes.
- Minimal flat/straight/eased handles, backward and vertical strokes, note-edge tracking, repeated complex smooth edits with bounded sample counts, handle ordering and bounds, smooth interpolation without overshoot, and actual mouse-driven handle edits preserving endpoint pitch and generating the expected MIDI values.
- Blank/existing/muted bend rendering data, interpolation, multi-take layout parsing.
- Persistent Cocoa overlay, action toggle state, repeated curve replacement, overlapping-note channel isolation, unrelated controller preservation.
- Undo transaction boundaries limited to item state, exact-stream rollback on write failure, stale-stroke rejection, and assertions that each edit uses one bulk write and one final sort.
- Handle-click assertions for zero chunk reads, MIDI hashes or full enumerations when state is unchanged; release assertions for no full model reload.
- Regression for REAPER returning success with an unchanged, unfilled buffer: retry at a larger capacity before any write.
- `tests/native_probe.mm` exercises the actual built plugin against native REAPER APIs in an isolated resource/project. A 96-note, roughly 22,000-controller fixture (264 KiB raw MIDI) passes 30 mixed freehand/smooth/vibrato edits with all original note attributes preserved. User fixtures and isolated resources remain in ignored `build/`.
- Raw MIDI byte/flag preservation, initial event ordering, Bezier cleanup, malformed-buffer rejection, and a 50,000-event replacement.
- Application-entry event filtering with a test application that processes shortcuts before Cocoa view dispatch: plain/Shift F/S, repeat/release consumption, modified shortcut forwarding, text entry, and Escape swallowing after overlay removal.
- Native accelerator fallback, timer cleanup, and immediate scroll mapping updates without MIDI-content changes.

Source layout: `src/plugin.mm` contains the REAPER/Cocoa integration; `src/curve.h` contains curve and allocation logic; `src/view_state.h` parses editor geometry. Tests live in `tests/`.

Official Cockos REAPER SDK and WDL headers are downloaded into ignored `third_party/`. Original license notices remain intact. Tested SDK revision: `c0eafe87863b2bf69c5c822760f1b32a753b211b`; WDL revision: `61c5553aad0d257775a4dd7bf36b8be617ec8281`.

## GitHub Actions and releases

`Build and release` builds on pushes to `main`, pull requests, version tags and manual dispatch. macOS builds a single ad-hoc signed universal dylib; Windows builds an x64 DLL with a statically linked runtime. Both run the portable engine tests; macOS also runs Cocoa keyboard and mock-host integration tests. Native REAPER is not installed on CI runners.

Push a new `v*` tag to publish a GitHub prerelease after both platform jobs pass. Each release contains platform ZIPs, installation instructions, SDK/WDL notices, and SHA-256 checksums. The first release is `v0.1.0`. The Windows overlay uses Win32 subclassing and a thread-local keyboard hook, sharing the curve/handle/vibrato/MIDI algorithms with macOS. It remains a live-UI preview until tested in Windows REAPER.

CMake build (macOS with CMake or Windows with Visual Studio 2022 C++ tools and CMake):

```sh
python scripts/bootstrap.py
cmake -S . -B build/cmake
cmake --build build/cmake --config Release
ctest --test-dir build/cmake -C Release --output-on-failure
```

On Windows use `-G "Visual Studio 17 2022" -A x64` when configuring. On macOS add `-DCMAKE_BUILD_TYPE=Release '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64' -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0` for a universal release build. Windows installation: copy `reaper_mpe_editor.dll` to the `UserPlugins` directory opened by **Options > Show REAPER resource path**, then restart REAPER. Windows uses Ctrl-Z/Ctrl-Shift-Z for undo/redo; F/S/V/0/Escape and mouse tools match macOS.
