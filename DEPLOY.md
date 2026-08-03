# Deploying 9Router on Dokploy via a Tailscale sidecar

9Router is reachable only from your tailnet. Nothing is published to the host,
no Traefik route is created, no public DNS record exists, and your other
projects on the VPS are unaffected.

## Why this shape

`tailscale serve` terminates TLS and proxies to `127.0.0.1:20128` inside a
shared network namespace. 9Router grants **local** requests privileged access:
keyless `/v1`, password reset, process-spawning routes. That would be a hole,
except `tailscale serve` sets `X-Forwarded-For` to the client's tailnet address
(`ipn/ipnlocal/serve.go`, `addProxyForwardedHeaders`), and 9Router's
`custom-server.js` strips any client-supplied forwarding headers before
stamping its own. The result is that remote callers are correctly treated as
remote. `verify.sh` asserts this.

Headroom stays on the docker bridge rather than in the namespace, so a
compromise of that third-party image cannot reach 9Router over loopback.

---

## 1. Tailnet preparation

In the Tailscale admin console:

1. **DNS → MagicDNS**: enabled.
2. **DNS → HTTPS Certificates**: enabled. Required for `serve` to issue a cert.
3. **Access controls**: define the tag and restrict who may reach it.

   New tailnets ship with a default rule permitting everything
   (`src: ["*"]`, `dst: ["*"]`, `ip: ["*"]`). Replace it. Recent tailnets use
   the `grants` syntax:

   ```jsonc
   {
     "tagOwners": { "tag:nine-router": ["autogroup:admin"] },
     "grants": [
       // Your devices reach the router on the serve port. Nothing else.
       {
         "src": ["autogroup:member"],
         "dst": ["tag:nine-router"],
         "ip":  ["tcp:443"],
       },
     ],
   }
   ```

   Older tailnets use `acls`, where the port belongs on `dst` and there is no
   `ip` field:

   ```jsonc
   {
     "tagOwners": { "tag:nine-router": ["autogroup:admin"] },
     "acls": [
       { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:nine-router:443"] },
     ],
   }
   ```

   Use one style or the other, not both for the same traffic.

   Two mistakes to avoid:

   - **Do not put `tag:nine-router` in `src`.** The router never initiates
     connections to your tailnet, it only receives them. A rule whose `src` and
     `dst` are both the tag grants the node access to itself and grants your
     laptops nothing.
   - **Tagged devices lose their owner's implicit access.** Once the container
     is tagged, the account that authenticated it no longer reaches it by
     default. The rule above is what restores access, so it is required, not
     optional.

   `tcp:443` is deliberate: it is the only port `tailscale serve` listens on,
   and it keeps `:20128` unreachable even though 9Router binds `0.0.0.0` inside
   the namespace.

4. **Settings → Device approval**: on.
5. **Keys → Generate auth key**: reusable, non-ephemeral, tagged `tag:nine-router`.
   Copy it; it is shown once.
6. MFA on the identity provider backing your Tailscale account.

Tagged nodes have key expiry disabled, which is what lets the stack sit
stopped for months and come back without re-authentication.

## 2. Dokploy project

1. **Create → Compose**. Name it `9router`.
2. **Paste `docker-compose.yml`** from this directory.
3. **Advanced → Isolated Deployments: OFF.** It injects a `networks:` key into
   every service, which is invalid alongside `network_mode` and will fail the
   deploy.
4. **Do not add a domain.** No Traefik router, no `dokploy-network`. That is
   the point.

## 3. File mount for the serve config

**Advanced → Volumes → Add File Mount**. Two fields, both required:

| Field | Value |
| --- | --- |
| **File Path** | `serve.json` |
| **Content** | the contents of `serve.json` from this repository |

File Path is a bare filename. No leading slash, no directory, no `../files/`
prefix. Dokploy writes it to `<project>/files/serve.json`, which is why
`docker-compose.yml` mounts it as `../files/serve.json`.

Confirm the path Dokploy reports after saving. If your version places it
elsewhere, adjust the volume line in `docker-compose.yml` to match.

**Do not mount the repository's `serve.json` directly.** It is committed here
so the configuration is versioned and reviewable, but Dokploy runs `git clone`
into a cleaned directory on every deployment, so a mount like
`./serve.json:/config/serve.json` works once and then breaks. With the
scheduled redeploy job in section 7, that happens on a cron. File Mounts live
outside the cloned directory and survive.

## 4. Environment variables

**Environment tab**. These live in Dokploy, never in a file on the server:

```
TS_AUTHKEY=tskey-auth-...
JWT_SECRET=<openssl rand -hex 32>
INITIAL_PASSWORD=<a real password>
```

`INITIAL_PASSWORD` is not optional. 9Router falls back to `123456` when it is
unset. It is bootstrap-only: once you set a password in the dashboard, that
bcrypt hash in SQLite takes precedence.

## 5. Deploy and verify

