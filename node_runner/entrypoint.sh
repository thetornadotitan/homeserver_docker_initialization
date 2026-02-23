#!/usr/bin/env bash
set -euo pipefail

die()  { echo "ERROR: $*" >&2; exit 1; }
log()  { echo "[entrypoint] $*" >&2; }
warn() { echo "[entrypoint][WARN] $*" >&2; }

: "${REPO_URL:?REPO_URL is required, e.g. git@github.com:org/repo.git}"
: "${BRANCH:=main}"
: "${APP_DIR:=/app/src}"
: "${GIT_DEPTH:=1}"                        # shallow fetch/clone depth
: "${GIT_REMOTE_NAME:=origin}"
: "${CLEAN_DIRTY_REPO:=true}"              # true => hard reset + clean -fdx before updating
: "${ALLOW_REMOTE_REWRITE:=true}"          # true => always set origin URL to REPO_URL
: "${RECLONE_ON_MISMATCH:=true}"           # true => if repo seems wrong/corrupt, wipe + clone
: "${SSH_KNOWN_HOSTS_STRICT:=true}"        # true => StrictHostKeyChecking=yes, else accept-new
: "${NPM_INSTALL_STRATEGY:=auto}"          # auto|ci|install|skip
: "${NPM_BUILD:=true}"                     # true => run build --if-present
: "${START_SCRIPT_PREFERENCE:=auto}"       # auto|start:prod|start|none
: "${HEALTHCHECK_FILE:=}"                  # optional: write a file when "ready" (e.g. /tmp/ready)

# ---------- helpers ----------
normalize_bool() {
  case "${1,,}" in
    1|true|yes|y|on)  echo "true" ;;
    0|false|no|n|off) echo "false" ;;
    *) echo "false" ;;
  esac
}

bool_CLEAN_DIRTY_REPO="$(normalize_bool "${CLEAN_DIRTY_REPO}")"
bool_ALLOW_REMOTE_REWRITE="$(normalize_bool "${ALLOW_REMOTE_REWRITE}")"
bool_RECLONE_ON_MISMATCH="$(normalize_bool "${RECLONE_ON_MISMATCH}")"
bool_SSH_KNOWN_HOSTS_STRICT="$(normalize_bool "${SSH_KNOWN_HOSTS_STRICT}")"
bool_NPM_BUILD="$(normalize_bool "${NPM_BUILD}")"

ensure_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

ensure_cmd git
ensure_cmd node
ensure_cmd npm
ensure_cmd ssh-keyscan
ensure_cmd ssh-keygen

# ---------- SSH setup (every run) ----------
log "Setting up SSH..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Known hosts (idempotent)
touch /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts

ssh-keygen -F github.com >/dev/null 2>&1 || ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null

# Key install (optional)
if [[ -n "${SSH_PRIVATE_KEY_PATH:-}" ]]; then
  [[ -f "${SSH_PRIVATE_KEY_PATH}" ]] || die "SSH_PRIVATE_KEY_PATH='${SSH_PRIVATE_KEY_PATH}' doesn't exist in container. Did you mount it?"
  cp "${SSH_PRIVATE_KEY_PATH}" /root/.ssh/id_ed25519
  chmod 600 /root/.ssh/id_ed25519

  if [[ "${bool_SSH_KNOWN_HOSTS_STRICT}" == "true" ]]; then
    export GIT_SSH_COMMAND="ssh -i /root/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"
  else
    # 'accept-new' is safer than 'no' but depends on OpenSSH version; fallback to 'no'
    export GIT_SSH_COMMAND="ssh -i /root/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  fi
else
  warn "SSH_PRIVATE_KEY_PATH not set; relying on container's default git auth (may fail for private repos)."
fi

