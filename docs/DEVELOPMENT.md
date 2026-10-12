# Developing Keystivo

How Keystivo is put together, how to build and sign it, and the technical details behind its features. For an overview of what Keystivo does, see the [README](../README.md).

## Architecture

```
Keystivo.xcodeproj          Thin app target: @main, Info.plist, entitlements, assets
Helper/                     Privileged charging helper (launchd daemon, XPC)
Savers/                     Screen saver host view and thumbnail generator (built by Scripts/build-savers.sh)
Packages/KeystivoKit        Swift package with independently testable modules
├── KeystivoCore            Localization, action registry, hotkeys (Carbon), shared event tap,
│                           permissions, diagnostics, JSON/SQLite persistence, fuzzy matcher
├── KeystivoAccessibility   AXUIElement wrapper, AX observers, window catalog, focusing
├── KeystivoWindows         Snap geometry, window manager, focus history, layouts, rules, tiling
├── KeystivoNavigation      Hint labels, element collector, hint/scroll state machines
├── KeystivoAudio           Device manager, process-tap per-app volume, audio profiles
├── KeystivoClipboard       History store (actor + SQLite), monitor, snippet expansion
├── KeystivoSearch          App catalog, Spotlight search, calculator, unit converter, text actions
├── KeystivoInput           Trackpad (MultitouchSupport) and mouse gestures, conflicts, input sources
├── KeystivoAutomation      Triggers, conditions, workflow engine, scheduler, library
├── KeystivoSystem          Power, keep-awake, power profiles, system commands, focus mode
├── KeystivoPlugins         Script plugins (manifest, trust, sandboxed process execution)
├── KeystivoTools           OCR/QR, color picker, annotation model and renderer, screen recorder,
│                           DDC/DisplayServices brightness, display modes, system monitor, Finder bridge
├── KeystivoFiles           App uninstaller, folder rules (FSEvents), shelf
├── KeystivoLinks           Browser routing rules, link cleaning, default-browser handling
├── KeystivoScreenSaver     Screen saver designs (SwiftUI), shared by the app and the .saver bundles
├── CSMC, KeystivoHelperCore  SMC access, charge-control schemes, XPC protocol, charge-limit policy
└── KeystivoApp             Composition root (runtime, configuration) and all UI
```

**One action system.** Everything Keystivo can do is an `ActionDescriptor` registered with `ActionRegistry`. Shortcuts, gestures, the launcher, workflows, profiles, device profiles and plugins all run the same `ActionInvocation`s. That makes command chains and automation possible without special cases.

**Event-driven, low overhead.** There's one shared `CGEventTap`, and its event mask is recomputed from what features need right now, so with snippets, mouse gestures and ⌘⇥ takeover off, no keyboard events are delivered. The multitouch engine, audio taps and thumbnails start only when used. AX observers, Core Audio listeners, IOKit power notifications and workspace notifications replace polling. The only timer-based checks are the clipboard change counter (macOS offers no notification) and a short-lived permission watcher.

**Configuration.** Everything is in one JSON document (`~/Library/Application Support/Keystivo/configuration.json`) that is decoded tolerantly (deep-merged onto defaults), saved atomically with debouncing, and backed up before imports, restores and resets. Clipboard history lives separately in SQLite and is never exported.

## Building

Requires Xcode 26 or later (developed with Xcode 27, Swift 6.4).

```bash
make signing-cert # once per Mac: local signing certificate (see below)
make run          # build Debug and launch
make test         # unit tests for every module (Swift Testing)
make dmg          # Release build → dist/Keystivo-<version>.dmg
make l10n-check   # every string used in code exists in every language
```

Or open `Keystivo.xcodeproj` and run the **Keystivo** scheme.

### Installing

`make dmg` produces a drag-to-install disk image: open it and drag Keystivo into Applications. If Keystivo is started from somewhere else (the disk image, Downloads), it offers to move itself into Applications, trashes an older copy there, relaunches and ejects the disk image. Only one Keystivo runs at a time; a newly started copy quits the previous one, so updates take over cleanly. Settings live in `~/Library/Application Support/Keystivo` and are kept across updates.

The disk image window layout is stored in `Config/DMG/DS_Store`. It is created the first time `make dmg` can control Finder (allow your terminal under *Privacy & Security › Automation*); run `Scripts/make-dmg.sh --relayout` to regenerate it.

### Signing and permissions

Keystivo needs **Accessibility** (window control, keyboard navigation, gestures, ⌘⇥ takeover). **Screen Recording** (live previews, screen recordings), **System Audio** (per-app volume) and **Microphone** (recordings with your voice) are optional. The app can't be sandboxed; distribute it with Developer ID.

