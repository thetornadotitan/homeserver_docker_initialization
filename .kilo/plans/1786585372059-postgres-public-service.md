# Plan: Public-facing Postgres via Traefik Public (TCP)

## Goal
Add a Postgres server reachable from the internet through the existing public edge
(Cloudflare Tunnel -> Traefik Public), with hardened non-default credentials so random
actors cannot authenticate.

## Key architectural finding (surface before implementing)
Traefik Public (`traefik_public`) and the Cloudflare tunnel are **HTTP-only**:
- `traefik_public` has a single entrypoint `web` on `:80` (foundations/docker-compose.yml:11).
- `cloudflared` forwards HTTP to `http://traefik_public:80` (foundations/docker-compose.yml:26-36).

Postgres is a **TCP** protocol with no HTTP `Host` header, so it cannot ride the HTTP route.
Exposing it through Traefik Public requires a dedicated **TCP entrypoint** on `traefik_public`
plus a **TCP router** on the postgres service. The user chose this path ("I want it through trafik").

## Decision: Route via Traefik TCP entrypoint
- Add a `postgres` TCP entrypoint (`:5432`) to `traefik_public` in `foundations/docker-compose.yml`.
- No host port publish on traefik_public — the tunnel reaches it over `public_proxy` by container
  name (consistent with the "public services are not directly bound to host ports" security model).
- Postgres joins `public_proxy` and carries `traefik.group=public` + TCP router labels so
  `traefik_public` discovers it (constraint `Label(traefik.group,public)`, foundations/docker-compose.yml:12).

## Cloudflare route (user already set correctly)
- `ps.isaachisey.com` -> `tcp://traefik_public:5432`  ✅
- Uses the container name `traefik_public` (resolved via Docker DNS on `public_proxy`, same as the
  working HTTP route `http://traefik_public:80`), not `localhost`. No change needed.

## Decisions (resolved)
- **TLS**: None for now (user selected). Cloudflare tunnel already encrypts the internet leg;
  strong auth is the primary defense. Document TLS as optional future hardening.
- **Placement**: New static compose project `services/postgres/` (matches `mysql`, `searxng`,
  `home-assistant` convention; auto-managed by `deployd`). Foundations gets only the TCP entrypoint.
  Do NOT create a shared-compose abstraction (YAGNI/KISS); follow the existing per-service convention.
- **Port/entrypoint**: `postgres` TCP entrypoint on `:5432`; no host `ports:` publish anywhere.
- **Credentials**: Dedicated non-default superuser via `POSTGRES_USER` + strong random
  `POSTGRES_PASSWORD` in a gitignored `.env`. The default `postgres` superuser stays present but has
  no password under `scram-sha-256`, so default creds cannot authenticate.
- **deployd**: `services/postgres/` will be auto-brought up by deployd once present. The
  traefik_public entrypoint change lives in `foundations/` (not deployd-managed) and needs one manual recreate.

## Files to change

### 1. EDIT `foundations/docker-compose.yml` — traefik_public TCP entrypoint
Add to the `traefik_public.command` list (around line 11):
```
      - --entrypoints.postgres.address=:5432
```
No host port publish on traefik_public (tunnel reaches via network).

### 2. NEW `services/postgres/docker-compose.yml`
```yaml
services:
  postgres:
    image: postgres:17
    container_name: postgres
    restart: unless-stopped
    networks:
      - public_proxy
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_HOST_AUTH_METHOD=scram-sha-256
    volumes:
      - ./postgres/data:/var/lib/postgresql/data
      - ./postgres/init:/docker-entrypoint-initdb.d   # optional least-privilege app user
    labels:
      - catalog.enable=false
      - catalog.name=Postgres
      - catalog.description=Public Postgres 17 (TCP via Traefik Public + Cloudflare tunnel).
      # --- Traefik Public TCP discovery ---
      - traefik.enable=true
      - traefik.group=public
      - traefik.tcp.routers.postgres.rule=HostSNI(`*`)
      - traefik.tcp.routers.postgres.entrypoints=postgres
      - traefik.tcp.routers.postgres.service=postgres
      - traefik.tcp.services.postgres.loadbalancer.server.port=5432

networks:
  public_proxy:
    external: true
    name: public_proxy
```
Notes:
- No host `ports:` publish — external access is tunnel-only (security model).
- `traefik.group=public` matches `traefik_public`'s constraint (foundations/docker-compose.yml:12),
  so it is discovered by Traefik Public, not Admin.
- `HostSNI(\`*\`)` matches any SNI for raw TCP pass-through to Postgres.
- `POSTGRES_HOST_AUTH_METHOD=scram-sha-256` forces scram auth explicitly.

### 3. NEW `services/postgres/.env.example` (committed, safe)
Placeholders + generation command. Do NOT commit real values.
```
POSTGRES_USER=put-a-random-non-default-username
POSTGRES_PASSWORD=put-a-strong-random-password
POSTGRES_DB=appdb
# generate:  openssl rand -base64 24
#            openssl rand -hex 8   (for a random username)
```

### 4. NEW `services/postgres/.env` (gitignored by `**/**.env`)
Real generated credentials, created at deploy time, never committed.

### 5. Optional: `services/postgres/init/` SQL
If a least-privilege app user is desired, add an init `.sql` that creates an app role with
`LOGIN` + limited privileges distinct from the superuser. Skip for now (KISS): a single strong
user is sufficient for a personal stack.

## Deployment steps (ordered)
1. Generate credentials into `services/postgres/.env` (gitignored):
   `openssl rand -base64 24` for password; a random non-default username. Confirm `git status`
   does not list `.env`.
2. Edit `foundations/docker-compose.yml` to add the `postgres` TCP entrypoint to traefik_public.
3. Recreate Traefik Public (foundations is not deployd-managed):
   `cd foundations && docker compose up -d --force-recreate traefik_public`
4. Create the postgres project and start it (deployd will also auto-manage it once present):
   `docker compose -f services/postgres/docker-compose.yml up -d`
5. Cloudflare dashboard: TCP route `ps.isaachisey.com` -> `tcp://traefik_public:5432` is already set
   (correct). No further Cloudflare change needed.
6. Verify (validation section below).

## Validation
- `docker compose -f services/postgres/docker-compose.yml config` — compose file valid.
- `docker logs traefik_public` — shows the `postgres` entrypoint listening on `:5432`.
- Local check: `docker exec postgres psql -U <POSTGRES_USER> -d <POSTGRES_DB> -c 'select version()'`.
- Remote check (no TLS, tunnel encrypts WAN leg):
  `psql "postgresql://<user>:<pass>@ps.isaachisey.com:5432/<db>?sslmode=prefer"`
- Negative check: connecting with the default `postgres` user / no password must FAIL (scram).
- `git status` — `.env` not tracked.

## Risks / future hardening (out of scope for this plan)
- Public DB exposure carries brute-force / DoS risk even with strong auth. Stronger option:
  Cloudflare Access (Zero Trust) or IP allow-list in front of the TCP route.
- Traefik TCP pass-through does no auth; protection is purely Postgres scram auth.
- TLS: enable later for the LAN leg (tunnel leg is already encrypted).
- Rotate password / store in a secrets manager instead of `.env` (gitignored file).
