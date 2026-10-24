import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
let registered;
const packets = [];
class Processor { constructor() { this.port = {postMessage: buffer => packets.push(buffer)}; } }
vm.runInNewContext(fs.readFileSync(path.join(root, 'BrowserExtension/samples.js'), 'utf8'), {
  AudioWorkletProcessor: Processor,
  registerProcessor: (name, processor) => { assert.equal(name, 'mashkeys-samples'); registered = processor; },
  Float32Array,
});
const processor = new registered();
for (let i = 0; i < 4; i++) processor.process([[new Float32Array(128).fill(0.4), new Float32Array(128).fill(0.2)]]);
assert.equal(packets.length, 1);
assert.equal(new Float32Array(packets[0]).length, 512);
assert.ok(Math.abs(new Float32Array(packets[0])[0] - 0.3) < 0.00001);
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'BrowserExtension/manifest.json'), 'utf8'));
assert.ok(manifest.permissions.includes('tabCapture'));
assert.ok(manifest.permissions.includes('nativeMessaging'));
assert.equal(manifest.host_permissions, undefined);
console.log('PASS: 512-frame bounded browser packets, channel mixing, minimal capture permissions');
