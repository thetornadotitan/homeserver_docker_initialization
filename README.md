# HomeServer Docker Stack

A structured dual-edge Docker environment providing:

- Public ingress via **Cloudflare Tunnel → Traefik Public**
- LAN-only ingress via **Traefik Admin**
- Internal DNS + ad blocking via **AdGuard**
- Dynamic service dashboard via **Service Catalog**
- Container management via **Portainer**
- Hardened Docker API exposure via **docker-socket-proxy**

---

# Architecture Overview

## Public Edge (Internet)

Internet  
→ Cloudflare DNS  
→ Cloudflare Tunnel (`cloudflared`)  
→ `traefik_public`  
→ Public containers (labeled `traefik.group=public`)

## Admin Edge (LAN Only)

LAN Browser  
→ `traefik_admin` (bound to `${LAN_IP}`)  
→ Admin containers (labeled `traefik.group=admin`)

All admin services live on the `admin_proxy` Docker network.

---

# Network Design

Two isolated Docker bridge networks are used:

## public_proxy

Used only for:

- `traefik_public`
- `cloudflared`
- Public-facing services

## admin_proxy

Used for:

- `traefik_admin`
- AdGuard
- Portainer
- Service Catalog
- docker-socket-proxy
- Any LAN-only services

This separation prevents accidental public exposure of internal services.

---

# Core Services

## Traefik Public

Reverse proxy for internet-facing services.

### Key Behavior

- Only discovers containers labeled:
  traefik.group=public
- `exposedbydefault=false`
- No direct host port binding (traffic arrives via Cloudflare tunnel)

---

## Cloudflared

Creates a secure outbound tunnel to Cloudflare.

### Requirements

Environment variable:
TUNNEL_TOKEN=<your-token>

Tunnel must point to:
http://traefik_public:80

---

## Traefik Admin

Reverse proxy for LAN-only services.

### Characteristics

- Only discovers containers labeled:
  traefik.group=admin
- Binds to:
  ${LAN_IP}:80
- Intended to be accessed via internal domain names (e.g. `portainer.hh`)

---

## AdGuard Home

Provides:

- LAN DNS
- Ad blocking
- Wildcard internal domain resolution

### Required DNS Rewrite

Inside AdGuard:

Filters → DNS rewrites

Add:
\*.hh → ${LAN_IP}

This allows:

portainer.hh  
catalog.hh  
adguard.hh  
anyservice.hh

to resolve to Traefik Admin.

---

## docker-socket-proxy

Hardened Docker API proxy.

Limits Docker socket access to only required endpoints.

Used by:

- Service Catalog

Not used by:

- Portainer (Portainer mounts Docker socket directly)

---

## Service Catalog

Custom service that:

- Reads containers via Docker API
- Filters by `catalog.enable=true`
- Performs health checks
- Displays admin dashboard

Environment configuration includes:

DOCKER_HOST=tcp://docker_socket_proxy:2375  
PORT=3000  
CATALOG_LABEL=catalog.enable

Traefik routing:

- Host: catalog.hh
- Optional: /hh/catalog (with StripPrefix)

---

## Portainer

Docker management UI.

### Features

- View logs
- Inspect containers
- Manage stacks
- Monitor status

### Requirements

Mount Docker socket:

- /var/run/docker.sock:/var/run/docker.sock

Data volume:

- portainer_data:/data

### Important

Portainer works best using host-based routing:
http://portainer.hh

Subpath routing (e.g., /hh/portainer) may cause UI loading issues unless base URL is configured.

---

# Labeling Conventions

## Traefik Discovery

Public services:
traefik.group=public

Admin services:
traefik.group=admin

All routed services must also include:
traefik.enable=true

---

## Catalog Visibility

To list a service in Service Catalog:
catalog.enable=true

Optional:
catalog.name=Friendly Name  
catalog.description=Short description  
catalog.health.port=PORT

---

# DNS Strategy

Recommended approach:

Use AdGuard DNS rewrite:

\*.hh → ${LAN_IP}

This enables wildcard internal routing without editing `/etc/hosts`.

Note:
`/etc/hosts` does NOT support wildcard domains.

---

# Startup Procedure

From project root:

docker compose up -d

To recreate a single service:

docker compose up -d --force-recreate <service_name>

To restart Portainer after timeout:

docker restart portainer

---

# Security Model

## Public Services

- Only accessible through Cloudflare tunnel
- Not directly bound to host ports
- Must explicitly opt-in via traefik.group=public

## Admin Services

- Bound only to LAN IP
- Require internal DNS resolution
- Not reachable from WAN

## Docker API

- Restricted through docker-socket-proxy
- Only minimal permissions granted
- Portainer intentionally has full access for management purposes

---

# Troubleshooting

## Portainer stuck on "Loading Portainer..."

Likely caused by subpath routing.
Use host routing instead:
http://portainer.hh

## Portainer setup timed out

Restart container:
docker restart portainer

## Service not appearing in Traefik

Ensure:

- traefik.enable=true
- Correct traefik.group label
- Container connected to correct network

## Service not appearing in Catalog

Ensure:
catalog.enable=true

---

# Extending the Stack

To add a new admin service:

1. Connect it to `admin_proxy`
2. Add labels:
   traefik.enable=true
   traefik.group=admin
3. Add routing rule:
   traefik.http.routers.<name>.rule=Host(`<name>.hh`)
4. Optionally enable catalog listing

To add a new public service:

1. Connect it to `public_proxy`
2. Add labels:
   traefik.enable=true
   traefik.group=public
3. Configure Cloudflare DNS as needed

---

# Environment Variables

Required in `.env`:

LAN_IP=192.168.x.x  
TUNNEL_TOKEN=<cloudflare-token>

---

# Design Goals

- Explicit exposure (no implicit routing)
- Network separation between public and admin
- Wildcard internal DNS
- Minimal Docker API exposure
- Service self-registration via labels
- Easy horizontal expansion

---

# Summary

This stack provides:

- Clean separation of WAN and LAN traffic
- Centralized internal routing
- Automatic service discovery
- Wildcard internal domains
- Secure Docker management
- Expandable microservice-friendly foundation

It is designed to scale while maintaining strict control over service exposure and network boundaries.
