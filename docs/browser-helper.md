# Website exclusions without stopping other music

macOS supplies a mixed browser output, not a separate website-labelled audio stream. MashKeys therefore removes the supported browsers from its native capture when website rules are enabled and adds back only the tabs you explicitly connect. A blocked Instagram tab never contributes to the analysis; a connected YouTube tab continues independently.

## Set up once

1. Move MashKeys into `/Applications` before setting up the helper.
2. Open **MashKeys → Settings → Set up browser helper…**. This registers the local native-messaging executable and reveals the included `BrowserExtension` folder in Finder.
3. Open `chrome://extensions`, `edge://extensions`, or `brave://extensions`. Enable **Developer mode**, select **Load unpacked**, and choose that folder. It is inside `MashKeys.app/Contents/Resources/BrowserExtension`.
4. Pin **MashKeys Tab Audio** to the browser toolbar.
5. In MashKeys Settings, check `instagram.com` or add your own domain.
6. Open your music tab and click the pinned MashKeys button. Its badge becomes **ON**. Click again to disconnect.

The helper is shipped as source, not listed in a browser extension store. Chrome must approve capture through your action; it cannot automatically capture every new tab. Developer-mode warnings are expected. Review the source before loading it.

## Rules

- Domains cover subdomains (`instagram.com` also covers `www.instagram.com`). They do not match unrelated suffixes such as `instagram.com.example.org`.
- Connecting a blocked site is refused. If you block a connected tab later, its audio is discarded by the app. Playback is not muted.
- When website rules are enabled, **all unconnected browser tabs are excluded from lighting**, even if their domains are not blocked.
- Native apps remain separate and automatic. Whole-app exclusion overrides a tab connection from that browser.
- Up to four connected tabs per browser bridge are analyzed. PCM packets and processing queues are bounded; overloaded analysis drops input rather than delaying playback.
- Safari and Firefox are not supported by this helper. You can exclude them as whole apps.

If the badge shows **!**, hover over it for the reason. Check that MashKeys is open, the native bridge was registered after moving the app, at least one website rule is active, and the current tab is a normal website. Re-run the setup button after moving MashKeys to another folder.

No network port is opened. Audio travels from the selected tab through Chrome’s native-messaging pipe to a user-only Unix socket on the same Mac. The helper must restore tab playback because `tabCapture` temporarily redirects it; closing a connection releases the stream. It does not intentionally change the source player’s volume.

[Chrome’s tabCapture documentation](https://developer.chrome.com/docs/extensions/reference/api/tabCapture) explains why per-tab user activation is required.
