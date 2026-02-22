#!/usr/bin/env bash
set -euo pipefail

# ---- Config (edit if you want) ----
APP_NAME="${APP_NAME:-deployd}"
DEPLOYD_DIR="${DEPLOYD_DIR:-$HOME/homeserver_docker_initialization/deployd}"
ENTRY_FILE="${ENTRY_FILE:-deployd.js}"

# Optional env vars for your deployd process
export SERVICES_ROOT="$HOME/homeserver_docker_initialization/services"
export STATE_FILE="$HOME/homeserver_docker_initialization/deployd/state.json"
export SSH_KEY_PATH="$HOME/secrets/deploy_key"
export POLL_SECONDS="60"
export DEFAULT_BRANCH="main"

# PM2 logrotate config (defaults are reasonable; tweak if you want)
LOGROTATE_MAX_SIZE="${LOGROTATE_MAX_SIZE:-10M}"
LOGROTATE_RETAIN="${LOGROTATE_RETAIN:-10}"
LOGROTATE_COMPRESS="${LOGROTATE_COMPRESS:-true}"
LOGROTATE_INTERVAL="${LOGROTATE_INTERVAL:-0 0 * * *}" # daily at midnight

# ---- Helpers ----
need_cmd() { command -v "$1" >/dev/null 2>&1; }
as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- 1) Ensure node + npm ----
install_node() {
  echo "[install] Node.js/npm not found. Installing Node.js 20.x (NodeSource) ..."
  as_root apt-get update -y
  as_root apt-get install -y ca-certificates curl gnupg

  # NodeSource repo
  as_root install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | as_root gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
    | as_root tee /etc/apt/sources.list.d/nodesource.list >/dev/null

  as_root apt-get update -y
  as_root apt-get install -y nodejs
}

if ! need_cmd node || ! need_cmd npm; then
  install_node
fi

echo "[ok] node: $(node -v) | npm: $(npm -v)"

# ---- 2) Ensure pm2 ----
if ! need_cmd pm2; then
  echo "[install] pm2 not found. Installing globally..."
  as_root npm install -g pm2
fi
echo "[ok] pm2: $(pm2 -v)"

# ---- 3) Ensure pm2-logrotate ----
if ! pm2 ls --silent | grep -q "pm2-logrotate"; then
  echo "[install] pm2-logrotate not found. Installing..."
  pm2 install pm2-logrotate
fi

# Configure logrotate (idempotent)
pm2 set pm2-logrotate:max_size "${LOGROTATE_MAX_SIZE}" >/dev/null
pm2 set pm2-logrotate:retain "${LOGROTATE_RETAIN}" >/dev/null
pm2 set pm2-logrotate:compress "${LOGROTATE_COMPRESS}" >/dev/null
pm2 set pm2-logrotate:rotateInterval "${LOGROTATE_INTERVAL}" >/dev/null
pm2 set pm2-logrotate:workerInterval 30 >/dev/null

echo "[ok] pm2-logrotate configured: max_size=${LOGROTATE_MAX_SIZE} retain=${LOGROTATE_RETAIN} compress=${LOGROTATE_COMPRESS} interval='${LOGROTATE_INTERVAL}'"

# ---- 4) Verify deployd exists + deps installed ----
[[ -d "${DEPLOYD_DIR}" ]] || die "DEPLOYD_DIR not found: ${DEPLOYD_DIR}"
[[ -f "${DEPLOYD_DIR}/${ENTRY_FILE}" ]] || die "ENTRY_FILE not found: ${DEPLOYD_DIR}/${ENTRY_FILE}"

echo "[install] Ensuring node deps installed in ${DEPLOYD_DIR} ..."
pushd "${DEPLOYD_DIR}" >/dev/null
if [[ -f package-lock.json ]]; then
  npm ci
else
  npm install
fi
popd >/dev/null

# ---- 5) Start (or restart) via pm2 with auto-restart ----
# pm2 auto-restarts by default if the process crashes.
# We also set a couple of safety options:
# - max_restarts: give up after N rapid crashes
# - restart_delay: small delay between restarts
# - time: add timestamps in pm2 logs
echo "[pm2] Starting ${APP_NAME} ..."
pm2 delete "${APP_NAME}" >/dev/null 2>&1 || true

pm2 start "${DEPLOYD_DIR}/${ENTRY_FILE}" \
  --name "${APP_NAME}" \
  --cwd "${DEPLOYD_DIR}" \
  --time \
  --max-restarts 50 \
  --restart-delay 2000

# ---- 6) Persist + enable startup on boot ----
pm2 save

# This prints a command you normally need to run once with sudo.
# We'll run it automatically.
STARTUP_CMD="$(pm2 startup systemd -u "${USER}" --hp "${HOME}" | tail -n 1 || true)"
if [[ -n "${STARTUP_CMD}" ]]; then
  echo "[pm2] Enabling startup on boot..."
  as_root bash -lc "${STARTUP_CMD}"
  pm2 save
fi

echo
echo "[done] deployd is running under pm2."
echo "  - Status:   pm2 status ${APP_NAME}"
echo "  - Logs:     pm2 logs ${APP_NAME}"
echo "  - Logrotate: pm2 logs pm2-logrotate"
