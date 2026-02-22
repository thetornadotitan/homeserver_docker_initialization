import express from "express";
import Docker from "dockerode";

const app = express();
const port = Number(process.env.PORT || 3000);
const labelKey = process.env.CATALOG_LABEL || "catalog.enable";
const docker = new Docker();

// ---- Tunables ----
const REFRESH_INTERVAL_MS = Number(process.env.REFRESH_INTERVAL_MS || 10_000);
const REQUEST_TIMEOUT_MS = Number(process.env.REQUEST_TIMEOUT_MS || 3_000);
const DEGRADED_THRESHOLD_MS = Number(process.env.DEGRADED_THRESHOLD_MS || 800);
const MAX_RETRIES = Number(process.env.MAX_RETRIES || 3);
const MAX_CONCURRENT_CHECKS = Number(process.env.MAX_CONCURRENT_CHECKS || 10);

// For PathPrefix(...) -> LAN_BASE_URL + /path
// Example: http://192.168.1.50
const LAN_BASE_URL = (process.env.LAN_BASE_URL || "").trim().replace(/\/$/, "");

// ---- In-memory cache ----
let lastSnapshot = {
  generatedAt: new Date().toISOString(),
  count: 0,
  services: [],
};
let lastRefresh = {
  startedAt: null,
  finishedAt: null,
  durationMs: null,
  error: null,
};

function uniq(arr) {
  return [...new Set(arr.filter(Boolean))];
}

// Extract Host(`...`) from traefik router rules
function parseTraefikHostUrls(labels = {}) {
  const urls = [];
  for (const [k, v] of Object.entries(labels)) {
    if (!k.endsWith(".rule")) continue;
    const str = String(v);

    // Host(`a.b`) or Host(`a.b`,`c.d`) etc. We'll grab all backtick-wrapped strings.
    const matches = [...str.matchAll(/Host\(([^)]+)\)/g)];
    for (const m of matches) {
      const inside = m[1] || "";
      const hosts = [...inside.matchAll(/`([^`]+)`/g)].map((x) => x[1]);
      for (const h of hosts) urls.push(`http://${h}`);
    }
  }
  return uniq(urls);
}