Deploy, then confirm the sidecar actually came up. Dokploy renders every
stderr line as an error and `tailscaled` logs everything to stderr, so read
the state rather than the log colour:

```bash
docker ps --format '{{.Names}}' | grep -i tailscale
docker exec <name> tailscale status         # node active, has an address
docker exec <name> tailscale serve status   # https://... -> http://127.0.0.1:20128
```

### Expected log noise

These appear on every start and are not faults:

| Message | Why |
| --- | --- |
| `tstun: error initializing tun dev stats polling: no such device` | Userspace mode has no TUN device to poll. |
| `magicsock: failed to force-set UDP read/write buffer size ... operation not permitted` | Raising socket buffers needs `NET_ADMIN`, which is deliberately not granted. Affects throughput only. |
| `health(wantrunning-false): Tailscale is stopped.` | Logged before `tailscale up` runs. |
| `health(warming-up): Tailscale is starting.` | Transient. |
| `control: lite map update error ... 409: superseded by another update` | Two control-plane map requests raced at startup. Harmless once; investigate only if it repeats. |
| Headroom printing `Claude Code: ANTHROPIC_BASE_URL=...` | Its usage banner, written to stderr. Means it is up. |

### If nothing routes

- **Device approval.** Section 1 turns it on, so a freshly authenticated node
  sits unapproved and unreachable until you approve it under **Machines**.
  This is the usual cause.
- **No certificate.** `serve` fetches it lazily on the first HTTPS request, so
  a slow first load is normal. If it never issues, **DNS → HTTPS Certificates**
  is off.
- **Connection refused through `serve`.** 9Router is still starting; it boots
  slower than the sidecar.

Then, from a machine on the tailnet:

```bash
./verify.sh 9router.<your-tailnet>.ts.net
```

Expected: `/v1/models` → 401, `/api/mcp/` → 403, `/api/settings` → 401,
`/dashboard` → 307. A 200 on the first check means the loopback hop leaked
local privileges. Stop and fix before connecting any provider.

On the VPS itself:

```bash
ss -tlnp | grep -E '20128|8787'   # expect no output
```

## 6. First login and clients

1. Open `https://9router.<your-tailnet>.ts.net`, log in with
   `INITIAL_PASSWORD`, change the password immediately.
2. Connect providers. Dashboard → Providers.
3. Dashboard → generate an API key.
4. Enable Headroom: Endpoint → Token Saver → Headroom. The URL should already
   read `http://headroom:8787`; recheck status, then enable.

Client configuration (Windows and macOS both run Tailscale natively):

```
Endpoint: https://9router.<your-tailnet>.ts.net/v1
API Key:  <from the dashboard>
```

## 7. Auto-update

You cannot webhook this. Docker Hub webhooks are configured by the repository
owner, and `decolua/9router` is not yours, so there is no push event to
subscribe to. Watchtower would work but requires mounting the Docker socket,
which is root-equivalent on a host running your other projects. Not worth it.

Polling instead. **Dokploy → Schedule Jobs → Create**:

- Schedule: `0 */6 * * *` (adjust to taste)
- Command:

  ```bash
  curl -fsS -X POST 'https://<your-dokploy-panel>/api/compose.deploy' \
    -H 'x-api-key: <dokploy-api-key>' \
    -H 'Content-Type: application/json' \
    -d '{"composeId":"<composeId from the project URL>"}'
  ```

`pull_policy: always` in the compose file makes the re-pull explicit rather
than incidental. Confirm the exact endpoint name against your panel's
`/swagger`. It has been `compose.deploy` in recent versions.

**Understand what you turned on.** Tracking `:latest` with an unattended
redeploy means an upstream compromise reaches your provider OAuth tokens
without review. If that stops being acceptable, pin a version tag and drop
the scheduled job.

## Stopping and restarting

Dokploy Stop halts the containers; volumes persist.

| Volume | Contents |
|---|---|
| `9router-data` | `db/data.sqlite`, provider OAuth tokens, API keys, `jwt-secret`, certs, backups |
| `tailscale-state` | node identity, serve config, TLS certificate |

Start returns the same tailnet hostname, the same certificate, and the same
configuration. The auth key is consumed only on first run.

Do not delete these volumes. `9router-data` is your entire configuration; if
`JWT_SECRET` were ever unset, it would also hold the auto-generated secret.

## Notes

- The dashboard is also reachable at `http://<tailnet-ip>:20128`, bypassing
  `serve`. Still safe, since the peer address is non-loopback and so carries
  no local privileges, but the ACL above restricts the tailnet to `:443`
  anyway.
- `REQUIRE_API_KEY` appears in upstream's `.env.example` and is dead code: no
  references anywhere in `src/`. API-key enforcement on `/v1` for remote
  callers is unconditional. Do not rely on that variable.
- `NEXT_PUBLIC_*` variables are baked in at image build time and cannot be
  overridden at runtime in a prebuilt image. Left at defaults.
- Design rationale and the rejected alternatives are in [docs/DESIGN.md](docs/DESIGN.md).
