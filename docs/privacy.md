# Privacy and permissions

MashKeys processes audio locally. It does not save, upload or transcribe audio, contact an analytics service, or download a model. Apple’s built-in sound classifier recognizes sound categories rather than words.

## Native app

- **System audio access:** used for the live bass envelope and optional speech detection. The microphone is not opened.
- **Keyboard lighting:** a private Apple framework adjusts the entire built-in backlight. Original settings are snapshotted in this app’s preferences and restored on Stop/Quit. A recovery snapshot covers unexpected exits.
- **Global shortcut:** registers a specific chord with Carbon. No general keyboard-event monitor is installed and other keystrokes are not collected.
- **Login item:** optional and controlled from the menu.
- Preferences store only light state, speech preference, app/domain exclusions, login preference and a temporary brightness recovery snapshot.

## Browsers

MashKeys uses native system audio capture. It does not install or use a browser extension, read tab URLs, inspect page content or collect browsing history. Websites are handled as part of the browser's audio output. Individual website exclusions are unavailable; whole-app exclusions are supported.

When upgrading from a release with the old browser helper, MashKeys removes only its own obsolete local native-messaging registrations and ignores old website-mode preferences. Old saved domains are not used. An installed copy of the retired extension can be removed from the browser.

Speech classification is probabilistic and takes a short window. Unknown and stale results do not hold a song hostage; an initial speech pulse or a mixed-content mistake is possible.
