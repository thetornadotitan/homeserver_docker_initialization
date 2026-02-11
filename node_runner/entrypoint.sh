#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

: "${REPO_URL:?REPO_URL is required, e.g. git@github.com:org/repo.git}"
: "${BRANCH:=main}"
: "${APP_DIR:=/app/src}"

# --- SSH setup (do this EVERY run, for clone AND pull) ---
mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [[ -n "${SSH_PRIVATE_KEY_PATH:-}" ]]; then
  if [[ ! -f "${SSH_PRIVATE_KEY_PATH}" ]]; then
    die "SSH_PRIVATE_KEY_PATH points to '${SSH_PRIVATE_KEY_PATH}', but that file doesn't exist in the container. Did you mount the secret?"
  fi

  cp "${SSH_PRIVATE_KEY_PATH}" /root/.ssh/id_ed25519
  chmod 600 /root/.ssh/id_ed25519

  # Ensure git uses this key
  export GIT_SSH_COMMAND="ssh -i /root/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"
fi

# Populate known_hosts (idempotent)
touch /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts
ssh-keygen -F github.com >/dev/null 2>&1 || ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null

# --- Git checkout/update ---
if [[ ! -d "${APP_DIR}/.git" ]]; then
  echo "Cloning ${REPO_URL} (${BRANCH})..."
  mkdir -p "${APP_DIR}"
  git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${APP_DIR}"
else
  echo "Repo already present; pulling latest..."
  git -C "${APP_DIR}" fetch --depth 1 origin "${BRANCH}"
  git -C "${APP_DIR}" reset --hard "origin/${BRANCH}"
fi

cd "${APP_DIR}"

# --- Install/build ---
if [[ -f package-lock.json ]]; then
  npm ci
else
  npm install
fi

npm run build --if-present

# --- Start (keep container alive) ---
echo "Starting app..."
if node -e 'process.exit((require("./package.json").scripts||{})["start:prod"] ? 0 : 1)'; then
  exec npm run start:prod
elif node -e 'process.exit((require("./package.json").scripts||{}).start ? 0 : 1)'; then
  exec npm run start
else
  echo "package.json scripts:" >&2
  node -e 'console.error(JSON.stringify((require("./package.json").scripts||{}), null, 2))' >&2
  die "No start script found (need scripts.start or scripts.start:prod)"
fi
