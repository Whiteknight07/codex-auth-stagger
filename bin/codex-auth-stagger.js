#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const require = createRequire(import.meta.url);
const rootPackageJsonPath = path.join(__dirname, "..", "package.json");

const packageMap = {
  "linux:x64": "@whiteknight07/codex-auth-stagger-linux-x64",
  "linux:arm64": "@whiteknight07/codex-auth-stagger-linux-arm64",
  "darwin:x64": "@whiteknight07/codex-auth-stagger-darwin-x64",
  "darwin:arm64": "@whiteknight07/codex-auth-stagger-darwin-arm64",
  "win32:x64": "@whiteknight07/codex-auth-stagger-win32-x64",
  "win32:arm64": "@whiteknight07/codex-auth-stagger-win32-arm64"
};

function readRootPackage() {
  try {
    return JSON.parse(fs.readFileSync(rootPackageJsonPath, "utf8"));
  } catch {
    return null;
  }
}

function maybePrintPreviewVersion(argv) {
  if (argv.length !== 1) return false;
  if (argv[0] !== "--version" && argv[0] !== "-V") return false;

  const rootPackage = readRootPackage();
  if (!rootPackage) return false;

  const previewLabel = rootPackage.codexAuthPreviewLabel;
  if (typeof previewLabel !== "string" || previewLabel.length === 0) return false;
  if (typeof rootPackage.version !== "string" || rootPackage.version.length === 0) return false;

  process.stdout.write(`codex-auth-stagger ${rootPackage.version} (preview ${previewLabel})\n`);
  return true;
}

if (maybePrintPreviewVersion(process.argv.slice(2))) {
  process.exit(0);
}

function resolveBinary() {
  const key = `${process.platform}:${process.arch}`;
  const packageName = packageMap[key];
  if (!packageName) {
    console.error(`Unsupported platform: ${process.platform}/${process.arch}`);
    process.exit(1);
  }

  try {
    const packageRoot = path.dirname(require.resolve(`${packageName}/package.json`));
    const binaryName = process.platform === "win32" ? "codex-auth-stagger.exe" : "codex-auth-stagger";
    const binaryPath = path.join(packageRoot, "bin", binaryName);
    if (!fs.existsSync(binaryPath)) {
      console.error(`Missing binary inside ${packageName}: ${binaryPath}`);
      process.exit(1);
    }
    return binaryPath;
  } catch (error) {
    console.error(
      `Missing platform package ${packageName}. Reinstall @whiteknight07/codex-auth-stagger on ${process.platform}/${process.arch}.`
    );
    if (error && error.message) {
      console.error(error.message);
    }
    process.exit(1);
  }
}

const binaryPath = resolveBinary();
const child = spawnSync(binaryPath, process.argv.slice(2), {
  stdio: "inherit"
});

if (child.error) {
  console.error(child.error.message);
  process.exit(1);
}

if (child.signal) {
  process.kill(process.pid, child.signal);
} else {
  process.exit(child.status ?? 1);
}
