#!/usr/bin/env node
"use strict";

import {
  readFileSync,
  mkdirSync,
  writeFileSync,
  readdirSync,
  existsSync,
} from "fs";
import { dirname, join, basename, isAbsolute, resolve } from "path";
import { fileURLToPath } from "url";
import { execFileSync, spawn } from "child_process";
import { parse } from "yaml";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

function abs(p) {
  return isAbsolute(p) ? p : resolve(__dirname, p);
}

const SERVICES_ROOT = process.env.SERVICES_ROOT
  ? abs(process.env.SERVICES_ROOT)
  : abs("../services");

const STATE_FILE = process.env.STATE_FILE
  ? abs(process.env.STATE_FILE)
  : abs("./state.json");

const POLL_SECONDS = Number(process.env.POLL_SECONDS || 60);

const DEFAULT_BRANCH = process.env.DEFAULT_BRANCH || "main";

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function readState() {
  try {
    return JSON.parse(readFileSync(STATE_FILE, "utf8"));
  } catch {
    return { services: {} };
  }
}

function writeState(state) {
  mkdirSync(dirname(STATE_FILE), { recursive: true });
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

function listServiceDirs(root) {
  return readdirSync(root, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => join(root, d.name));
}

function findComposeFile(dir) {
  const candidates = [
    "docker-compose.yml",
    "docker-compose.yaml",
    "compose.yml",
    "compose.yaml",
  ];
  for (const f of candidates) {
    const p = join(dir, f);
    if (existsSync(p)) return p;
  }
  return null;
}

function envToObj(env) {
  if (!env) return {};
  if (Array.isArray(env)) {
    const out = {};
    for (const item of env) {
      if (typeof item !== "string") continue;
      const idx = item.indexOf("=");
      if (idx === -1) continue;
      out[item.slice(0, idx)] = item.slice(idx + 1);
    }
    return out;
  }
  if (typeof env === "object") {
    const out = {};
    for (const [k, v] of Object.entries(env))
      out[k] = v == null ? "" : String(v);
    return out;
  }
  return {};
}

function discoverServices() {
  const results = [];
  for (const dir of listServiceDirs(SERVICES_ROOT)) {
    const composePath = findComposeFile(dir);
    if (!composePath) continue;

    let doc;
    try {
      doc = parse(readFileSync(composePath, "utf8")) || {};
    } catch (e) {
      log(`[WARN] Failed parsing ${composePath}:`, e.message);
      continue;
    }

    const services = doc.services || {};
    if (typeof services !== "object") continue;

    for (const [composeServiceName, svc] of Object.entries(services)) {
      if (!svc || typeof svc !== "object") continue;
      const env = envToObj(svc.environment);
      if (!env.REPO_URL) continue;

      results.push({
        name: basename(dir), // folder name
        composeDir: dir,
        composeFile: basename(composePath),
        composeServiceName,
        repoUrl: env.REPO_URL,
        branch: env.BRANCH || DEFAULT_BRANCH,
      });

      // Typically you only want one repo-driven service per folder
      break;
    }
  }
  return results;
}

function gitRemoteSha(repoUrl, branch) {
  // Uses SSH config/keys available to the process user
  const out = execFileSync(
    "git",
    ["ls-remote", repoUrl, `refs/heads/${branch}`],
    { encoding: "utf8" },
  ).trim();
  // format: "<sha>\trefs/heads/main"
  const sha = out.split(/\s+/)[0];
  return sha || null;
}

function runCompose(composeDir, composeFile, composeServiceName) {
  return new Promise((resolve, reject) => {
    const args = [
      "compose",
      "-f",
      composeFile,
      "up",
      "-d",
      "--force-recreate",
      composeServiceName,
    ];
    log(`[DEPLOY] (${composeDir}) docker ${args.join(" ")}`);
    const p = spawn("docker", args, { cwd: composeDir, stdio: "inherit" });
    p.on("exit", (code) =>
      code === 0
        ? resolve()
        : reject(new Error(`docker compose exited ${code}`)),
    );
  });
}

async function tick() {
  const state = readState();
  const services = discoverServices();

  // remove stale entries
  const currentNames = new Set(services.map((s) => s.name));
  for (const k of Object.keys(state.services || {})) {
    if (!currentNames.has(k)) delete state.services[k];
  }

  for (const svc of services) {
    const prev = state.services[svc.name]?.sha || "";
    let remote;
    try {
      remote = gitRemoteSha(svc.repoUrl, svc.branch);
    } catch (e) {
      log(`[${svc.name}] ERROR reading remote SHA: ${e.message}`);
      continue;
    }
    if (!remote) {
      log(`[${svc.name}] ERROR: remote sha empty`);
      continue;
    }

    if (remote === prev) {
      log(`[${svc.name}] no change (${svc.branch}@${remote.slice(0, 7)})`);
      continue;
    }

    log(
      `[${svc.name}] change detected: ${prev.slice(0, 7)} -> ${remote.slice(0, 7)}`,
    );

    try {
      await runCompose(svc.composeDir, svc.composeFile, svc.composeServiceName);
      state.services[svc.name] = {
        sha: remote,
        lastDeployAt: new Date().toISOString(),
      };
      writeState(state);
      log(`[${svc.name}] deployed`);
    } catch (e) {
      log(`[${svc.name}] DEPLOY FAILED: ${e.message}`);
    }
  }
}

async function main() {
  log(
    `deployd starting. root=${SERVICES_ROOT} poll=${POLL_SECONDS}s state=${STATE_FILE}`,
  );
  await tick();
  setInterval(
    () => tick().catch((e) => log("tick error:", e.message)),
    POLL_SECONDS * 1000,
  );
}

main().catch((e) => {
  log("fatal:", e);
  process.exit(1);
});
