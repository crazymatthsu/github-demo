#!/usr/bin/env node
// render-mermaid.cjs — parse and render every ```mermaid block of a Markdown file in headless Chromium, so a
// broken diagram is caught before GitHub shows it as an error box.
//
// Usage: node render-mermaid.cjs <file.md> [--out <dir>] [--theme default|dark] [--parse-only]
//   --out         write diagram-NN.svg and diagram-NN.png there (default: ./mermaid-out)
//   --theme       Mermaid theme to render with; GitHub uses default (light) and dark (dark mode)
//   --parse-only  only run mermaid.parse(): fast, no images. Runs in Node on jsdom when that package is
//                 installed (no browser at all: the offline check), else in Chromium.
//
// Needs Node 18+ and the npm package `mermaid` (11); rendering also needs `playwright-core` and a Chromium,
// --parse-only needs `jsdom` instead:
//   npm install --no-save --prefix "$TMPDIR/mmd" mermaid@11 playwright-core jsdom
//   NODE_PATH="$TMPDIR/mmd/node_modules" node render-mermaid.cjs .github/workflows/README.md
// Chromium: $CHROMIUM_PATH, else the one Playwright manages (`npx playwright install chromium`).
// Behind a TLS-intercepting proxy, Chromium needs the proxy CA in its NSS store (certutil), never
// --ignore-certificate-errors. Where no Chromium can be installed, --parse-only still proves the syntax;
// widths and layout then stay unchecked.
//
// Output: one line per diagram, "#NN ok <width>x<height> <first line>" or "#NN FAIL <error>".
// Exit codes: 0 all diagrams render · 1 at least one failed · 2 usage or missing dependency.
'use strict';

const fs = require('fs');
const path = require('path');

function usage(code) {
  const lines = fs.readFileSync(__filename, 'utf8').split('\n');
  const text = lines.slice(1, lines.findIndex(l => l.startsWith("'use strict'"))).map(l => l.replace(/^\/\/ ?/, ''));
  (code ? console.error : console.log)(text.join('\n'));
  process.exit(code);
}

const searchPaths = [process.cwd(), __dirname, ...(process.env.NODE_PATH || '').split(path.delimiter).filter(Boolean)];
function tryLoad(name) {
  try {
    return require.resolve(name, { paths: searchPaths });
  } catch {
    return null;
  }
}
function load(name) {
  const found = tryLoad(name);
  if (found) return found;
  console.error(`render-mermaid: npm package '${name}' not found (see --help: npm install --no-save mermaid@11 playwright-core jsdom)`);
  process.exit(2);
}
const firstLine = code => (code.split('\n').find(l => l.trim() && !l.trim().startsWith('%%')) || '').trim();
const errorLines = e => String((e && (e.message || e)) || 'unknown error').split('\n').slice(0, 5).join('\n     ');

// --parse-only without a browser: Mermaid's parser on a jsdom window.
async function parseInNode(blocks, jsdomPath) {
  const { JSDOM } = require(jsdomPath);
  const { pathToFileURL } = require('url');
  const dom = new JSDOM('<!doctype html><html><body></body></html>', { pretendToBeVisual: true });
  for (const key of ['window', 'document', 'navigator', 'DOMParser', 'Element', 'HTMLElement', 'SVGElement', 'Node']) {
    if (!(key in globalThis)) globalThis[key] = key === 'window' ? dom.window : dom.window[key];
  }
  const esm = path.join(path.dirname(load('mermaid/package.json')), 'dist', 'mermaid.core.mjs');
  const mermaid = (await import(pathToFileURL(esm).href)).default;
  mermaid.initialize({ startOnLoad: false, securityLevel: 'strict' });
  let failed = 0;
  for (let i = 0; i < blocks.length; i++) {
    const n = String(i + 1).padStart(2, '0');
    try {
      await mermaid.parse(blocks[i]);
      console.log(`#${n} ok ${firstLine(blocks[i])}`);
    } catch (e) {
      failed++;
      console.log(`#${n} FAIL ${firstLine(blocks[i])}\n     ${errorLines(e)}`);
    }
  }
  console.log(`${blocks.length - failed}/${blocks.length} diagrams parse (Node and jsdom, no browser: widths unchecked)`);
  process.exit(failed ? 1 : 0);
}

