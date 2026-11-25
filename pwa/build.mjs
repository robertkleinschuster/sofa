// Builds the PWA into dist/ (GitHub Pages): esbuild (wasm - runs on every CI and on the 10.9 Mac
// alike) bundles src/main.ts with hls.js split into its own chunk, loaded only when a video plays;
// static files, the brands' logos (res/logos) and the icon are copied; the service worker gets the
// build's id and the list of shell files to cache.

import * as esbuild from 'esbuild-wasm';
import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..');
const out = join(here, 'dist');

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

cpSync(join(here, 'static'), out, { recursive: true });
cpSync(join(repo, 'res/icon/sofa-icon.svg'), join(out, 'icons/icon.svg'));
mkdirSync(join(out, 'logos/marks'), { recursive: true });
for (const f of readdirSync(join(repo, 'res/logos'))) if (f.endsWith('.png')) cpSync(join(repo, 'res/logos', f), join(out, 'logos', f));
const marks = readdirSync(join(repo, 'res/logos/marks')).filter((f) => f.endsWith('.png'));
for (const f of marks) cpSync(join(repo, 'res/logos/marks', f), join(out, 'logos/marks', f));

const common = { bundle: true, minify: true, target: ['es2020', 'safari15'], legalComments: 'linked', logLevel: 'warning' };

await esbuild.build({
  ...common,
  entryPoints: { app: join(here, 'src/main.ts') },
  outdir: out, format: 'esm', splitting: true, chunkNames: 'chunks/[name]-[hash]', sourcemap: true,
  define: { __SOFA_MARKS__: JSON.stringify(marks.map((f) => f.replace(/\.png$/, ''))) },
});

// every file of the shell, and the build's id from their contents
const files = [];
const walk = (d) => { for (const f of readdirSync(d)) { const p = join(d, f); if (statSync(p).isDirectory()) walk(p); else files.push(p); } };
walk(out);
const shell = files.map((p) => relative(out, p)).filter((p) => !p.endsWith('.map') && !p.endsWith('.LEGAL.txt')).sort();
const hash = createHash('sha256');
for (const p of shell) hash.update(p).update(readFileSync(join(out, p)));
const build = hash.digest('hex').slice(0, 12);

await esbuild.build({
  ...common,
  entryPoints: { sw: join(here, 'src/sw.ts') },
  outdir: out, format: 'iife',
  define: { __SOFA_BUILD__: JSON.stringify(build), __SOFA_SHELL__: JSON.stringify(['./', ...shell.filter((p) => p !== 'index.html')]) },
});
writeFileSync(join(out, '.nojekyll'), '');
console.log(`pwa: built ${build} (${shell.length} files) into ${relative(repo, out)}`);
