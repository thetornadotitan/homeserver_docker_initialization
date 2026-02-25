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
import os from "os";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

function expandHome(p) {
  if (!p) return p;
  if (p === "~") return os.homedir();
  if (p.startsWith("~/")) return join(os.homedir(), p.slice(2));
  return p;
}

function abs(p) {
  p = expandHome(p);
  return isAbsolute(p) ? p : resolve(__dirname, p);
}

/**
 * New layout:
 * - SERVICES_DIR: parent folder containing many compose projects
 *   e.g. ../services
 * - GITHUB_DIR:   git-polled compose projects live under ../services/github
 */
const SERVICES_DIR = process.env.SERVICES_DIR
  ? abs(process.env.SERVICES_DIR)
  : abs("../services");

const GITHUB_DIR = process.env.GITHUB_DIR
  ? abs(process.env.GITHUB_DIR)
  : join(SERVICES_DIR, "github");

const STATE_FILE = process.env.STATE_FILE
  ? abs(process.env.STATE_FILE)
  : abs("./state.json");
const POLL_SECONDS = Number(process.env.POLL_SECONDS || 60);
const DEFAULT_BRANCH = process.env.DEFAULT_BRANCH || "main";
const SSH_KEY_PATH = abs(process.env.SSH_KEY_PATH || "~/secrets/deploy_key");

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
  if (!existsSync(root)) return [];
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

/**
 * GitHub-driven: only look under GITHUB_DIR, and only include services
 * where the compose service environment contains REPO_URL.
 */
function discoverGithubServices() {
  const results = [];

  for (const dir of listServiceDirs(GITHUB_DIR)) {
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

      // Usually one repo-driven service per folder
      break;
    }
  }
  return results;
}

/**
 * Non-GitHub: look under SERVICES_DIR excluding "github".
 * Any folder with a compose file is considered a "static compose project".
 */
function discoverStaticComposeProjects() {
  const results = [];

  for (const dir of listServiceDirs(SERVICES_DIR)) {
    if (basename(dir) === "github") continue;

    const composePath = findComposeFile(dir);
    if (!composePath) continue;

    results.push({
      name: basename(dir),
      composeDir: dir,
      composeFile: basename(composePath),
    });
  }
  return results;
}

function gitRemoteSha(repoUrl, branch) {
  const out = execFileSync(
    "git",
    ["ls-remote", repoUrl, `refs/heads/${branch}`],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        GIT_SSH_COMMAND: `ssh -i "${SSH_KEY_PATH}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new`,
      },
    },
  ).trim();

  return out.split(/\s+/)[0] || null;
}

/**
 * GitHub deploy behavior: force recreate the single service in the compose file.
 */
function runComposeService(composeDir, composeFile, composeServiceName) {
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

/**
 * Static projects: bring up the whole compose project (all services) only if it's down.
 * "Down" here means: docker compose ps shows zero running services for that project.
 */
function anyServicesRunning(composeDir, composeFile) {
  try {
    const out = execFileSync(
      "docker",
      ["compose", "-f", composeFile, "ps", "--status", "running", "--services"],
      { cwd: composeDir, encoding: "utf8" },
    ).trim();
    return out.length > 0;
  } catch {
    // If compose errors (e.g., never started / no project), treat as not running.
    return false;
  }
}

function runComposeProjectUp(composeDir, composeFile) {
  return new Promise((resolve, reject) => {
    const args = ["compose", "-f", composeFile, "up", "-d"];
    log(`[UP] (${composeDir}) docker ${args.join(" ")}`);
    const p = spawn("docker", args, { cwd: composeDir, stdio: "inherit" });
    p.on("exit", (code) =>
      code === 0
        ? resolve()
        : reject(new Error(`docker compose exited ${code}`)),
    );
  });
}

let isTickRunning = false;

async function tick() {
  if (isTickRunning) return;
  isTickRunning = true;
  try {
    // 1) Ensure non-github compose projects are running
    const staticProjects = discoverStaticComposeProjects();
    for (const proj of staticProjects) {
      const running = anyServicesRunning(proj.composeDir, proj.composeFile);
      if (running) {
        log(`[${proj.name}] static compose ok (running)`);
        continue;
      }

      log(`[${proj.name}] static compose not running -> starting`);
      try {
        await runComposeProjectUp(proj.composeDir, proj.composeFile);
        log(`[${proj.name}] static compose started`);
      } catch (e) {
        log(`[${proj.name}] static compose START FAILED: ${e.message}`);
      }
    }

    // 2) GitHub-driven deploys (poll + redeploy)
    const state = readState();
    const services = discoverGithubServices();

    // remove stale entries (only for github-polled services)
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
        await runComposeService(
          svc.composeDir,
          svc.composeFile,
          svc.composeServiceName,
        );
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
  } finally {
    isTickRunning = false;
  }
}

async function main() {
  log(
    `deployd starting. services=${SERVICES_DIR} github=${GITHUB_DIR} poll=${POLL_SECONDS}s state=${STATE_FILE}`,
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
