# Privacy and permissions

MashKeys processes audio locally. It does not save, upload or transcribe audio, contact an analytics service, or download a model. Apple’s built-in sound classifier recognizes sound categories rather than words.

## Native app

- **System audio access:** used for the selected frequency envelope and optional speech detection. The microphone is not opened.
- **Keyboard lighting:** a private Apple framework adjusts the entire built-in backlight. Original settings are snapshotted in this app’s preferences and restored on Stop/Quit. A recovery snapshot covers unexpected exits.
- **Global shortcut:** registers a specific chord with Carbon. No general keyboard-event monitor is installed and other keystrokes are not collected.
- **Login item:** optional and controlled from the menu.
- Preferences store light state, speech preference, beat source, sensitivity, app exclusions, login preference and a temporary brightness recovery snapshot. Inactive domain choices from older versions may remain saved.

## Browsers

MashKeys uses native system audio capture. It does not install or use a browser extension, read tab URLs, inspect page content or collect browsing history. Websites are handled as part of the browser's audio output. Individual website exclusions are unavailable; whole-app exclusions are supported.

When upgrading from a release with the old browser helper, MashKeys removes only its own obsolete local native-messaging registrations and ignores old website-mode preferences. Old saved domains are not used. An installed copy of the retired extension can be removed from the browser.

Speech classification is probabilistic and takes a short window. Unknown and stale results do not hold a song hostage; an initial speech pulse or a mixed-content mistake is possible.

## Sync to song

Sync uses the same allowed system-audio mix and selected frequency source as the lights. On request, it temporarily holds about eight seconds of derived energy/share measurements in memory. It does not save or upload raw audio, identify a track, or download a model. Measurements are discarded after tuning or cancellation; only the resulting sensitivity is saved. If multiple allowed audio sources play together, the suggestion reflects their mix. Confirmed speech is excluded when speech protection is enabled. Cancelling, changing settings, stopping capture or failing to hear enough rhythm leaves the current sensitivity unchanged.