macOS ties privacy permissions to the code signature. Ad-hoc signatures change with every build, so without a certificate Accessibility and Screen Recording have to be granted again after each rebuild. `make signing-cert` creates a self-signed "Keystivo Local Signing" certificate in your login keychain and a git-ignored `Config/Local.xcconfig` that uses it; grants then survive rebuilds and updates. To sign with an Apple developer team instead (needed for distribution and for the charging helper on other Macs), see `Config/Local.xcconfig.example`.

After switching signing identities, Keystivo may appear in *System Settings › Privacy & Security* while still reporting "not granted": remove the entry with **−** once and grant access again.

A locally signed disk image is meant for your own Macs. Copied to another Mac through the internet, Gatekeeper blocks it because it isn't notarized.

## Localization

All UI strings live in a String Catalog (`KeystivoCore/Resources/Localizable.xcstrings`): English, Türkçe, Deutsch, Français, Español, Italiano, Português (Brasil), Русский, 简体中文, 繁體中文, 日本語, 한국어. The language can be switched live in Settings › General.

```bash
python3 Scripts/l10n.py check              # missing keys, coverage, placeholder mismatches
python3 Scripts/l10n.py missing de         # untranslated strings as JSON
python3 Scripts/l10n.py import de de.json  # merge translations
```

## Plugins

A plugin is a folder `Name.keystivoplugin/` in `~/Library/Application Support/Keystivo/Plugins` containing a `manifest.json` and executable scripts in any language. Commands can be `silent`, `text` or `list` (JSON items with `open`, `copy`, `paste`, `notify` or `run` actions). Scripts run in their own process with a timeout and receive `KEYSTIVO_QUERY` and `KEYSTIVO_LANGUAGE`. A plugin must be trusted explicitly, and changing its files revokes trust. Settings › Plugins installs a commented example.

## Technical notes and limits

- **⌘⇥ takeover and reserved shortcuts:** macOS consumes chords like ⌘⇥ and ⌘\` before regular hotkeys fire, so Keystivo matches them in its event tap (Accessibility required). The shortcut recorder also captures through the tap, so any chord can be recorded.
- **Hyper key and remapping** use the built-in `hidutil` user key mapping for the current session. They're reset when Keystivo quits and need no driver or root.
- **Battery charge limiting** runs through a small launchd daemon (`KeystivoHelper`) registered with `SMAppService` after the user approves it in Login Items. It accepts XPC connections only from Keystivo's signature and can only pause or resume charging and bypass the adapter, through the SMC keys this Mac's firmware supports (`CHTE` on current Apple Silicon firmware, `CH0B`/`CH0C` on older firmware, `BCLM` on Intel). It restores normal charging whenever Keystivo disconnects, and also when the helper itself starts. Macs without a battery or without these keys show the feature as unavailable. Installing a launchd daemon requires a Developer ID-signed build.
- **External monitor brightness** uses DDC/CI over `IOAVService` on Apple Silicon. Services are paired with displays by EDID vendor, product and serial number, and slider moves are coalesced so only the latest value is written. Built-in and Apple displays use DisplayServices. Monitors that don't answer DDC (and Intel Macs) fall back to gamma dimming.
- **Screen savers** are real `.saver` bundles, one per design, compiled from the `KeystivoScreenSaver` sources by the app's "Build Screen Savers" phase (cached by source hash) and shipped in `Keystivo.app/Contents/Library/Screen Savers`. Settings › Screen Savers copies them to `~/Library/Screen Savers`. Each bundle uses its own Swift module name so several can load in one process, and each quits the screen saver host when the saver stops (a macOS 14+ leak). GPU backgrounds (aurora, nebula, ocean, retro sunset) are Metal fragment shaders compiled at runtime by the system's Metal driver, so building needs no separate Metal toolchain; they draw through a CAMetalLayer at 30 fps, with soft effects rendered at reduced resolution. "Use" in Settings › Screen Savers opens System Settings, switches the chooser to Custom and selects the design through Accessibility.
- **Screen recording** uses ScreenCaptureKit's recording output (HEVC or H.264 `.mov`). Keystivo's own recording controls are excluded from the video, while keystroke and click overlays are recorded.

- **Per-app volume** uses `AudioHardwareCreateProcessTap` (macOS 14.2+) with a private aggregate device. Apps at 100% are never tapped. Audio from shared helper processes is attributed to the responsible app.
- **Trackpad gestures** read raw contacts from the MultitouchSupport framework, loaded dynamically, so the app degrades gracefully if it's missing. macOS's own gestures can't be suppressed; overlaps are reported in Settings.
- **Window focusing** across Spaces uses the same SkyLight SPI as other window managers, with a public API fallback. Windows on other Spaces are listed from the window server.
- **Dock previews** observe the Dock's accessibility tree; the Dock itself is never replaced or modified.
- Private SPIs are resolved with `dlsym` and always have a fallback. They aren't App Store compatible; the planned Mac App Store edition will be a sandboxed build without them.
