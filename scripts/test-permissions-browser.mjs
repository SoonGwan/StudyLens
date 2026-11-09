// Start Vite on 127.0.0.1:15439, then run:
// ego-browser nodejs < scripts/test-permissions-browser.mjs
// This runner uses Ego's taskSpace API, not the standalone Node runtime.
const assert = (await import("node:assert/strict")).default;
const task = await taskSpace("StudyLens issue verification");
const page = task.page("p1");
await page.goto("http://127.0.0.1:15439/tests/browser/permissions.html");
await page.waitForFunction(() => window.permissionQa?.requests.length === 1);
// Give the browser real focus before controlling deferred responses. The act of
// focusing the page itself legitimately triggers another permission refresh.
await page.click("h2");
await page.evaluate(() => {
  window.permissionQa.requests = [];
  window.dispatchEvent(new Event("focus"));
});
const state = () => page.evaluate(() => ({
  message: document.querySelector('[role="status"]').textContent.trim(),
  denied: document.querySelectorAll(".warn").length,
  granted: document.querySelectorAll(".ok").length,
  checking: [...document.querySelectorAll("span")].filter((el) => el.textContent === "확인 중…").length,
  retryDisabled: document.querySelector("button").disabled,
}));

assert.deepEqual(await state(), {
  message: "권한 상태를 확인하고 있습니다.", denied: 0, granted: 0, checking: 2, retryDisabled: true,
});
await page.evaluate(() => window.permissionQa.requests[0].reject(new Error("simulated IPC failure")));
await page.waitForFunction(() => document.querySelector('[role="status"]').textContent.includes("불러오지 못했습니다"));
assert.equal((await state()).denied, 0);
assert.equal((await state()).retryDisabled, false);

await page.click('loc=role:button[name="다시 확인"]');
await page.waitForFunction(() => window.permissionQa.requests.length === 2);
await page.evaluate(() => window.permissionQa.requests[1].resolve({ accessibility: false, screenRecording: true }));
await page.waitForFunction(() => document.querySelectorAll(".ok").length === 1);
assert.equal((await state()).denied, 1);

// Focus refreshes can overlap. A failed older response must not erase a new success.
await page.evaluate(() => {
  window.dispatchEvent(new Event("focus"));
  window.dispatchEvent(new Event("focus"));
});
await page.waitForFunction(() => window.permissionQa.requests.length === 4);
await page.evaluate(() => window.permissionQa.requests[3].resolve({ accessibility: true, screenRecording: true }));
await page.waitForFunction(() => document.querySelectorAll(".ok").length === 2);
await page.evaluate(async () => {
  window.permissionQa.requests[2].reject(new Error("stale failure"));
  await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
});
assert.equal((await state()).granted, 2);
assert.equal((await state()).denied, 0);

// An unavailable OS query is not a denial, and manual retry still recovers.
await page.evaluate(() => window.dispatchEvent(new Event("focus")));
await page.waitForFunction(() => window.permissionQa.requests.length === 5);
await page.evaluate(() => window.permissionQa.requests[4].resolve(null));
await page.waitForFunction(() => document.querySelector('[role="status"]').textContent.includes("이 환경에서는"));
assert.equal((await state()).denied, 0);
await page.click('loc=role:button[name="다시 확인"]');
await page.waitForFunction(() => window.permissionQa.requests.length === 6);
await page.evaluate(() => window.permissionQa.requests[5].resolve({ accessibility: true, screenRecording: false }));
await page.waitForFunction(() => document.querySelectorAll(".warn").length === 1);
assert.equal((await state()).granted, 1);
await page.evaluate(() => {
  window.dispatchEvent(new Event("focus"));
  window.dispatchEvent(new Event("focus"));
});
await page.waitForFunction(() => window.permissionQa.requests.length === 8);
await page.evaluate(() => window.permissionQa.requests[7].resolve({ accessibility: true, screenRecording: false }));
await page.waitForFunction(() => document.querySelectorAll(".ok").length === 1);
await page.evaluate(async () => {
  window.permissionQa.requests[6].resolve({ accessibility: false, screenRecording: false });
  await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
});
assert.equal((await state()).granted, 1);
assert.equal((await state()).denied, 1);
await page.click('.row:nth-of-type(2) button');
await page.click('.row:nth-of-type(3) button');
assert.deepEqual(await page.evaluate(() => window.permissionQa.opened), ["accessibility", "screen"]);
console.log("Permission browser regression passed: loading, failure, retry, mixed grants, focus refresh, stale failure/success, unavailable query, recovery and settings links.");
console.log(await page.snapshot());
console.log({ screenshot: await page.screenshot({ path: "/tmp/studylens-permissions-qa.png" }) });
// The parent goal remains active; reuse this TaskSpace for subsequent browser checks.
