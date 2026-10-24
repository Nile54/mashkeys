// Metadata and PCM travel only through Chrome's local native-messaging pipe.
const HOST = 'io.github.nile54.mashkeys';
const sessions = new Set();
const waiting = [];
let nativePort;
let openingOffscreen;

function native(message) {
  if (!nativePort) {
    nativePort = chrome.runtime.connectNative(HOST);
    nativePort.onMessage.addListener(reply => waiting.shift()?.resolve(reply));
    nativePort.onDisconnect.addListener(() => {
      const reason = chrome.runtime.lastError?.message || 'MashKeys disconnected.';
      nativePort = undefined;
      while (waiting.length) waiting.shift().resolve({ok: false, error: reason});
      chrome.runtime.sendMessage({target: 'offscreen', type: 'stop-all'}).catch(() => {});
      for (const tab of sessions) badge(tab, '!', 'Open MashKeys and reconnect this tab.');
      sessions.clear();
    });
  }
  if (waiting.length >= 8) return Promise.resolve({ok: false, busy: true});
  return new Promise(resolve => {
    waiting.push({resolve});
    try { nativePort.postMessage(message); }
    catch (error) { waiting.pop(); resolve({ok: false, error: String(error)}); }
  });
}

function hostname(url) {
  try { return new URL(url).hostname.toLowerCase().replace(/^www\./, ''); }
  catch { return ''; }
}

function excluded(host, list) {
  return list.some(rule => host === rule || host.endsWith('.' + rule));
}

function badge(tabId, text, title) {
  chrome.action.setBadgeText({tabId, text}).catch(() => {});
  chrome.action.setBadgeBackgroundColor({tabId, color: text === 'ON' ? '#087f6a' : '#615464'}).catch(() => {});
  chrome.action.setTitle({tabId, title}).catch(() => {});
}

async function offscreen() {
  if (openingOffscreen) return openingOffscreen;
  openingOffscreen = (async () => {
    const contexts = await chrome.runtime.getContexts({contextTypes: ['OFFSCREEN_DOCUMENT']});
    if (!contexts.length) await chrome.offscreen.createDocument({
      url: 'offscreen.html', reasons: ['USER_MEDIA'],
      justification: 'Analyze explicitly connected music tabs locally and keep their audio audible.'
    });
  })();
  try { await openingOffscreen; } finally { openingOffscreen = undefined; }
}

chrome.action.onClicked.addListener(async tab => {
  if (!tab.id) return;
  if (sessions.has(tab.id)) {
    await chrome.runtime.sendMessage({target: 'offscreen', type: 'stop', tabId: tab.id});
    sessions.delete(tab.id); badge(tab.id, '', 'Connect this music tab to MashKeys');
    return;
  }
  try {
    const config = await native({type: 'hello'});
    if (!config.ok) throw new Error(config.error || 'Open the MashKeys app first.');
    if (!config.isolated) throw new Error('Add a website exclusion in MashKeys Settings to enable isolated browser tabs. Normal system capture already works without this helper.');
    const host = hostname(tab.url);
    if (!host) throw new Error('Open a normal website to connect its audio.');
    if (excluded(host, config.blockedSites || [])) throw new Error('This website is blocked in MashKeys Settings.');
    await offscreen();
    const streamId = await chrome.tabCapture.getMediaStreamId({targetTabId: tab.id});
    const reply = await chrome.runtime.sendMessage({target: 'offscreen', type: 'start', tabId: tab.id, streamId, host});
    if (!reply?.ok) throw new Error(reply?.error || 'Could not connect tab audio.');
    sessions.add(tab.id); badge(tab.id, 'ON', 'MashKeys connected · click to disconnect');
  } catch (error) {
    badge(tab.id, '!', String(error.message || error));
  }
});

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id || message.target !== 'background') return;
  if (message.type === 'pcm') {
    native({type: 'pcm', stream: String(message.tabId), host: message.host,
      rate: message.rate, samples: message.samples, browser: message.browser}).then(reply => {
      if (reply.ok) badge(message.tabId, reply.blocked ? 'OFF' : 'ON',
        reply.blocked ? 'This website is blocked in MashKeys Settings.' : 'MashKeys connected · click to disconnect');
      respond(reply);
    });
    return true;
  }
  if (message.type === 'stopped') {
    sessions.delete(message.tabId); badge(message.tabId, '', 'Connect this music tab to MashKeys');
    native({type: 'stop', stream: String(message.tabId)}).then(respond);
    return true;
  }
});

chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
  if (sessions.has(tabId) && change.url) {
    chrome.runtime.sendMessage({target: 'offscreen', type: 'host', tabId, host: hostname(tab.url)}).catch(() => {});
  }
});
chrome.tabs.onRemoved.addListener(tabId => {
  if (sessions.delete(tabId)) chrome.runtime.sendMessage({target: 'offscreen', type: 'stop', tabId}).catch(() => {});
});
