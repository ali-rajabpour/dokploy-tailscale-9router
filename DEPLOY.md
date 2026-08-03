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

   ```jsonc
   {
     "tagOwners": { "tag:nine-router": ["autogroup:admin"] },
     "acls": [
       // Only your own devices, only the serve port.
       { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:nine-router:443"] }
     ]
   }
   ```

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

**Advanced → Volumes → Add File Mount**:

- Content: the contents of `serve.json` from this directory
- File path: `serve.json`

Dokploy writes it into the project's `files/` directory, which the compose
file references as `../files/serve.json`. Confirm the resulting path shown in
the Dokploy UI matches; if your Dokploy version places it elsewhere, adjust
the volume line in `docker-compose.yml` to match.

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

Deploy. Then, from a machine on the tailnet:

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
