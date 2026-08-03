# Design notes

Why this deployment looks the way it does, what was rejected, and what to
re-check if upstream changes.

## Requirements

Run 9Router on a Dokploy-managed VPS that already hosts unrelated production
projects. Reachable from Windows and macOS desktop clients and their IDEs.
Automatic updates from upstream. Configuration and credentials must survive
stop/start cycles. Single operator.

Security was the binding constraint: the deployment was to be abandoned if it
could not be made safe.

## Upstream review

Read from source at `decolua/9router@master` rather than from documentation.
`src/dashboardGuard.js` implements the entire authorization model:

- `/api/*` is deny-by-default with a short public allow-list (`/api/health`,
  `/api/init`, `/api/auth/login`, `/api/version`, …).
- `/dashboard/*` requires a JWT cookie. `requireLogin` defaults to `true`
  (`src/lib/db/repos/settingsRepo.js:20`).
- `/v1`, `/v1beta`, `/api/v1`, and `/codex` are public prefixes, but remote
  callers must present a valid API key. Loopback callers bypass that check.
- `LOCAL_ONLY_PATHS` — routes that spawn child processes or read host secrets
  (`/api/mcp/`, `/api/cli-tools/*`, `/api/tunnel/*`, `/api/auth/reset-password`,
  `/api/headroom/*`) — returns 403 to anything not local.
- `custom-server.js` deletes client-supplied `x-9r-real-ip`, `x-9r-via-proxy`,
  and `x-forwarded-for` before stamping values derived from the TCP socket, so
  header spoofing cannot forge a loopback origin.
- `src/lib/auth/loginLimiter.js` applies progressive lockout: five failures,
  then 30s / 2m / 10m / 30m.

Findings that shaped the design:

1. `INITIAL_PASSWORD` falls back to `123456`. Must be set explicitly.
2. `JWT_SECRET`, when unset, is generated into `$DATA_DIR/jwt-secret` — safe
   only while the volume persists.
3. `REQUIRE_API_KEY` is documented in upstream's `.env.example` but has **no
   references anywhere in `src/`**. It is dead. API-key enforcement for remote
   `/v1` callers is unconditional and does not depend on it. Do not rely on
   that variable.
4. Blast radius is high. The database holds OAuth tokens for Claude, Copilot,
   Cursor, and Kiro. Compromise means subscription abuse and token theft.
5. Behind a shared reverse proxy the login limiter keys on the proxy's address,
   collapsing every client into one bucket. Tolerable for one user, but an
   argument against fronting the service with Traefik.

Conclusion: safe to run, given a strong bootstrap password and a persistent
volume — provided it is not exposed publicly.

## Options considered

| Option | Verdict |
| --- | --- |
| Public domain, Traefik, 9Router auth only | Rejected. One layer in front of live provider OAuth tokens. |
| Public domain + Cloudflare Access on dashboard paths | Rejected. Leaks the origin IP, and `:443` answers the world — anyone who finds the address reaches every other vhost on the box directly. |
| Cloudflare Tunnel + Access | Rejected. IDEs cannot carry Access identity, so `/v1` needs a bypass rule and reverts to API-key-only. Decisive objection: TLS terminates at Cloudflare's edge, so prompts, source, and tokens transit their infrastructure in plaintext. |
| Tailscale installed on the host | Rejected. Adds a root daemon and rewrites `/etc/resolv.conf` on a production server. |
| **Tailscale as a sidecar container** | **Chosen.** |

The deciding argument: in every publicly-exposed option, `/v1` must stay
reachable by clients that authenticate with a bearer token alone, so no
identity proxy can gate it. Tailnet membership is the only mechanism that
removes the exposure without breaking the clients.

## Architecture

```
tailnet ──TLS 443──> [tailscale sidecar] ──127.0.0.1:20128──> [9router]
                            │  (shared netns)                     │
                            └── docker bridge ────────────> [headroom :8787]
```

One Dokploy Compose stack, three containers, no published host ports, no
Traefik route, no `dokploy-network`, no public DNS record.

### Namespace sharing

