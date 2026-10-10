// Exercise the actual sidecar entry point, not just SelectionCore mocks. In particular,
// SelectedTextService's main-thread precondition catches dispatchMain() regressions.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

if (process.platform !== "darwin") {
  console.log("test-helper: macOS-only sidecar, skipping.");
  process.exit(0);
}

const root = fileURLToPath(new URL("..", import.meta.url));
const binPath = execFileSync("swift", ["build", "-c", "release", "--package-path", join(root, "native"), "--show-bin-path"], { encoding: "utf8" }).trim();
const requests = [
  { id: 1, cmd: "ping" },
  { id: 2, cmd: "unknown" },
  { id: true, cmd: "ping" },
  { id: 1.5, cmd: "ping" },
  { id: 3 },
  "not JSON",
  { id: 4, cmd: "ping" },
];
const input = "\n" + requests.map((request) => typeof request === "string" ? request : JSON.stringify(request)).join("\n") + "\n";
const result = spawnSync(join(binPath, "studylens-helper"), ["serve", "--owner-pid", String(process.pid)], {
  input, encoding: "utf8", timeout: 10_000,
});
assert.ifError(result.error);
assert.equal(result.status, 0, result.stderr);
const replies = result.stdout.trim().split("\n").map((line) => JSON.parse(line));
assert.deepEqual(replies, [
  { id: 1, ok: true },
  { id: 2, ok: false, error: "badRequest" },
  { id: 0, ok: false, error: "badRequest" },
  { id: 0, ok: false, error: "badRequest" },
  { id: 3, ok: false, error: "badRequest" },
  { id: 0, ok: false, error: "badRequest" },
  { id: 4, ok: true },
]);
console.log("test-helper: 7 protocol cases passed; main-thread service startup and EOF exit verified.");
