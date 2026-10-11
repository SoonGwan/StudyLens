const assert = require('node:assert/strict');
const { resolve, join } = require('node:path');
const { mkdirSync } = require('node:fs');
const { chromium } = require('../tools/landing/node_modules/playwright-core');
const AxeBuilder = require('../tools/landing/node_modules/@axe-core/playwright').default;
const base = process.argv[2] || 'http://127.0.0.1:4182/';
const screenshots = resolve(__dirname, '../docs/landing');
mkdirSync(screenshots, { recursive:true });
const report = name => console.log('PASS ' + name);
(async () => {
  const browser = await chromium.launch({ executablePath:process.env.STUDYLENS_CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless:true });
  try {
    const context = await browser.newContext({ reducedMotion:'reduce' });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    const requests = [];
    page.on('request', request => requests.push(request.url()));
    for (const width of [360,390,520,768,1024,1440]) {
      await page.setViewportSize({ width,height:1000 });
      const response = await page.goto(base);
      assert.equal(response.status(),200);
      await page.evaluate(() => Promise.all([...document.images].map(image => { image.loading='eager'; return image.decode(); })));
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth),false,`Overflow at ${width}`);
      assert.equal(await page.locator('h1').count(),1);
      assert.equal(await page.locator('link[rel="canonical"]').getAttribute('href'),'https://study-lens.no-money-do-you-have-money.com/');
      assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).scrollBehavior),'auto');
      // Check text geometry, including the largest heading, rather than containers alone.
      const badText = await page.evaluate(() => {
        const walker = document.createTreeWalker(document.querySelector('main'),NodeFilter.SHOW_TEXT);
        const bad = [];
        while(walker.nextNode()) {
          if(!walker.currentNode.textContent.trim() || !walker.currentNode.parentElement.checkVisibility()) continue;
          // Code intentionally scrolls within its own terminal/preview.
          if(walker.currentNode.parentElement.closest('pre')) continue;
          const range=document.createRange(); range.selectNodeContents(walker.currentNode);
          for(const rect of range.getClientRects()) if(rect.left < -1 || rect.right > innerWidth+1) bad.push(walker.currentNode.textContent.slice(0,80));
        }
        return bad;
      });
      assert.deepEqual(badText,[],`Clipped text at ${width}`);
      const axe = await new AxeBuilder({ page }).withTags(['wcag2a','wcag2aa','wcag21aa']).analyze();
      if(axe.violations.length) console.log(JSON.stringify(axe.violations.map(item=>({ id:item.id,nodes:item.nodes.map(node=>({ target:node.target,summary:node.failureSummary })) })),null,2));
      assert.deepEqual(axe.violations.map(item=>({id:item.id,nodes:item.nodes.map(node=>node.target)})),[],`Accessibility at ${width}`);
      if(width===360 || width===1440) await page.screenshot({ path:join(screenshots,width===360?'mobile-360.png':'desktop-1440.png'),fullPage:true });
      report(`layout, text geometry, reduced motion, images, axe: ${width}px`);
    }
    await page.keyboard.press('Tab');
    assert.equal(await page.locator(':focus').textContent(),'본문으로 바로가기');
    await page.keyboard.press('Enter');
    assert.equal(await page.evaluate(() => location.hash),'#main');
    report('keyboard skip link');

    await page.locator('[data-mode="image"]').focus();
    await page.keyboard.press('Enter');
    assert.equal(await page.locator('[data-mode="image"]').getAttribute('aria-pressed'),'true');
    assert.equal(await page.locator('.feature').count(),4);
    assert.equal(await page.locator('[data-mode]').count(),4);
    for(const mode of ['text','image','code','captureCode']) {
      const codeMode = mode === 'code' || mode === 'captureCode';
      await page.locator(`[data-mode="${mode}"]`).click();
      assert.equal(await page.locator('#response-preview').isVisible(),false);
      for(let step=1; step<=4; step++) {
        await page.locator('#demo-next').click();
        assert.equal(await page.locator('.demo-steps li[aria-current="step"]').count(),1);
        assert.equal(await page.locator('#response-preview').isVisible(),codeMode ? step===4 : step>=3);
        assert.equal(await page.locator('#clipboard-preview').isVisible(),codeMode && step===3);
        if(mode==='captureCode') {
          assert.equal(await page.locator('#demo-selection').evaluate(node=>node.classList.contains('capture')),step>=2);
          assert.equal(await page.locator('#shortcut-hint').textContent(),'⌘ ⇧ 7');
        }
      }
      if(codeMode) {
        assert.equal(await page.locator('#example-code').isVisible(),true);
        assert.match(await page.locator('#demo-status').textContent(),/직접 ⌘V/);
      }
      await page.locator('#demo-next').dblclick();
      await page.locator('#demo-reset').click();
      assert.equal(await page.locator('#response-preview').isVisible(),false);
      assert.equal(await page.locator('#demo-selection').getAttribute('class'),'selection-area');
      report(`${mode}: full flow, rapid input, reset`);
    }
    await page.evaluate(() => {
      window.copyRequests=[];
      Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:text=>new Promise((resolve,reject)=>window.copyRequests.push({text,resolve,reject}))}});
    });
    await page.locator('[data-mode="text"]').click();
    for(let i=0;i<3;i++) await page.locator('#demo-next').click();
    await page.locator('#copy-example').click();
    await page.locator('[data-mode="image"]').click();
    await page.evaluate(() => window.copyRequests[0].resolve());
    assert.equal(await page.locator('#copy-state').textContent(),'내용을 검토한 뒤 복사하세요.');
    assert.equal(await page.locator('#response-preview').isVisible(),false);
    report('old clipboard completion after switching mode stays invalidated');
    for(let i=0;i<3;i++) await page.locator('#demo-next').click();
    await page.locator('#copy-example').click();
    await page.evaluate(() => window.copyRequests[1].reject(new Error('denied')));
    await page.waitForFunction(() => document.getElementById('copy-state').textContent.includes('직접 선택'));
    await page.locator('#copy-example').click();
    await page.evaluate(() => window.copyRequests[2].resolve());
    await page.waitForFunction(() => document.getElementById('copy-state').textContent.includes('복사했습니다'));
    report('clipboard denial is visible and retry recovers');
    await page.locator('#copy-install').click();
    await page.locator('#copy-install').click();
    await page.evaluate(() => { window.copyRequests[4].resolve(); });
    await page.waitForFunction(() => document.getElementById('install-copy-status').textContent.includes('복사했습니다'));
    await page.evaluate(() => { window.copyRequests[3].reject(new Error('old denial')); });
    assert.equal(await page.locator('#install-copy-status').textContent(),'설치 명령을 복사했습니다.');
    assert.match(await page.evaluate(() => window.copyRequests[4].text),/git clone https:\/\/github.com\/SoonGwan\/StudyLens.git\ncd StudyLens\nbun install\nbun run app:build\nopen src-tauri\/target\/release\/bundle\/dmg/);
    report('repeated install copy: newest result survives old failure');
    await page.locator('[data-mode="captureCode"]').click();
    for(let i=0;i<3;i++) await page.locator('#demo-next').click();
    assert.equal(await page.evaluate(()=>window.copyRequests.length),5,'demo steps never automatically copy to the real clipboard');
    await page.locator('#demo-next').click();
    await page.locator('#copy-example').click();
    assert.equal(await page.evaluate(()=>window.copyRequests[5].text),await page.locator('#example-code').textContent());
    await page.locator('[data-mode="text"]').click();
    await page.evaluate(()=>window.copyRequests[5].resolve());
    assert.equal(await page.locator('#copy-state').textContent(),'내용을 검토한 뒤 복사하세요.');
    report('capture-code copies code only on explicit click; late completion stays invalidated');
    assert.deepEqual(errors,[]);
    assert.deepEqual(requests.filter(url=>new URL(url).origin!==new URL(base).origin),[]);
    report('no page errors or external requests');
    const noJS = await browser.newContext({ javaScriptEnabled:false,viewport:{width:360,height:900} });
    const staticPage=await noJS.newPage();
    await staticPage.goto(base);
    await staticPage.locator('summary').first().click();
    assert.equal(await staticPage.locator('details[open]').count(),1);
    assert.match(await staticPage.locator('noscript').textContent(),/코드만 성공 시 자동 복사/);
    assert.match(await staticPage.locator('noscript').textContent(),/캡처 → 코드는 ⌘⇧7/);
    assert.equal(await staticPage.evaluate(() => document.documentElement.scrollWidth>innerWidth),false);
    assert.equal(await staticPage.locator('a[href="#install"]').first().isVisible(),true);
    await noJS.close();
    await context.close();
    report('JavaScript disabled: content, FAQ, install navigation, no overflow');
  } finally { await browser.close(); report('owned browser contexts closed'); }
})().catch(error=>{ console.error(error);process.exitCode=1; });
