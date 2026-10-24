<p align="center"><img src="docs/mark.svg" width="120" alt="MashKeys"></p>

# MashKeys

Music for your MacBook keyboard. Smooth, full-range bass pulses that follow the music’s pace and volume—with live drop accents, local speech filtering, and a global **⌘⌥K** toggle.

**[Download MashKeys](https://github.com/Nile54/mashkeys/releases/latest)** · [Browser helper setup](docs/browser-helper.md) · [Privacy](docs/privacy.md)

**Normal music listening needs no browser extension.** MashKeys captures system audio from all apps and websites automatically. The browser helper is an optional extra only for individual-site exclusions.

MashKeys is a standalone Swift app. It does not require or install another keyboard visualizer, virtual audio driver, Python service, or cloud account.

## Install

1. Download the latest `.dmg`, open it, and drag **MashKeys** into **Applications**.
2. Open MashKeys. Choose **Enable MashKeys** and allow system-audio access when macOS asks.
3. Play music from YouTube, Music, Spotify, Voicemod, or another app. The keyboard icon in the menu bar controls MashKeys.
4. Press **⌘⌥K** from any app to turn the lights on or off. **⌘Q** still quits the foreground app normally.

The public build is ad-hoc signed, **not Apple-notarized**. On first download, macOS may block opening it. After trying to open it, use **System Settings → Privacy & Security → Open Anyway**, only if you trust this project. Do not disable Gatekeeper globally. You can also build from source below. Release assets have SHA-256 checksums.

If audio access was denied, enable MashKeys under **Privacy & Security → Screen & System Audio Recording**, then toggle it on again. The exact pane label varies with macOS.

## How the lights behave

- All keys dip to **0%** and ease back to **100%**. This is a single white backlight, not per-key RGB.
- Faster rhythms recover faster; stronger hits linger longer. The upward fade can last up to about **2.2 seconds**.
- A pronounced bass-energy lift or bass returning after a musical break can interrupt an ordinary pulse.
- Ordinary overlapping hits finish their fade, preventing continuous rapid strobing.
- Audio is measured live in short windows. No song recognition, training pass, replay, or track download is needed.

**Ignore talking** is on by default. Only confident recent speech blocks pulses. Singing and rap remain eligible, and unknown music is allowed immediately. A sound classifier needs roughly half a second of audio to decide: a brief initial speech pulse is possible, and mixed speech/music can be misclassified. This is not a perfect voice separator or an understanding of musical structure.

Stopping or quitting restores your previous brightness, automatic-brightness setting and idle dimming. Start at login is optional in the menu.

## Ignore apps and websites

Open **MashKeys → Settings**.

**Whole apps:** check an app under “Ignore whole apps.” Its audio is removed from MashKeys’ native capture. It is not muted. Helper processes are covered. Changing app rules or starting a newly allowed app may briefly rebuild the filtered capture.

**Websites (optional):** explicitly enable **Website filtering (optional)**, then select a domain such as `instagram.com`. Merely having saved rules does not change normal system capture. This mode uses **strict browser-tab isolation**, not “pause everything while Instagram is open.” Connected YouTube music and native apps can keep driving the keyboard while Instagram is ignored.

This requires the included Chrome/Edge/Brave helper. Chrome requires a user gesture to capture a tab, so click the helper once on each music tab you want connected. While optional website filtering is active, **unconnected browser tabs also do not drive the lights**. Your audio remains audible. Native apps continue automatically. Safari/Firefox website-level isolation is not supported; whole-app exclusion is available instead.

Leave **Website filtering (optional)** off to listen everywhere with no helper, tab connections or extra setup. Speech suppression and whole-app exclusions still work. Saved website rules remain available but inactive. See [the browser helper guide](docs/browser-helper.md) only if you want that optional mode.

## Compatibility

- macOS **14.2 or later**, Apple Silicon or Intel; the download is universal.
- A Mac with a supported built-in, adjustable keyboard backlight.
- Tested on an **M5 MacBook Pro running macOS 27**. Other models and OS versions are not exhaustively hardware-tested.
- External RGB keyboards, Magic Keyboard lighting, and individually addressed keys are not supported.

Keyboard brightness uses Apple’s **private CoreBrightness framework** because there is no public per-frame backlight API. A macOS update may change it. Unsupported hardware reports an error instead of pretending that LEDs changed.

## Build and test

Install Apple’s Command Line Tools (`xcode-select --install`), then:

```sh
git clone https://github.com/Nile54/mashkeys.git
cd mashkeys
./scripts/test.sh
./scripts/build.sh
open .build/MashKeys.app
```

`build.sh` builds both CPU architectures, generates the original icon, bundles the browser helper and signs the app ad hoc. To use your own signing certificate, set `CODESIGN_IDENTITY`. No signing credentials are included in this repository. `./scripts/package.sh` creates the DMG, ZIP and checksums in `dist/`.

Tests generate their own signals; no user song or captured audio is distributed. They cover first-play bass response, smooth full-depth recovery, tempo/volume adaptation, live drop accents, gain changes, irregular audio buffers, speech decision policy, site rules, the local browser bridge and packet mixing. CI builds the universal app. Automated tests do **not** prove optical LED timing or compatibility with every Mac.

For an additional local classifier check, run `./scripts/test-audio.sh spoken-44100.wav music-44100.wav` with your own 44.1 kHz files. This analyzes them without playing, recording, or uploading them.

## Source map

| Component | Purpose |
| --- | --- |
| `Core.swift` | Live bass, drop contrast, adaptive rise and speech policy |
| `BassSpectrum.swift` | Reusable 2048-point FFT, advanced every 256 samples |
| `AudioTap.swift` | System capture, allowed-process mixes and output-device changes |
| `SpeechGuard.swift` | Bounded, on-device SoundAnalysis worker |
| `KeyboardBacklight.swift` / `LightAnimator.swift` | Hardware snapshots, immediate writes and smooth recovery |
| `BrowserBridge.swift` / `BrowserExtension/` | Independent, explicitly connected browser-tab audio |
| `Rules.swift` / `SettingsWindow.swift` | App and domain exclusions |
| `GlobalShortcut.swift` | Carbon registration of ⌘⌥K, without keystroke monitoring |

Audio capture uses [Apple’s CoreAudio process taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps); speech checks use [SoundAnalysis](https://developer.apple.com/documentation/soundanalysis). Browser isolation follows [Chrome’s tabCapture permission model](https://developer.chrome.com/docs/extensions/reference/api/tabCapture).

MIT licensed. Built by Nilesh Nandakumar.