9Router runs with `network_mode: "service:tailscale"`. The `tailscale0`
interface exists only inside that namespace, leaving the host's routing table,
resolver configuration, firewall, and Docker's iptables chains untouched.
Deleting the stack leaves nothing behind.

For reference, a host-level install would have touched: addresses from
`100.64.0.0/10` (no overlap with Docker's ranges), MagicDNS rewriting
`/etc/resolv.conf`, and new `ts-input` / `ts-forward` / `ts-postrouting`
firewall chains. The default route would have been unaffected unless an exit
node was configured. The sidecar makes all of that moot.

### The loopback privilege question

`tailscale serve` proxies over loopback, and 9Router grants local requests
elevated access. This is safe only because `serve` sets forwarding headers.
Verified in `tailscale/tailscale`, `ipn/ipnlocal/serve.go`:
`addProxyForwardedHeaders` is called unconditionally from the proxy's `Rewrite`
hook and sets `X-Forwarded-For` to the client's tailnet address along with
`X-Forwarded-Proto: https`.

```
client 100.x → serve (TLS :443) → XFF=100.x, XFP=https
  → 127.0.0.1:20128 → custom-server.js: loopback peer + XFF present
  → stamps x-9r-real-ip=100.x, x-9r-via-proxy=1
  → dashboardGuard.isLocalRequest() = false
```

`/v1` still requires an API key and the local-only routes still return 403.
Two incidental benefits over a Traefik fronting: the rate limiter gets real
per-client buckets, and `X-Forwarded-Proto: https` makes `AUTH_COOKIE_SECURE`
behave correctly.

**If upstream changes either `custom-server.js`'s header handling or
`dashboardGuard.isLocalRequest`, re-run `verify.sh` before trusting the
deployment.**

### Headroom placement

Headroom stays outside the shared namespace on purpose. Inside it, it could
reach `127.0.0.1:20128` without an `X-Forwarded-For` header and be treated as
a local request — unlocking keyless `/v1`, `/api/auth/reset-password`, and the
process-spawning routes. On the Docker bridge it reaches 9Router at a
non-loopback address and is treated as remote. It is a third-party image and
gets no implicit trust.

### Least privilege

The sidecar runs in userspace mode (`TS_USERSPACE=true`), requiring neither
`NET_ADMIN` nor `/dev/net/tun`. `serve` functions normally in that mode.

## Persistence

| Volume | Contents | Rationale |
| --- | --- | --- |
| `9router-data` → `/app/data` | `db/data.sqlite`, provider OAuth tokens, API keys, `jwt-secret`, certificates, backups | the entire configuration |
| `tailscale-state` → `/var/lib/tailscale` | node identity, serve config, TLS certificate | same hostname and certificate after restart, no re-authentication |

The auth key is consumed on first run only. `--advertise-tags=tag:9router`
disables key expiry for the node, so a stack left stopped for months still
restarts cleanly.

## Updates

Registry webhooks are not possible here: Docker Hub webhooks are configured by
the repository owner, and `decolua/9router` belongs to upstream. There is no
push event to subscribe to.

Watchtower was rejected because it requires mounting the Docker socket, which
is root-equivalent on a host running unrelated production projects.

Chosen mechanism: a Dokploy scheduled job on a cron calling Dokploy's own API
to redeploy, with `pull_policy: always` making the re-pull explicit rather than
incidental.

Accepted risk: tracking `:latest` with an unattended redeploy means an upstream
compromise reaches the provider OAuth tokens without review. Mitigation if that
becomes unacceptable — pin a version tag and delete the scheduled job.

## Verification

`verify.sh` asserts, from a tailnet machine: `/v1/models` → 401, `/api/mcp/` →
403, `/api/settings` → 401, `/dashboard` → 307. A 200 on the first means the
central assumption has broken. On the host, `ss -tlnp | grep -E '20128|8787'`
must return nothing.

## To confirm against your installed versions

- Dokploy's File Mount path convention (`../files/serve.json`).
- The exact Dokploy API endpoint for compose redeploy, via the panel's
  `/swagger`.
