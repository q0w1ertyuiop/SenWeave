import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { homedir } from 'node:os';

const root = fileURLToPath(new URL('../', import.meta.url));
const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const moon = readFileSync(join(root, 'moon.mod'), 'utf8');
if (!moon.includes(`version = "${manifest.version}"`)) throw new Error('MoonBit and npm versions differ');
const built = spawnSync('moon', ['build', 'cmd/bridge', '--target', 'js', '--release', '--deny-warn'], { cwd: root, stdio: 'inherit' });
if (built.error) throw built.error;
if (built.status !== 0) process.exit(built.status ?? 1);
const code = readFileSync(join(root, '_build/js/release/build/cmd/bridge/bridge.js'), 'utf8');
mkdirSync(join(root, 'dist'), { recursive: true });
writeFileSync(join(root, 'dist/bridge.cjs'), `// SenWeave ${manifest.version} · Apache-2.0 · compiled from MoonBit\n${code}`);
const declarations = readFileSync(join(root, 'js/index.d.ts'));
for (const name of ['index.d.mts', 'index.d.cts']) writeFileSync(join(root, 'dist', name), declarations);
const toolchain = process.env.MOON_HOME ?? join(homedir(), '.moon');
const notices = join(root, 'dist/third-party');
mkdirSync(notices, { recursive: true });
for (const [source, target] of [
  [join(toolchain, 'lib/core/LICENSE'), 'core-LICENSE.txt'],
  [join(toolchain, 'lib/core/NOTICE'), 'core-NOTICE.txt'],
  [join(root, '.mooncakes/2515050242/cbor/LICENSE'), 'cbor-LICENSE.txt'],
]) writeFileSync(join(notices, target), readFileSync(source));
console.log(`Built SDK ${manifest.version}`);