# ---------- repo functions ----------
is_git_repo() {
  [[ -d "${APP_DIR}/.git" ]] && git -C "${APP_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

current_origin_url() {
  git -C "${APP_DIR}" remote get-url "${GIT_REMOTE_NAME}" 2>/dev/null || true
}

set_origin_url() {
  git -C "${APP_DIR}" remote set-url "${GIT_REMOTE_NAME}" "${REPO_URL}"
}

wipe_dir() {
  # Safer for volume mounts: clear contents without deleting the mountpoint itself
  log "Wiping contents of ${APP_DIR}..."
  mkdir -p "${APP_DIR}"
  rm -rf "${APP_DIR:?}/"* "${APP_DIR:?}/".[^.]* "${APP_DIR:?}/"..?* 2>/dev/null || true
}

clone_repo() {
  log "Cloning ${REPO_URL} (branch=${BRANCH}, depth=${GIT_DEPTH}) into ${APP_DIR}..."

  mkdir -p "${APP_DIR}"
  tmp="$(mktemp -d)"

  git clone --depth "${GIT_DEPTH}" --branch "${BRANCH}" "${REPO_URL}" "${tmp}/repo"

  log "Replacing contents of ${APP_DIR}..."
  rm -rf "${APP_DIR:?}/"* "${APP_DIR:?}/".[^.]* "${APP_DIR:?}/"..?* 2>/dev/null || true
  # Move cloned contents into mounted dir
  cp -a "${tmp}/repo/." "${APP_DIR}/"
  rm -rf "${tmp}"
}

clean_repo() {
  log "Cleaning repo state (reset + clean -fdx)..."
  git -C "${APP_DIR}" reset --hard
  git -C "${APP_DIR}" clean -fdx
}

fetch_and_reset() {
  log "Fetching ${GIT_REMOTE_NAME}/${BRANCH} (depth=${GIT_DEPTH})..."
  git -C "${APP_DIR}" fetch --depth "${GIT_DEPTH}" "${GIT_REMOTE_NAME}" "${BRANCH}"
  log "Resetting to ${GIT_REMOTE_NAME}/${BRANCH}..."
  git -C "${APP_DIR}" reset --hard "${GIT_REMOTE_NAME}/${BRANCH}"
}

verify_repo_sanity() {
  # Basic sanity: must have package.json and a usable git repo
  [[ -f "${APP_DIR}/package.json" ]] || return 10
  git -C "${APP_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 11
  return 0
}

repo_slug() {
  # Returns "owner/repo" from common git URL formats
  local url="$1"
  url="${url%.git}"
  url="${url#ssh://}"
  url="${url#git@github.com:}"
  url="${url#https://github.com/}"
  url="${url#http://github.com/}"
  echo "$url"
}

did_fresh_clone="false"

# If a repo already exists in the mounted dir, enforce that it's the repo we expect.
# If you change REPO_URL in compose, this ensures you never keep the old repo around.
existing_origin="$(current_origin_url)"
expected_slug="$(repo_slug "${REPO_URL}")"
existing_slug="$(repo_slug "${existing_origin:-}")"

log "Expected repo: ${expected_slug}"
log "Existing repo: ${existing_slug:-<none>}"

if [[ -n "${existing_slug}" && "${existing_slug}" != "${expected_slug}" ]]; then
  warn "Repo mismatch detected (${existing_slug} != ${expected_slug})."
  if [[ "${bool_RECLONE_ON_MISMATCH}" == "true" ]]; then
    wipe_dir
    clone_repo
    did_fresh_clone="true"
  else
    die "Repo mismatch and RECLONE_ON_MISMATCH=false"
  fi
fi

# ---------- Git checkout/update ----------
log "Ensuring application checkout in ${APP_DIR}..."

if [[ "${did_fresh_clone}" == "true" ]]; then
  log "Fresh clone already performed due to repo mismatch."
elif ! is_git_repo; then
  log "No valid git repo found at ${APP_DIR}."
  clone_repo
else
  log "Repo already present."

  # Optional: clean dirty/cached state first
  if [[ "${bool_CLEAN_DIRTY_REPO}" == "true" ]]; then
    clean_repo || warn "Could not clean repo (continuing)."
  fi

  existing_origin="$(current_origin_url)"
  log "Existing ${GIT_REMOTE_NAME} URL: ${existing_origin:-<none>}"
  log "Expected ${GIT_REMOTE_NAME} URL: ${REPO_URL}"

  if [[ "${bool_ALLOW_REMOTE_REWRITE}" == "true" ]]; then
    if [[ -n "${existing_origin}" && "${existing_origin}" != "${REPO_URL}" ]]; then
      warn "Origin mismatch detected. Rewriting ${GIT_REMOTE_NAME} to REPO_URL."
    fi
    set_origin_url || {
      if [[ "${bool_RECLONE_ON_MISMATCH}" == "true" ]]; then
        warn "Failed to set remote URL; recloning."
        wipe_dir
        clone_repo
        did_fresh_clone="true"
      else
        die "Failed to set remote URL and RECLONE_ON_MISMATCH=false"
      fi
    }
  else
    if [[ -n "${existing_origin}" && "${existing_origin}" != "${REPO_URL}" ]]; then
      if [[ "${bool_RECLONE_ON_MISMATCH}" == "true" ]]; then
        warn "Origin mismatch and ALLOW_REMOTE_REWRITE=false; recloning."
        wipe_dir
        clone_repo
        did_fresh_clone="true"
      else
        die "Origin mismatch (${existing_origin} != ${REPO_URL}) and ALLOW_REMOTE_REWRITE=false"
      fi
    fi
  fi

  # Update to desired branch head
  if [[ "${did_fresh_clone}" != "true" ]] && is_git_repo; then
    if ! git -C "${APP_DIR}" ls-remote --exit-code --heads "${GIT_REMOTE_NAME}" "${BRANCH}" >/dev/null 2>&1; then
      if [[ "${bool_RECLONE_ON_MISMATCH}" == "true" ]]; then
        warn "Remote does not have branch '${BRANCH}' or cannot access it; recloning."
        wipe_dir
        clone_repo
        did_fresh_clone="true"
      else
        die "Remote does not have branch '${BRANCH}' or cannot access it."
      fi
    else
      fetch_and_reset
    fi
  fi
fi

# Verify expected files exist
if ! verify_repo_sanity; then
  if [[ "${bool_RECLONE_ON_MISMATCH}" == "true" ]]; then
    warn "Repo sanity check failed (missing package.json or repo broken). Recloning..."
    wipe_dir
    clone_repo
    verify_repo_sanity || die "Repo sanity check still failing after reclone."
  else
    die "Repo sanity check failed and RECLONE_ON_MISMATCH=false"
  fi
fi

cd "${APP_DIR}"
log "Checked out commit: $(git rev-parse --short HEAD) on branch: $(git rev-parse --abbrev-ref HEAD)"
log "Origin URL now: $(git remote get-url "${GIT_REMOTE_NAME}")"

# ---------- Install ----------
case "${NPM_INSTALL_STRATEGY,,}" in
  skip)
    log "Skipping npm install (NPM_INSTALL_STRATEGY=skip)."
    ;;
  ci)
    log "Running npm ci..."
    npm ci
    ;;
  install)
    log "Running npm install..."
    npm install
    ;;
  auto)
    if [[ -f package-lock.json ]]; then
      log "package-lock.json found; running npm ci..."
      npm ci
    else
      log "No package-lock.json; running npm install..."
      npm install
    fi
    ;;
  *)
    die "Invalid NPM_INSTALL_STRATEGY='${NPM_INSTALL_STRATEGY}'. Use auto|ci|install|skip."
    ;;
