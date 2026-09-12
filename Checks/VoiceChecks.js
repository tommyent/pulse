// Exercise the actual embedded page without a microphone, network, or provider account.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Sources/Pulse/CodexChat.swift', 'utf8');
const page = source.match(/<script>([\s\S]*?)<\/script>/)[1];
const requests = [], events = [], peers = [];
class Peer {
  constructor() { this.iceGatheringState = 'complete'; peers.push(this); }
  createDataChannel() { return {}; }
  addTrack(track) { this.track = track; }
  async createOffer() { return { sdp: 'test-offer' }; }
  async setLocalDescription(offer) { this.localDescription = offer; }
  close() { this.closed = true; }
}
const context = vm.createContext({
  navigator: { mediaDevices: { getUserMedia: () => new Promise((resolve, reject) => requests.push({ resolve, reject })) } },
  RTCPeerConnection: Peer,
  webkit: { messageHandlers: { pulse: { postMessage: event => events.push(event) } } },
  document: { getElementById: () => ({}) }, setTimeout,
});
vm.runInContext(page, context);
function stream() {
  const track = { enabled: true, stopped: false, stop() { this.stopped = true; } };
  return { track, getTracks: () => [track], getAudioTracks: () => [track] };
}
(async () => {
  const cancelled = context.pulseStart();
  context.pulseStop();
  const late = stream();
  requests.shift().resolve(late);
  await cancelled;
  assert(late.track.stopped, 'permission resolving after Stop must release the microphone');
  assert.equal(peers.length, 0);
  assert.equal(events.length, 0);

  const obsolete = context.pulseStart();
  const current = context.pulseStart(true);
  const oldRequest = requests.shift();
  const active = stream();
  requests.shift().resolve(active);
  await current;
  assert.equal(active.track.enabled, false, 'mute must survive starting a new call');
  oldRequest.reject(new Error('obsolete permission request'));
  await obsolete;
  assert.equal(active.track.stopped, false, 'a stale start must not stop the new call');
  assert.equal(events.length, 1);
  context.pulseMute(false);
  assert(active.track.enabled);
  peers.at(-1).connectionState = 'failed';
  peers.at(-1).onconnectionstatechange();
  assert(active.track.stopped, 'a failed connection must release capture');
  assert(peers.at(-1).closed);
  assert.equal(events.at(-1).kind, 'closed');
  console.log('Voice checks passed: cancelled capture, restart, mute and disconnected cleanup');
})().catch(error => { console.error(error); process.exitCode = 1; });
