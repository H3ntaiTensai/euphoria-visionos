# AGENT.md

Instructions for AI coding agents (Claude Code, Codex, Cursor, Copilot, …) working in this repository. Read the whole file before you change anything. A human-oriented overview is in [README.md](README.md).

## What this project is

A **fully native** visionOS app (Swift, SwiftUI, RealityKit, Metal) that plays the visual novel *Euphoria* from the user's own copy of the PC game. The PC game runs on the YU-RIS 0.474 engine with the ERIS script framework. Python tools convert the compiled scripts to JSON. A Swift interpreter runs that JSON, and Swift reimplements the ERIS framework calls.

**The most important rule: keep it native.** Never add Ren'Py, a web view, WebAssembly, an embedded YU-RIS engine or a third-party game engine. New behavior goes into Swift (most often `Eris.swift`), so the app stays easy to customize.

## Hard rules

1. **Never commit game data.** That means nothing from `original/`, `extracted/`, `decompiled/`, `visionOS/Euphoria/Resources/Game/`, `*.ypf`, `*.ybn` or `*.sd` saves, and no game text, art, audio or movies. `.gitignore` covers these. Don't weaken it, and don't `git add -f`. Before every commit, check `git status` and the staged file list.
2. **No CG in docs or commits.** Screenshots under `docs/screenshots/` must show UI on backgrounds only, never event CGs (`cg/ev*`) or the gallery grid. The title screen in `title-in-room.jpg` is the one exception.
3. **No new dependencies.** The Python tools use the standard library only. The app uses Apple frameworks only, with no Swift packages. Ask the user before adding any.
4. **Don't hand-edit `visionOS/Euphoria.xcodeproj`.** `tools/create_xcode_project.py` generates it. After adding, removing or renaming a `.swift` or `.metal` file, run `python3 tools/create_xcode_project.py`. Pass `DEVELOPMENT_TEAM` and `BUNDLE_ID` as environment variables, never hard-code them.
5. **Match the original.** Timing, easing, layout (the 1024×768 stage coordinates) and branching should follow the original scripts. If you're unsure how a call behaves, read the decompiled ERIS source (see below) before guessing.

## Layout

```
tools/                     Python + shell build tools (stdlib only)
  ypf_extract.py           unpack .ypf archives
  yuris.py                 YSTB bytecode reader (format notes in docstring)
  ybn_decompile.py         optional: readable source → decompiled/
  build_story.py           scripts → Resources/Game/story/*.json + index
  package_assets.py        hard-link art/audio into Resources/Game
  convert_audio.sh         Ogg → AAC (visionOS can't decode Ogg)
  convert_movies.sh        MPEG-1 → H.264 MP4 (uses transcode_movie.swift)
  create_xcode_project.py  generates the .xcodeproj
  import_saves.py          PC saves → app slots
  explore_routes.py        headless route checker (the test suite)
visionOS/Euphoria/
  EuphoriaApp.swift        app entry, window + spatial scene setup
  StoryData.swift          JSON model of converted scripts
  Value.swift              YU-RIS values and expression evaluation
  StoryEngine.swift        interpreter: flow, variables, choices, saves, auto/skip
  Eris.swift               ERIS framework calls (MAC.*, es.SP.*, es.SND, choices)
  Stage.swift / StageView.swift / Shaders.metal   layers, tweens, rule transitions
  GameView.swift           window, dialogue, ornament, title, debug automation
  Panels.swift             history, save/load, settings
  Extras.swift             bonus menu: gallery, replay, music, staff comments
  SpatialScenes.swift      on-device spatial scenes for full-screen art
  AudioDirector.swift      sound channels
  Persistence.swift        save slots, globals, unlocks
docs/screenshots/          README images (UI only, no CG)
```

Git ignores these local folders, but they exist on the user's machine after a build:

- `original/Euphoria/`: the user's game install.
- `extracted/`: raw archive contents.
- `decompiled/source/`: YU-RIS-style source, including the ERIS framework at `decompiled/source/eris/`. This is the reference for how framework calls behave.
- `visionOS/Euphoria/Resources/Game/`: converted story and assets bundled into the app.

## First-time build for a new user

When someone asks you to build and install the app from scratch (README.md › Build with an AI agent), run README.md › Build for them, step by step:

1. **Ask first** for what only they know: the path to their installed game (the folder holding `euphoria.exe` and `pac/`), their Apple developer team ID, a bundle ID of their own (suggest `com.<name>.euphoria`), and their headset's name from `xcrun devicectl list devices`. Check the requirements in README.md: Xcode 26+, Python 3.9+, about 12 GB free.
2. **Copy the game** to `original/Euphoria/` and confirm `original/Euphoria/pac/bn.ypf` exists. Never commit it.
3. **Extract and convert** with the commands in README.md › Build › 2, in order. Extraction and audio conversion take several minutes each; run them in the background and report progress.
4. **Check the conversion** with `explore_routes.py` (see Verify your change, step 2). It should reach 456/457 scripts and all six movies.
5. **Generate the project** with their team ID and bundle ID (below), then build, install and launch.
6. **Hand back what you can't do:** signing in to Xcode, enabling Developer Mode, pairing the headset, and trusting the developer certificate on the headset (*Settings › General › VPN & Device Management*). If they have PC saves, offer README.md › Importing PC saves.

