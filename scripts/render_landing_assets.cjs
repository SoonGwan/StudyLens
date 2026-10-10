// Render original HTML/vector sources. No generated art is repainted or altered.
const { chromium } = require('../tools/landing/node_modules/playwright-core');
const sharp = require('../tools/landing/node_modules/sharp');
const { join, resolve } = require('node:path');
const { pathToFileURL } = require('node:url');
const root = resolve(__dirname, '..');
(async () => {
  await sharp(join(root, 'brand/lens-poses-master.png')).webp({ quality:90, alphaQuality:100 }).toFile(join(root, 'landing/assets/lens-poses.webp'));
  await sharp(join(root, 'landing/assets/favicon.svg')).resize(32,32).png().toFile(join(root, 'landing/assets/favicon-32.png'));
  await sharp(join(root, 'landing/assets/favicon.svg')).resize(180,180).png().toFile(join(root, 'landing/assets/apple-touch-icon.png'));
  await sharp(join(root, 'brand/app-result.png')).webp({ quality:90 }).toFile(join(root, 'landing/assets/app-result.webp'));
  const browser = await chromium.launch({ executablePath:process.env.STUDYLENS_CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless:true, args:['--allow-file-access-from-files'] });
  try {
    const page = await browser.newPage({ viewport:{ width:1200, height:630 }, deviceScaleFactor:1 });
    await page.goto(pathToFileURL(join(root, 'brand/og-source.html')).href);
    await page.evaluate(() => Promise.all([...document.images].map(image => image.decode())));
    await page.screenshot({ path:join(root,'landing/assets/og-ko.png') });
    console.log('Rendered WebP delivery assets, icons and 1200 × 630 Korean OG card.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode=1; });
