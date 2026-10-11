// Renders the app's real result window (React, built by `bun run build`) with a saved
// example answer. Tauri IPC is stubbed in the page; no AI request, no screen access.
const { chromium } = require('../tools/landing/node_modules/playwright-core');
const { createServer } = require('node:http');
const { readFileSync, existsSync } = require('node:fs');
const { join, resolve, extname, normalize } = require('node:path');

const root = resolve(__dirname, '..');
const dist = join(root, 'dist');
if (!existsSync(join(dist, 'result.html'))) throw new Error('Run `bun run build` first.');
const example = readFileSync(join(root, 'brand/result-example.txt'), 'utf8');

// Same fence split as src-tauri/src/document.rs for this well-formed example.
function blocks(source) {
  const out = [];
  let lines = [], fence = null;
  const flush = (language, closed) => {
    if (!lines.length && language === null) return;
    let text = lines.join('\n') + (closed && lines.length ? '\n' : '');
    if (language !== null || text.trim()) out.push({ id: out.length, text, language, isComplete: language === null || closed });
    lines = [];
  };
  for (const line of source.split('\n')) {
    const m = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence) {
      if (m && m[1][0] === fence.char && m[1].length >= fence.len && !m[2].trim()) { flush(fence.lang, true); fence = null; } else lines.push(line);
    } else if (m) { flush(null, false); fence = { char: m[1][0], len: m[1].length, lang: m[2].trim().split(/\s+/)[0] || '' }; } else lines.push(line);
  }
  flush(fence ? fence.lang : null, false);
  return out;
}

const result = {
  status: 'ready', explanation: example, blocks: blocks(example), capturedImage: null, selectedText: '',
  errorMessage: null, hint: null, copied: false, copiedCodeId: null, quickCopyMessage: null,
  billingLabel: 'Claude 구독 (Claude Code)', progress: null,
};
const settings = { settings: { shortcuts: { capture: 'CommandOrControl+Shift+9', text: 'CommandOrControl+Shift+0', code: 'CommandOrControl+Shift+8' } } };

const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml' };
const server = createServer((req, res) => {
  const path = normalize(join(dist, decodeURIComponent(new URL(req.url, 'http://x').pathname)));
  if (!path.startsWith(dist) || !existsSync(path)) { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'Content-Type': types[extname(path)] || 'application/octet-stream' }).end(readFileSync(path));
});

server.listen(0, '127.0.0.1', async () => {
  const browser = await chromium.launch({ executablePath: process.env.STUDYLENS_CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 720, height: 780 }, deviceScaleFactor: 2, colorScheme: 'light', userAgent: 'Mozilla/5.0 (Macintosh)' });
    await page.addInitScript(({ result, settings }) => {
      let next = 1;
      window.__TAURI_INTERNALS__ = {
        transformCallback: () => next++,
        unregisterCallback: () => {},
        invoke: async (cmd) => ({ get_result: result, get_settings: settings }[cmd] ?? null),
      };
      window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener: () => {} };
    }, { result, settings });
    // A plain window backdrop with traffic lights stands in for macOS vibrancy and chrome.
    await page.goto(`http://127.0.0.1:${server.address().port}/result.html`);
    await page.addStyleTag({ content: `
      body { background: #f6f6f7; }
      .titlebar { position: relative; }
      .titlebar::before { content: ""; position: absolute; left: 18px; top: 50%; width: 12px; height: 12px; margin-top: -6px; border-radius: 50%;
        background: #ff5f57; box-shadow: 20px 0 #febc2e, 40px 0 #28c840; }` });
    await page.waitForSelector('.answer');
    await page.screenshot({ path: join(root, 'brand/app-result.png') });
    console.log('Rendered result window: 1440 × 1560');
  } finally {
    await browser.close();
    server.close();
  }
});
