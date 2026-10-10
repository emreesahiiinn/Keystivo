# Keystivo

A native macOS productivity app that brings a launcher, an advanced window switcher, window management, Homerow-style keyboard navigation, a per-app audio mixer, trackpad and mouse gestures, automation workflows, clipboard history and snippets together in one app, built on one shared action system.

Swift 6 · SwiftUI + AppKit · macOS 15+ · 12 languages · Liquid Glass on macOS 26+

## Features

| Area | What's included |
| --- | --- |
| **App & window switching** | ⌘⇥ replacement (optional, on by default) or ⌥⇥, with live ScreenCaptureKit previews. Pick individual windows of the same app (\`), jump back to the previous window (⌥\`), search windows by title in the launcher, filter by app group (G), and order by focus history. |
| **Dock & windows** | Window previews when hovering Dock icons; click to focus that exact window. Alternative launcher bar on any screen edge (pinned and running apps, auto-hide). Halves, thirds, quarters, sixths, center, maximize, ½→⅔→⅓ cycling, gaps. Move windows between displays, resize and nudge, undo. Save and restore desktop layouts per display set, restored automatically when those monitors reconnect. |
| **Per-app audio** | Volume (0–150%) and mute per app using Core Audio process taps, with no driver. Live meters, quick mixer (⌃⌥M), output/input device switching, mic mute, volume shortcuts, reusable audio profiles. |
| **Keyboard navigation** | Global command palette (⌥Space). Letter hints on clickable elements (⌘⇧Space) with right-click, ⌘-click, double-click and hover modifiers. Element search (⇥). Keyboard scrolling (⌘⇧J, j/k/d/u/g/G). Custom global and app-specific shortcuts. Command chains. |
| **Trackpad & mouse** | Multi-finger taps, double taps, swipes and tip-taps. Mouse stroke gestures with an on-screen trail. Per-app gesture profiles (app-specific beats global). Gesture and shortcut conflict detection against macOS's own shortcuts and trackpad settings. |
| **Automation** | Trigger → condition → action engine. Triggers: app opened/quit/activated, schedule, interval, wake/sleep, lock, displays, power source, battery, audio device, keyboard/mouse connected, profile, focus, shortcut. Nested if/otherwise steps, delays, sub-workflows, run history, template library, `.keystivoflow` sharing. |
| **Clipboard & search** | SQLite-backed clipboard history (text, rich text, links, images, files, colors) with search, pinning, privacy filters (password managers, nspasteboard.org markers) and retention. Snippets with keyword expansion and `{date}`, `{clipboard}`, `{cursor}` placeholders. Spotlight file search. Calculator and offline unit conversion (`10 km to mi`, `3,5 kg kaç lb`). Quick actions for apps, files and text (case, slug, Base64, JSON, hashes…). |
| **Workspaces** | Work and personal profiles that switch audio, power, layout, input source and apps. Multi-monitor layouts. Window stacking (grid, cascade, main + stack, columns, rows). Window history. Default window position per app. Focus mode that hides or blocks distracting apps, dims the background and runs a Shortcut to enable a macOS Focus. |
| **System control** | Menu bar control center. Battery info, keep-awake and power profiles (applied automatically on AC or battery). Microphone control. Per-app and per-device keyboard input-source profiles. Quick commands (lock, sleep displays, dark mode, hidden files, eject, empty trash…). |
| **Utilities (paid-app replacements)** | Drag-to-snap with live preview (Magnet, BetterSnapTool). Menu bar icon hiding (Bartender, Hidden Bar). Mouse-only scroll direction, speed and smooth scrolling, side buttons as back/forward (Mos, SteerMouse). Hyper key and per-keyboard key remapping via `hidutil` (Hyperkey, Karabiner basics). OCR and QR from any screen area (TextSniper). Color picker (Sip). Screenshot annotation editor with arrows, shapes, pen, highlighter, text, numbered steps, pixelation and crop, plus pinned screenshots (CleanShot, Shottr). Screen recording of an area or a display with system audio and microphone (CleanShot, Kap). CPU/memory/network/disk in the menu bar (iStat Menus, Stats). App uninstaller with leftover detection (AppCleaner). Folder rules (Hazel). Drag-and-drop shelf (Yoink, Dropover). Browser routing with rules and tracking-parameter removal (Velja, Choosy). Keystroke, click and cursor overlays (KeyCastr, Presentify). Hardware brightness for external monitors over DDC/CI, brightness keys for the display under the pointer, resolution switcher and software dimming as a fallback (MonitorControl, BetterDisplay basics). Battery charge limit with sailing range, discharge to the limit and a one-time top-up (AlDente). On-device translation. Finder extras (new file here, open terminal or editor here, copy path). |
| **Platform** | User profiles, sectioned import/export with automatic backups, script plugin architecture with trust, a permissions and error center with conflict and resource reports, and event-driven design throughout. |

## Architecture

```
Keystivo.xcodeproj          Thin app target: @main, Info.plist, entitlements, assets
Helper/                     Privileged charging helper (launchd daemon, XPC)
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
├── CSMC, KeystivoHelperCore  SMC access, charge-control schemes, XPC protocol, charge-limit policy
└── KeystivoApp             Composition root (runtime, configuration) and all UI
```

**One action system.** Everything Keystivo can do is an `ActionDescriptor` registered with `ActionRegistry`. Shortcuts, gestures, the launcher, workflows, profiles, device profiles and plugins all run the same `ActionInvocation`s. That makes command chains and automation possible without special cases.

**Event-driven, low overhead.** There's one shared `CGEventTap`, and its event mask is recomputed from what features need right now, so with snippets, mouse gestures and ⌘⇥ takeover off, no keyboard events are delivered. The multitouch engine, audio taps and thumbnails start only when used. AX observers, Core Audio listeners, IOKit power notifications and workspace notifications replace polling. The only timer-based checks are the clipboard change counter (macOS offers no notification) and a short-lived permission watcher.

**Configuration.** Everything is in one JSON document (`~/Library/Application Support/Keystivo/configuration.json`) that is decoded tolerantly (deep-merged onto defaults), saved atomically with debouncing, and backed up before imports, restores and resets. Clipboard history lives separately in SQLite and is never exported.

## Building

Requires Xcode 26 or later (developed with Xcode 27, Swift 6.4).

```bash
make run        # build Debug and launch
make test       # unit tests for every module (Swift Testing)
make l10n-check # every string used in code exists in every language
```

Or open `Keystivo.xcodeproj` and run the **Keystivo** scheme.

### Signing and permissions

Keystivo needs **Accessibility** (window control, keyboard navigation, gestures, ⌘⇥ takeover). **Screen Recording** (live previews, screen recordings), **System Audio** (per-app volume) and **Microphone** (recordings with your voice) are optional. The app can't be sandboxed; distribute it with Developer ID.

Debug builds are ad-hoc signed with a designated requirement on the bundle identifier, so privacy grants survive rebuilds. To sign with your team, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`.

If an older build already appears in *System Settings › Privacy & Security* but Keystivo still reports "not granted", remove the entry with **−** and grant access again.

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
- **Screen recording** uses ScreenCaptureKit's recording output (HEVC or H.264 `.mov`). Keystivo's own recording controls are excluded from the video, while keystroke and click overlays are recorded.

- **Per-app volume** uses `AudioHardwareCreateProcessTap` (macOS 14.2+) with a private aggregate device. Apps at 100% are never tapped. Audio from shared helper processes is attributed to the responsible app.
- **Trackpad gestures** read raw contacts from the MultitouchSupport framework, loaded dynamically, so the app degrades gracefully if it's missing. macOS's own gestures can't be suppressed; overlaps are reported in Settings.
- **Window focusing** across Spaces uses the same SkyLight SPI as other window managers, with a public API fallback. Windows on other Spaces are listed from the window server.
- **Dock previews** observe the Dock's accessibility tree; the Dock itself is never replaced or modified.
- Private SPIs are resolved with `dlsym` and always have a fallback. They aren't App Store compatible, which Keystivo doesn't target.
