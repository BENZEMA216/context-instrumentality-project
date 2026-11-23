import { copyFileSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { build } from 'esbuild';

const root = resolve(import.meta.dirname, '..');
const dist = resolve(root, 'dist');
mkdirSync(dist, { recursive: true });

await Promise.all([
  build({
    entryPoints: [resolve(root, 'src/background.ts')],
    bundle: true,
    format: 'esm',
    target: 'chrome120',
    outfile: resolve(dist, 'background.js'),
  }),
  build({
    entryPoints: [resolve(root, 'src/content.ts')],
    bundle: true,
    format: 'iife',
    target: 'chrome120',
    outfile: resolve(dist, 'content.js'),
  }),
  build({
    entryPoints: [resolve(root, 'src/popup.ts')],
    bundle: true,
    format: 'esm',
    target: 'chrome120',
    outfile: resolve(dist, 'popup.js'),
  }),
]);

copyFileSync(resolve(root, 'manifest.json'), resolve(dist, 'manifest.json'));
copyFileSync(resolve(root, 'popup.html'), resolve(dist, 'popup.html'));
console.log('Built Context Hub MV3 extension into dist/');
