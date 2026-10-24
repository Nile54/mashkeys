# Privacy and permissions

MashKeys processes audio locally. It does not save, upload or transcribe audio, contact an analytics service, or download a model. Apple’s built-in sound classifier recognizes sound categories rather than words.

## Native app

- **System audio access:** used for the live bass envelope and optional speech detection. The microphone is not opened.
- **Keyboard lighting:** a private Apple framework adjusts the entire built-in backlight. Original settings are snapshotted in this app’s preferences and restored on Stop/Quit. A recovery snapshot covers unexpected exits.
- **Global shortcut:** registers a specific chord with Carbon. No general keyboard-event monitor is installed and other keystrokes are not collected.
- **Login item:** optional and controlled from the menu.
- Preferences store only light state, speech preference, app/domain exclusions, login preference and a temporary brightness recovery snapshot.

## Optional browser helper

Permissions are `activeTab`, `tabCapture`, `tabs`, `offscreen` and `nativeMessaging`. There are no all-site content scripts and no remote server. Tab permission allows the helper to keep track of the selected tab’s hostname after navigation.

Only explicitly connected tab audio is streamed. Its **hostname**, sample rate, tab stream identifier and short PCM packets travel over local IPC. Full URLs, titles, page contents, messages, passwords and browsing history are not sent to MashKeys or to an external service. No audio file is created.

The app checks website/app rules before processing a browser stream. Local IPC uses a socket with owner-only permissions and checks the connecting user’s identity. Packets and stream counts are bounded.

When music lights are paused, system capture stops. A connected browser tab may remain routed through its local AudioContext to preserve playback; incoming packets are discarded until lights are enabled again. Disconnect the tab through the helper to release that capture.

Speech classification is probabilistic and takes a short window. Unknown and stale results do not hold a song hostage; an initial speech pulse or a mixed-content mistake is possible.
