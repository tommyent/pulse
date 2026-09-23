#!/usr/bin/env node
// Fake native helper for CodexSessionChecks; no audio devices or network.
const assert = require('node:assert/strict');
let buffer = Buffer.alloc(0), stage = 'hello', controls = 0, dying = false;
function send(message) {
  const body = Buffer.from(JSON.stringify(message));
  const head = Buffer.alloc(4); head.writeUInt32BE(body.length);
  const frame = Buffer.concat([head, body]);
  process.stdout.write(frame.subarray(0, 2));
  setTimeout(() => process.stdout.write(frame.subarray(2)), 15);
}
process.stdin.on('data', chunk => {
  buffer = Buffer.concat([buffer, chunk]);
  while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32BE()) {
    const length = buffer.readUInt32BE();
    const m = JSON.parse(buffer.subarray(4, length + 4));
    buffer = buffer.subarray(length + 4);
    if (m.type === 'hello') {
      assert.equal(stage, 'hello'); assert.equal(m.protocol, 1); assert.equal(m.buildCommit, 'fixture');
      assert.equal(process.env.GST_REGISTRY, '/dev/null');
      stage = 'initializeRuntime'; send({type:'ready'});
    } else if (m.type === 'initializeRuntime') {
      assert.equal(stage, m.type); stage = 'startTransport'; send({type:'runtimeReady'});
    } else if (m.type === 'startTransport') {
      assert.equal(stage, m.type); stage = 'applyAnswer'; send({type:'offer', sdp:'fixture-offer'});
    } else if (m.type === 'applyAnswer') {
      assert.equal(stage, m.type);
      if (m.sdp === 'malformed-frame') { process.stdout.write(Buffer.from([0, 3, 0, 0])); return; }
      if (m.sdp === 'die-after-devices') dying = true; else assert.equal(m.sdp, 'fixture-answer');
      stage = 'openDevices'; send({type:'transportReady'});
    } else if (m.type === 'openDevices') {
      assert.equal(stage, m.type); stage = 'controls'; send({type:'devicesOpened'});
      if (dying) setTimeout(() => {                        // stands in for an audio device changing under the helper
        process.stderr.write('fixture: input stream error, ending session\n');
        process.exit(1);
      }, 40);
    } else if (m.type === 'setAudioControls') {
      assert.equal(stage, 'controls');
      if (controls++ === 0) assert.equal(m.controls.microphoneMuted, true);
      assert.equal(m.controls.speakerSuppressed, false); send({type:'audioControlsApplied'});
    } else if (m.type === 'inspectAudio') {
      assert(controls > 0); send({type:'audioState', state:{microphonePeak:0, speakerPeak:100}});
    } else { throw new Error('unexpected message'); }
  }
});