const args = process.argv.slice(2);
if (args.includes('-h') || args.includes('--help')) usage(0);
let file = null, out = 'mermaid-out', theme = 'default', parseOnly = false;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--out') out = args[++i];
  else if (a === '--theme') theme = args[++i];
  else if (a === '--parse-only') parseOnly = true;
  else if (!file && !a.startsWith('--')) file = a;
  else { console.error(`render-mermaid: unknown argument '${a}'`); usage(2); }
}
if (!file || !out || !['default', 'dark'].includes(theme)) usage(2);

const md = fs.readFileSync(file, 'utf8');
const blocks = [...md.matchAll(/```mermaid\r?\n([\s\S]*?)```/g)].map(m => m[1]);
if (blocks.length === 0) {
  console.log(`render-mermaid: no mermaid blocks in ${file}`);
  process.exit(0);
}

if (parseOnly && tryLoad('jsdom')) {
  parseInNode(blocks, tryLoad('jsdom')).catch(e => { console.error(`render-mermaid: ${e.message || e}`); process.exit(2); });
  return;
}
const { chromium } = require(load('playwright-core'));
const mermaidJs = path.join(path.dirname(load('mermaid/package.json')), 'dist', 'mermaid.min.js');

(async () => {
  const launch = {};
  if (process.env.CHROMIUM_PATH) launch.executablePath = process.env.CHROMIUM_PATH;
  let browser;
  try {
    browser = await chromium.launch(launch);
  } catch (e) {
    console.error(`render-mermaid: Chromium did not start (${String(e.message || e).split('\n')[0]}).`);
    console.error('  Install one (npx playwright install chromium) or set CHROMIUM_PATH; to check the syntax without a');
    console.error('  browser, install jsdom next to mermaid and run with --parse-only.');
    process.exit(2);
  }
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  const bg = theme === 'dark' ? '#0d1117' : '#ffffff';
  await page.setContent(`<html><body style="background:${bg};margin:0"><div id="out"></div></body></html>`);
  await page.addScriptTag({ path: mermaidJs });
  // useMaxWidth false renders at natural size, which shows how wide GitHub will have to shrink a diagram.
  await page.evaluate(t => mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: t,
    flowchart: { useMaxWidth: false } }), theme);
  if (!parseOnly) fs.mkdirSync(out, { recursive: true });
  let failed = 0;
  for (let i = 0; i < blocks.length; i++) {
    const n = String(i + 1).padStart(2, '0');
    const first = firstLine(blocks[i]);
    const res = await page.evaluate(async ({ code, i, parseOnly }) => {
      try {
        await mermaid.parse(code);
        if (parseOnly) return { ok: true };
        const { svg } = await mermaid.render('m' + i, code);
        document.getElementById('out').innerHTML = `<div id="d${i}" style="display:inline-block;padding:12px">${svg}</div>`;
        return { ok: true, svg };
      } catch (e) {
        return { ok: false, error: String((e && (e.message || e)) || 'unknown error') };
      }
    }, { code: blocks[i], i, parseOnly });
    if (!res.ok) {
      failed++;
      console.log(`#${n} FAIL ${first}\n     ${errorLines(res.error)}`);
      continue;
    }
    if (parseOnly) { console.log(`#${n} ok ${first}`); continue; }
    fs.writeFileSync(path.join(out, `diagram-${n}.svg`), res.svg);
    const el = await page.$(`#d${i}`);
    await el.screenshot({ path: path.join(out, `diagram-${n}.png`) });
    const box = await el.boundingBox();
    const wide = box.width > 1000 ? '  (wider than ~1000px: GitHub will shrink it)' : '';
    console.log(`#${n} ok ${Math.round(box.width)}x${Math.round(box.height)} ${first}${wide}`);
  }
  await browser.close();
  console.log(`${blocks.length - failed}/${blocks.length} diagrams render${parseOnly ? ' (parse only)' : `, images in ${out}`}`);
  process.exit(failed ? 1 : 0);
})().catch(e => { console.error(`render-mermaid: ${e.message || e}`); process.exit(2); });