esac

# ---------- Build ----------
if [[ "${bool_NPM_BUILD}" == "true" ]]; then
  log "Running npm run build --if-present..."
  npm run build --if-present
else
  log "Skipping build (NPM_BUILD=false)."
fi

# Optional readiness marker
if [[ -n "${HEALTHCHECK_FILE}" ]]; then
  log "Writing readiness file to ${HEALTHCHECK_FILE}"
  mkdir -p "$(dirname "${HEALTHCHECK_FILE}")"
  echo "ready $(date -Iseconds)" > "${HEALTHCHECK_FILE}"
fi

# ---------- Start ----------
log "Starting app..."

has_script() {
  local s="$1"
  node -e "process.exit(((require('./package.json').scripts||{})['${s}'] ? 0 : 1))"
}

start_mode="${START_SCRIPT_PREFERENCE,,}"

if [[ "${start_mode}" == "none" ]]; then
  log "START_SCRIPT_PREFERENCE=none; sleeping to keep container alive."
  exec tail -f /dev/null
elif [[ "${start_mode}" == "start:prod" ]]; then
  has_script "start:prod" || die "Requested start:prod but scripts.start:prod not found"
  exec npm run start:prod
elif [[ "${start_mode}" == "start" ]]; then
  has_script "start" || die "Requested start but scripts.start not found"
  exec npm run start
elif [[ "${start_mode}" == "auto" ]]; then
  if has_script "start:prod"; then
    exec npm run start:prod
  elif has_script "start"; then
    exec npm run start
  else
    log "package.json scripts:"
    node -e 'console.error(JSON.stringify((require("./package.json").scripts||{}), null, 2))' >&2
    die "No start script found (need scripts.start or scripts.start:prod)"
  fi
else
  die "Invalid START_SCRIPT_PREFERENCE='${START_SCRIPT_PREFERENCE}'. Use auto|start:prod|start|none."
fi