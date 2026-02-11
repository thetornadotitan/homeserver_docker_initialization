#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

detect_ip() {
  local ip=""
  # Prefer the IP used for the default route (most correct on servers)
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"

  # Fallback: first non-loopback IPv4
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -vE '^127\.' | head -n1 || true)"
  fi

  [[ -n "${ip}" ]] || die "Could not detect LAN IPv4 address."
  echo "${ip}"
}

# Load existing .env if present (for TUNNEL_TOKEN)
EXISTING_TUNNEL_TOKEN=""
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set +u
  source "${ENV_FILE}" || true
  set -u
  EXISTING_TUNNEL_TOKEN="${TUNNEL_TOKEN-}"
fi

# Allow overriding via environment variable
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

docker compose up -d
echo
echo "Up. AdGuard setup UI: http://${LAN_IP}:3000"
