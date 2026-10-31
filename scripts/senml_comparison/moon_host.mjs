import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const bridge = require('../../_build/js/release/build/examples/comparison/comparison.js');
const requests = JSON.parse(readFileSync(0, 'utf8'));
process.stdout.write(JSON.stringify(requests.map(({ payload, format, now }) =>
  JSON.parse(bridge.compare_payload(payload, format, now)))));
