#!/usr/bin/env node
// Fetches the signed `sundown` binary for this Mac, checks it, and runs it.
//
// There is no postinstall step on purpose: `npx sundown-cli` should be a way
// to try the tool once without leaving anything behind, and a postinstall that
// downloads a binary is the thing people rightly disable. The download happens
// on first run, into a versioned cache, and every later run is a spawn.
//
// The checksum is not optional. This script executes what it downloads, so an
// unverified download is a supply chain with one link and no lock on it. A
// build with no recorded checksum refuses and points at Homebrew rather than
// running something it cannot vouch for.

const { createHash } = require("node:crypto");
const { execFileSync, spawnSync } = require("node:child_process");
const { mkdtempSync, mkdirSync, existsSync, readFileSync, renameSync } = require("node:fs");
const { tmpdir, homedir, arch, platform } = require("node:os");
const { join } = require("node:path");

const pkg = require("../package.json");
const REPO = "https://github.com/Zu9zwan9/sundown";

function fail(...lines) {
  for (const line of lines) console.error(line);
  process.exit(1);
}

if (platform() !== "darwin") {
  fail(
    "sundown reads the macOS process table and only runs on macOS.",
    "A Linux port needs one file — see " + REPO + "#where-to-take-it-next"
  );
}

const target = arch() === "arm64" ? "arm64" : "x64";
const expected = (pkg.checksums || {})[target] || "";
if (!expected || expected.startsWith("REPLACE_")) {
  fail(
    "This build of sundown-cli has no recorded checksum for " + target + ",",
    "so there is nothing to verify the download against and it will not run one.",
    "",
    "Install from Homebrew instead:  brew install Zu9zwan9/sundown/sundown"
  );
}

const cache = join(homedir(), ".cache", "sundown-cli", pkg.version);
const binary = join(cache, "sundown");

if (!existsSync(binary)) {
  const url = `${REPO}/releases/download/v${pkg.version}/sundown-macos-${target}.tar.gz`;
  const scratch = mkdtempSync(join(tmpdir(), "sundown-"));
  const tarball = join(scratch, "sundown.tar.gz");

  process.stderr.write(`sundown: fetching ${pkg.version} for ${target}…\n`);
  const download = spawnSync("curl", ["-fsSL", url, "-o", tarball], { stdio: "inherit" });
  if (download.status !== 0) {
    fail(
      "sundown: could not download " + url,
      "Homebrew is the other way in:  brew install Zu9zwan9/sundown/sundown"
    );
  }

  const actual = createHash("sha256").update(readFileSync(tarball)).digest("hex");
  if (actual !== expected) {
    fail(
      "sundown: checksum mismatch — refusing to run the download.",
      "  expected " + expected,
      "  got      " + actual
    );
  }

  mkdirSync(cache, { recursive: true });
  execFileSync("tar", ["-xzf", tarball, "-C", scratch]);
  renameSync(join(scratch, "sundown"), binary);
}

const run = spawnSync(binary, process.argv.slice(2), { stdio: "inherit" });
process.exit(run.status === null ? 1 : run.status);
