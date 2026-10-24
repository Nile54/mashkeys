const streams = new Map();

async function browserBundle() {
  if (navigator.userAgent.includes('Edg/')) return 'com.microsoft.edgemac';
  if (await navigator.brave?.isBrave?.()) return 'com.brave.Browser';
  return 'com.google.Chrome';
}

function base64(buffer) {
  return btoa(String.fromCharCode(...new Uint8Array(buffer)));
}

async function stop(tabId) {
  const session = streams.get(tabId);
  if (!session) return;
  streams.delete(tabId);
  session.worklet.port.onmessage = null;
  session.media.getTracks().forEach(track => track.stop());
  await session.audio.close();
  chrome.runtime.sendMessage({target: 'background', type: 'stopped', tabId}).catch(() => {});
}

async function start(message) {
  await stop(message.tabId);
  const media = await navigator.mediaDevices.getUserMedia({audio: {mandatory: {
    chromeMediaSource: 'tab', chromeMediaSourceId: message.streamId
  }}, video: false});
  const audio = new AudioContext({latencyHint: 'interactive'});
  try {
    await audio.audioWorklet.addModule('samples.js');
    const source = audio.createMediaStreamSource(media);
    const worklet = new AudioWorkletNode(audio, 'mashkeys-samples');
    const quiet = audio.createGain(); quiet.gain.value = 0;
    // tabCapture suppresses the original output; this branch preserves listening.
    source.connect(audio.destination);
    source.connect(worklet).connect(quiet).connect(audio.destination);
    const session = {audio, media, worklet, host: message.host, busy: false, browser: await browserBundle()};
    streams.set(message.tabId, session);
    worklet.port.onmessage = async event => {
      if (session.busy || !streams.has(message.tabId)) return; // bounded backpressure, never delay playback
      session.busy = true;
      try {
        const reply = await chrome.runtime.sendMessage({target: 'background', type: 'pcm', tabId: message.tabId,
          host: session.host, rate: audio.sampleRate, samples: base64(event.data), browser: session.browser});
        if (reply?.released || reply?.isolated === false || (reply?.error && !reply?.busy)) await stop(message.tabId);
      } catch { await stop(message.tabId); }
      finally { session.busy = false; }
    };
    media.getAudioTracks()[0]?.addEventListener('ended', () => stop(message.tabId));
    await audio.resume();
  } catch (error) {
    media.getTracks().forEach(track => track.stop()); await audio.close(); throw error;
  }
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id || message.target !== 'offscreen') return;
  if (message.type === 'start') {
    start(message).then(() => respond({ok: true})).catch(error => respond({ok: false, error: String(error.message || error)}));
    return true;
  }
  if (message.type === 'stop') { stop(message.tabId).then(() => respond({ok: true})); return true; }
  if (message.type === 'stop-all') { Promise.all([...streams.keys()].map(stop)).then(() => respond({ok: true})); return true; }
  if (message.type === 'host') {
    if (!message.host || !message.host.includes('.')) { stop(message.tabId).then(() => respond({ok: true})); return true; }
    const session = streams.get(message.tabId); if (session) session.host = message.host; respond({ok: true});
  }
});
