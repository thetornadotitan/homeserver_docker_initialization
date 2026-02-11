#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

log() { echo -e "\n==> $*\n"; }

ensure_docker() {
  local has_docker=false
  local has_compose=false

  if need_cmd docker; then
    has_docker=true
  fi

  # Compose v2 is "docker compose"
  if $has_docker && docker compose version >/dev/null 2>&1; then
    has_compose=true
  fi

  if $has_docker && $has_compose; then
    log "Docker and Docker Compose already installed."
    return 0
  fi

  log "Docker/Compose missing — installing via Docker's official Ubuntu repository..."
  need_cmd sudo || die "sudo is required to install Docker. Install sudo or run as root."

  # Ask for sudo once up-front
  sudo -v

  # Run install steps as root, without re-exec'ing the whole script
  sudo bash -euo pipefail <<'ROOT'
apt-get update -y
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

UBUNTU_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
ARCH="$(dpkg --print-architecture)"

echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

# Ensure docker group exists
getent group docker >/dev/null 2>&1 || groupadd docker
ROOT

  # Add invoking user to docker group (so docker works without sudo)
  local user_to_add="${SUDO_USER:-$USER}"
  if id -nG "${user_to_add}" | tr ' ' '\n' | grep -qx docker; then
    log "User '${user_to_add}' already in docker group."
  else
    log "Adding user '${user_to_add}' to docker group..."
    sudo usermod -aG docker "${user_to_add}"
    log "IMPORTANT: log out/in (or run: newgrp docker) before running docker without sudo."
  fi

  log "Docker install complete."
  docker --version || true
  docker compose version || true
}

detect_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"

  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -vE '^127\.' | head -n1 || true)"
  fi

  [[ -n "${ip}" ]] || die "Could not detect LAN IPv4 address."
  echo "${ip}"
}

# 1) Ensure docker + compose are present
ensure_docker

# 2) Load existing .env if present (for TUNNEL_TOKEN)
EXISTING_TUNNEL_TOKEN=""
if [[ -f "${ENV_FILE}" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "${ENV_FILE}" || true
  set -u
  EXISTING_TUNNEL_TOKEN="${TUNNEL_TOKEN-}"
fi

TOKEN_FROM_ENV="${TUNNEL_TOKEN-}"
TOKEN="${TOKEN_FROM_ENV:-$EXISTING_TUNNEL_TOKEN}"
[[ -n "${TOKEN}" ]] || die "TUNNEL_TOKEN is not set. Put it in .env or export it before running: export TUNNEL_TOKEN=... "

LAN_IP="$(detect_ip)"

cat > "${ENV_FILE}" <<EOF
LAN_IP=${LAN_IP}
TUNNEL_TOKEN=${TOKEN}
EOF

echo "Wrote ${ENV_FILE}:"
cat "${ENV_FILE}"
echo

# 3) Start services
docker compose up -d
echo
echo "Up. AdGuard setup UI: http://${LAN_IP}:3000"
