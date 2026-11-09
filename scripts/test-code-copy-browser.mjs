// With Vite on 127.0.0.1:15440 and Rust's opt-in snapshot output in /tmp:
// ego-browser nodejs < scripts/test-code-copy-browser.mjs
const assert = (await import("node:assert/strict")).default;
const { readFile } = await import("node:fs/promises");
const records = JSON.parse(await readFile("/tmp/studylens-code-copy-snapshots.json", "utf8"));
assert.equal(records.length, 37);
const task = await taskSpace("StudyLens issue verification");
const page = task.page("p1");
await page.goto("http://127.0.0.1:15440/tests/browser/code-copy.html");
await page.waitForFunction(() => !!window.copyQa);

for (const record of records) {
  const { fixture, blocks } = record;
  await page.evaluate((value) => window.copyQa.mount(value), record);
  await page.waitForFunction((name) => document.querySelector(`[data-fixture="${name}"] .window`), fixture.name);
  const shown = await page.evaluate(() => ({
    texts: [...document.querySelectorAll(".code pre")].map((pre) => pre.textContent),
    enabled: [...document.querySelectorAll(".code-head button")].map((button) => !button.disabled),
    quick: [...document.querySelectorAll("footer button")].find((b) => b.textContent === "코드만 복사")?.disabled ?? null,
  }));
  assert.deepEqual(shown.texts, fixture.codeBlocks.map((b) => b.text), fixture.name);
  const allowed = fixture.codeBlocks.map((b) => b.isComplete && b.text.trim().length > 0);
  assert.deepEqual(shown.enabled, allowed, fixture.name);
  assert.equal(shown.quick, allowed.length === 1 ? !allowed[0] : null, fixture.name);

  await page.click('loc=role:button[name="전체 복사"]');
  assert.deepEqual(await page.evaluate(() => window.copyQa.commands.map((c) => c.command)), ["copy_explanation"], fixture.name);
  const expectedIds = [];
  const code = blocks.filter((b) => b.language !== null);
  for (let i = 0; i < code.length; i++) {
    if (!allowed[i]) continue;
    await page.click(`.code:nth-of-type(${i + 1}) .code-head button`);
    expectedIds.push(code[i].id);
  }
  if (allowed.length === 1 && allowed[0]) {
    await page.click('loc=role:button[name="코드만 복사"]');
    expectedIds.push(code[0].id);
  }
  assert.deepEqual(await page.evaluate(() => window.copyQa.commands.filter((c) => c.command === "copy_code").map((c) => c.payload.id)), expectedIds, fixture.name);
}
console.log("37 Swift fixtures passed in the actual React result window: exact text, copy command IDs, empty/incomplete disabled buttons and multiple-block handling.");
console.log(await page.snapshot());
