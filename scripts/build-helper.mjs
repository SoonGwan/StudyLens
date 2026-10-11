// Builds the macOS selection helper and places it where Tauri expects a sidecar:
// src-tauri/binaries/studylens-helper-<target triple>.
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

if (process.platform !== "darwin") {
  console.log("build-helper: not macOS, skipping (Windows reads selections in-process).");
  process.exit(0);
}

const root = new URL("..", import.meta.url).pathname;
const triple = execFileSync("rustc", ["--print", "host-tuple"], { encoding: "utf8" }).trim();
const packagePath = join(root, "native");
execFileSync("swift", ["build", "-c", "release", "--package-path", packagePath], { stdio: "inherit" });
const binPath = execFileSync("swift", ["build", "-c", "release", "--package-path", packagePath, "--show-bin-path"], { encoding: "utf8" }).trim();
const target = join(root, "src-tauri", "binaries", `studylens-helper-${triple}`);
mkdirSync(join(root, "src-tauri", "binaries"), { recursive: true });
copyFileSync(join(binPath, "studylens-helper"), target);
console.log(`build-helper: ${target}`);