Never commit their game data, team ID, bundle ID or headset name.

## Build and run

From the repo root (the full first-time pipeline is in README.md › Build):

The app targets a physical Apple Vision Pro. Ask the user for their team ID, bundle ID and headset name if you don't know them, and never commit them.

```sh
DEVELOPMENT_TEAM=<team> BUNDLE_ID=<bundle id> python3 tools/create_xcode_project.py
xcodebuild -project visionOS/Euphoria.xcodeproj -scheme Euphoria \
  -destination 'generic/platform=visionOS' -derivedDataPath .build/DeviceData \
  -allowProvisioningUpdates build
xcrun devicectl list devices
xcrun devicectl device install app --device "<headset>" .build/DeviceData/Build/Products/Debug-xros/Euphoria.app
xcrun devicectl device process launch --device "<headset>" <bundle id> -- -autostart YES
```

Put launch arguments after `--`: without it, devicectl reads arguments such as `-traceLines` as its own options.

The headset must be awake, unlocked, in Developer Mode and paired with the Mac. If `devicectl` can't reach it, tell the user. Don't retry in a loop.

If you change `tools/build_story.py` or `tools/yuris.py`, regenerate the story JSON:

```sh
python3 tools/build_story.py extracted/bn/ysbin extracted visionOS/Euphoria/Resources/Game
```

If `Resources/Game/` is missing, the asset pipeline hasn't run. Run it from the user's own game (see First-time build) if they want a build; otherwise tell them. Never fabricate placeholder assets.

## Verify your change

1. **It builds.** Run the `xcodebuild` command above with zero errors. Don't leave new warnings.
2. **Routes still work** after any interpreter, converter or flow change:
   ```sh
   python3 tools/explore_routes.py visionOS/Euphoria/Resources/Game/story
   python3 tools/explore_routes.py visionOS/Euphoria/Resources/Game/story --replays
   ```
   The baseline is 456/457 scripts reached, all six movies, no problems, and 78/78 replays clean. `explore_routes.py` mirrors the Swift interpreter. If you change flow semantics in `StoryEngine.swift`, make the same change there.
3. **It looks right.** Launch on the headset with the debug launch arguments to jump straight to the scene you changed, then ask the user to check it in the headset:
   ```sh
   xcrun devicectl device process launch --device "<headset>" <bundle id> -- -startLabel <label> -autoAdvance 1 -traceLines YES
   ```
   The arguments are `-autostart YES`, `-startLabel <label>`, `-loadSlot <slot>`, `-autoAdvance <sec>`, `-choices 0,1`, `-skip YES`, `-skipFor <sec>` (stop skipping after that long), `-traceLines YES`, `-traceSound YES`, `-traceSpatial YES` (spatial scene queue and display), `-simulateSpatial <sec>`, `-panel history|save|load|settings|gallery|replays`, `-textHidden YES`, `-titleExtras YES`, `-viewGallerySet N`, `-replay <label>`, `-playMovie <name>`, `-bonusGroup N` and `-bonusSwitch <section>` (change bonus section after a few seconds). They're implemented in `DebugAutomation` in `GameView.swift` and work in Debug builds only. Logs go to `Documents/debug.log` in the app container. Pull it with:
   ```sh
   xcrun devicectl device copy from --device "<headset>" --domain-type appDataContainer \
     --domain-identifier <bundle id> --source Documents/debug.log --destination .build/
   ```
4. **Say what you couldn't check.** You can't see the headset's display. Say clearly which visual, spatial-scene and gaze/pinch behavior the user still needs to confirm by looking.

## Conventions

- Swift 5 mode, visionOS 26 deployment target. SwiftUI with `@Observable`. Keep the engine on `@MainActor` like the existing code.
- Match the style around you: short doc comments on types and non-obvious functions, no banner comments, and no force-unwraps on asset lookups (a missing asset logs and skips).
- Framework calls are dispatched by name in `callFramework` in `Eris.swift`. Arguments are positional and 1-based, as in the original (see the argument helper at the bottom of `StoryEngine.swift`). Calls with no case are logged as "Unimplemented framework call". To add a call, find it in `decompiled/source/eris/`, implement its observable effect, and keep the original's millisecond durations, converting them with `seconds(_:)`.
- UI should feel like visionOS: rounded window, glass materials (`.glassBackgroundEffect()`), controls in ornaments, and hover effects on interactive elements.
- Variables appear as `@1078` (int) and `$1110` (string) because the compiled form has no names. If you work one out, document it in a comment. Don't rename keys in saved JSON, because that breaks existing saves.
- Persistence formats (`Saves/*.json`, `globals.json`, `progress.json`) must stay backward compatible. Add optional fields only.

## Known gaps (good first tasks)

- Blend modes, skew, and the bonus-game counters in `Eris.swift`.
- More faithful blur and continuous shake.
- `import_saves.py`: follow the jump that leaves some PC saves at a menu.
- Hardware polish: gaze/pinch targets, comfort, and spatial scene timing.

## Git

- Work on a branch. Keep commits small and use imperative subjects ("Add blend mode support to es.SP").
- Run `git status` before committing, and confirm that no file under the ignored game-data paths is staged.
- This repo is private. Don't change its visibility, and don't push to any other remote.