// Extract PathPrefix(`/x`) from traefik router rules
function parseTraefikPathPrefixes(labels = {}) {
  const paths = [];
  for (const [k, v] of Object.entries(labels)) {
    if (!k.endsWith(".rule")) continue;
    const str = String(v);

    // Match PathPrefix(`/a`) or PathPrefix(`/a`,`/b`)
    const matches = [...str.matchAll(/PathPrefix\(([^)]+)\)/g)];
    for (const m of matches) {
      const inside = m[1] || "";
      const pths = [...inside.matchAll(/`([^`]+)`/g)].map((x) => x[1]);
      for (const p of pths) paths.push(p);
    }
  }
  return uniq(paths);
}

function buildLanUrlsFromPaths(paths) {
  if (!LAN_BASE_URL) return [];
  return uniq(
    paths.map((p) => {
      if (!p.startsWith("/")) return `${LAN_BASE_URL}/${p}`;
      return `${LAN_BASE_URL}${p}`;
    }),
  );
}

async function checkUrlHealth(url) {
  let attempt = 0;
  let lastError = null;

  while (attempt < MAX_RETRIES) {
    attempt++;

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    const start = Date.now();

    try {
      const res = await fetch(url, {
        method: "GET",
        signal: controller.signal,
      });
      clearTimeout(timeout);

      const latency = Date.now() - start;

      if (!res.ok) {
        lastError = `HTTP ${res.status}`;
        continue;
      }

      return {
        health:
          latency >= DEGRADED_THRESHOLD_MS || attempt > 1 ? "degraded" : "up",
        responseTimeMs: latency,
        attempts: attempt,
        error: null,
      };
    } catch (err) {
      clearTimeout(timeout);
      lastError =
        err?.name === "AbortError" ? "timeout" : err?.message || "fetch_error";
    }
  }

  return {
    health: "down",
    responseTimeMs: null,
    attempts: MAX_RETRIES,
    error: lastError,
  };
}

// Try a list of candidate URLs; first success wins.
// degraded if slow OR if it only succeeded after failing earlier candidates.
async function checkCandidates(candidates) {
  let failuresBeforeSuccess = 0;
  let lastFailure = null;

  for (const url of candidates) {
    const r = await checkUrlHealth(url);
    if (r.health === "up" || r.health === "degraded") {
      return {
        ...r,
        checkedUrl: url,
        // If earlier candidates failed, treat as degraded
        health: failuresBeforeSuccess > 0 ? "degraded" : r.health,
      };
    }
    failuresBeforeSuccess++;
    lastFailure = r.error || "failed";
  }

  return {
    health: "down",
    responseTimeMs: null,
    attempts: MAX_RETRIES,
    error: lastFailure,
    checkedUrl: candidates[0] || null,
  };
}

function mapContainerToService(c) {
  const labels = c.Labels || {};
  const enabled = labels[labelKey] === "true" || labels[labelKey] === "1";
  if (!enabled) return null;

  const traefikGroup = labels["traefik.group"] || "unknown";
  const visibility =
    traefikGroup === "public"
      ? "public"
      : traefikGroup === "admin"
        ? "private"
        : "unknown";

  const name =
    labels["catalog.name"] ||
    (c.Names?.[0] ? c.Names[0].replace(/^\//, "") : c.Id?.slice(0, 12));

  const hostUrls = parseTraefikHostUrls(labels);
  const pathPrefixes = parseTraefikPathPrefixes(labels);
  const lanUrls = buildLanUrlsFromPaths(pathPrefixes);

  // Candidate order: host first (nice DNS), then LAN IP path fallback
  const healthCandidates = uniq([...hostUrls, ...lanUrls]);

  return {
    id: c.Id,
    name,
    visibility,
    description: labels["catalog.description"] || null,
    image: c.Image,
    state: c.State,
    status: c.Status,
    created: c.Created,
    urls: hostUrls, // purely DNS-based (what you’d show as “pretty URL”)
    lanUrls, // LAN_BASE_URL + pathprefix (what works now)
    healthCandidates, // what health checker will try
    health: c.State === "running" ? "up" : "down",
    responseTimeMs: null,
    attempts: 0,
    error: null,
    checkedUrl: null,
    labels: {
      "traefik.group": labels["traefik.group"],
    },
  };
}

async function mapWithConcurrency(items, mapper, maxConcurrent) {
  const results = new Array(items.length);
  let i = 0;

  async function worker() {
    while (true) {
      const idx = i++;
      if (idx >= items.length) return;
      results[idx] = await mapper(items[idx], idx);
    }
  }

  const workers = Array.from(
    { length: Math.min(maxConcurrent, items.length) },
    worker,
  );
  await Promise.all(workers);
  return results;
}

// ---- background refresh loop ----
let refreshInFlight = false;

async function refreshSnapshot() {
  if (refreshInFlight) return;
  refreshInFlight = true;

  const started = Date.now();
  lastRefresh.startedAt = new Date().toISOString();
  lastRefresh.error = null;

  try {
    const containers = await docker.listContainers({ all: false });
    const mapped = containers.map(mapContainerToService).filter(Boolean);

    const checked = await mapWithConcurrency(
      mapped,
      async (svc) => {
        if (svc.state !== "running") {
          return { ...svc, health: "down" };
        }

        if (!svc.healthCandidates?.length) {
          // No routes found; treat running as "up" (or switch to "unknown" if desired)
          return { ...svc, health: "up" };
        }

        const result = await checkCandidates(svc.healthCandidates);

        return {
          ...svc,
          health: result.health,
          responseTimeMs: result.responseTimeMs,
          attempts: result.attempts,
          error: result.error,
          checkedUrl: result.checkedUrl,
        };
      },
      MAX_CONCURRENT_CHECKS,
    );

    checked.sort((a, b) => a.name.localeCompare(b.name));

    lastSnapshot = {
      generatedAt: new Date().toISOString(),
      count: checked.length,
      services: checked,
    };
  } catch (err) {
    lastRefresh.error = err?.message || "refresh_error";
  } finally {
    const dur = Date.now() - started;
    lastRefresh.finishedAt = new Date().toISOString();
    lastRefresh.durationMs = dur;
    refreshInFlight = false;
  }
}

function startBackgroundLoop() {
  refreshSnapshot();
  setInterval(refreshSnapshot, REFRESH_INTERVAL_MS);
}

// ---- routes ----
app.get("/health", (req, res) => res.json({ ok: true }));

app.get("/services", (req, res) => {
  res.json({
    ...lastSnapshot,
    refresh: {
      ...lastRefresh,
      lanBaseUrl: LAN_BASE_URL || null,
      refreshIntervalMs: REFRESH_INTERVAL_MS,
    },
  });
});

app.post("/refresh", async (req, res) => {
  await refreshSnapshot();
  res.json({
    ok: true,
    generatedAt: lastSnapshot.generatedAt,
    refresh: lastRefresh,
  });
});

// ---- start ----
startBackgroundLoop();

app.listen(port, () => {
  console.log(`service-catalog listening on :${port}`);
  console.log(
    `refresh interval: ${REFRESH_INTERVAL_MS}ms, timeout: ${REQUEST_TIMEOUT_MS}ms, degraded >= ${DEGRADED_THRESHOLD_MS}ms`,
  );
  console.log(`LAN_BASE_URL: ${LAN_BASE_URL || "(not set)"}`);
});
