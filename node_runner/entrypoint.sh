#!/usr/bin/env bash
set -euo pipefail

: "${REPO_URL:?REPO_URL is required, e.g. https://github.com/org/repo.git}"
: "${BRANCH:=main}"
: "${APP_DIR:=/app/src}"

if [[ ! -d "${APP_DIR}/.git" ]]; then
  echo "Cloning ${REPO_URL} (${BRANCH})..."
  mkdir -p "${APP_DIR}"
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh

  if [[ -n "${SSH_PRIVATE_KEY_PATH:-}" ]]; then
    cp "${SSH_PRIVATE_KEY_PATH}" /root/.ssh/id_ed25519
    chmod 600 /root/.ssh/id_ed25519
    export GIT_SSH_COMMAND="ssh -i /root/.ssh/id_ed25519 -o IdentitiesOnly=yes"
  fi

  # Trust GitHub host key (prevents interactive prompt)
  ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null
  chmod 600 /root/.ssh/known_hosts
  git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${APP_DIR}"
else
  echo "Repo already present; pulling latest..."
  git -C "${APP_DIR}" fetch --depth 1 origin "${BRANCH}"
  git -C "${APP_DIR}" reset --hard "origin/${BRANCH}"
fi

cd "${APP_DIR}"

# Install deps (supports npm/yarn/pnpm if you want; this is npm-only)
if [[ -f package-lock.json ]]; then
  npm ci
else
  npm install
fi

# Build if present (Nest/TS typically has this)
npm run build --if-present

# Start (Nest: start:prod often; Express: start)
if npm run start:prod --if-present; then
  :
else
  npm run start
fi
