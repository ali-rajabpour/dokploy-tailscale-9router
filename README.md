# dokploy-tailscale-9router

A hardened [9Router](https://github.com/decolua/9router) deployment for
[Dokploy](https://dokploy.com), reachable only over a private
[Tailscale](https://tailscale.com) network.

No public DNS record. No Traefik route. No ports published on the host. Nothing
about the rest of your server changes.

---

## Why this exists

I run a self-hosted VPS with Dokploy, hosting a number of unrelated production
projects. I wanted 9Router on it: an AI router that fronts Claude Code,
Cursor, Copilot, and friends, giving them fallback across providers and
compressing tool output to save tokens.

Four problems got in the way.

**1. The upstream compose file does not work on Dokploy.** Dokploy routes
traffic through Traefik, which needs Docker labels and a shared network on
every service it serves. The official `docker-compose.yml` has neither, and
it sets `container_name`, which Dokploy's own documentation warns breaks logs
and metrics.

**2. I could not convince myself it was safe to expose.** This is the part
that changed the design. 9Router's SQLite database holds live OAuth tokens for
every provider you connect. Losing it means someone else spending your Claude
and Copilot subscriptions, and walking away with the tokens.

I read the upstream authorization model rather than trusting the README, and
it is genuinely well built: deny-by-default on `/api/*`, JWT on the dashboard,
progressive login lockout, and a set of process-spawning routes restricted to
local callers with client-supplied forwarding headers stripped so they cannot
be spoofed.

But one thing does not go away. The `/v1` endpoint has to stay reachable by
IDEs and CLI tools that speak plain HTTP with a bearer token. No identity proxy
can gate that path without breaking every client. Cloudflare Access, Zero
Trust, an OAuth proxy; all of them end up with a bypass rule on `/v1`, and
you are back to a single API key standing between the public internet and your
provider tokens. Cloudflare Tunnel has a second problem for this workload:
TLS terminates at their edge, so every prompt, every file your agent reads, and
every token passes through their infrastructure in plaintext.

The honest fix is not to expose it at all.

**3. I wanted upstream updates without babysitting.** The usual answer,
Watchtower, wants the Docker socket mounted. On a box running everything else
I own, that is root-equivalent access traded for update convenience. No.

**4. I stop this service when I am not using it.** Restarting had to bring
back the same configuration, the same provider logins, and the same hostname,
not a fresh install asking me to reconnect eleven providers.

## What this repository does about it

9Router runs inside a Tailscale sidecar's network namespace. `tailscale serve`
terminates TLS and forwards to it over loopback. The service is reachable at
`https://9router.<your-tailnet>.ts.net` from your own devices and from nowhere
else.

```
tailnet ──TLS 443──> [tailscale sidecar] ──127.0.0.1:20128──> [9router]
                            │  (shared netns)                     │
                            └── docker bridge ────────────> [headroom :8787]
```

- **Your host's networking is untouched.** `tailscale0` exists only inside the
  container namespace. No root daemon, no rewritten `/etc/resolv.conf`, no new
  firewall chains, nothing left behind if you delete the stack. The sidecar
  runs in userspace mode, so it needs neither `NET_ADMIN` nor `/dev/net/tun`.
- **Traefik is not involved at all.** The label problem disappears rather than
  getting solved.
- **Two layers on every request.** Tailnet membership, then 9Router's own
  password and API key.
- **Updates poll instead of listening.** A Dokploy scheduled job calls
  Dokploy's own API to redeploy. No Docker socket exposed.
- **State survives.** Named volumes keep the database, provider tokens, node
  identity, and TLS certificate across stop/start cycles.

### The subtle part

Proxying over loopback is exactly the thing that could have broken this.
9Router grants *local* requests elevated access: `/v1` without an API key,
plus password reset and the process-spawning routes. A naive loopback proxy
would hand every tailnet visitor those privileges.

It holds because `tailscale serve` sets `X-Forwarded-For` to the client's
tailnet address unconditionally (`ipn/ipnlocal/serve.go`,
`addProxyForwardedHeaders`), and 9Router's `custom-server.js` strips any
client-supplied forwarding headers before stamping its own. Remote callers stay
remote:

```
client 100.x → serve (TLS :443) → XFF=100.x, X-Forwarded-Proto=https
  → 127.0.0.1:20128 → strips spoofed headers, stamps x-9r-via-proxy=1
  → isLocalRequest() = false
```

`verify.sh` asserts this after every deploy. If those checks ever fail, the
central assumption has broken and you should stop before connecting providers.

Two incidental wins over fronting it with Traefik: login rate limiting gets
real per-client buckets instead of collapsing every caller into one, and
`X-Forwarded-Proto: https` makes secure cookies behave correctly.

Headroom deliberately stays on the Docker bridge rather than in the shared
namespace. Inside it, that third-party image could reach 9Router over loopback
with no forwarding header and inherit local privileges. On the bridge it is
treated as the remote client it is.

## Contents

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | The stack: Tailscale sidecar, 9Router, Headroom |
| `serve.json` | `tailscale serve` configuration, mounted via Dokploy |
| `.env.example` | The three required secrets |
| `verify.sh` | Post-deploy assertions that privileges did not leak |
| `DEPLOY.md` | Full runbook |
| `docs/DESIGN.md` | Design rationale, upstream review, rejected alternatives |

## Quick start

1. In the Tailscale admin console, enable MagicDNS and HTTPS Certificates, then
   replace the default allow-everything policy with:

   ```jsonc
   {
     "tagOwners": { "tag:nine-router": ["autogroup:admin"] },
     "grants": [
       {
         "src": ["autogroup:member"],
         "dst": ["tag:nine-router"],
         "ip":  ["tcp:443"],
       },
     ],
   }
   ```

   The tag goes in `dst` only. Putting it in `src` as well grants the node
   access to itself and your own machines nothing. On older tailnets that use
   `acls` instead of `grants`, see [DEPLOY.md](DEPLOY.md) for the equivalent.

   Then generate a reusable, non-ephemeral auth key carrying `tag:nine-router`.
2. Create a Dokploy **Compose** project from this repository. Leave
   **Isolated Deployments off**, because it injects a `networks:` key that is
   invalid alongside `network_mode`.
3. Add `serve.json` as a Dokploy File Mount.
4. Set `TS_AUTHKEY`, `JWT_SECRET`, and `INITIAL_PASSWORD` in the Environment
   tab.
5. Deploy, then run `./verify.sh 9router.<your-tailnet>.ts.net`.

Full instructions, including the ACL, the update job, and client
configuration, are in [DEPLOY.md](DEPLOY.md).

> `INITIAL_PASSWORD` is not optional. 9Router falls back to `123456` when it is
> unset.

## Requirements

- A VPS running Dokploy
- A Tailscale account (the free tier is sufficient)
- Tailscale installed on each client machine. Windows, macOS, Linux, iOS, and
  Android all have first-class clients

## Trade-offs

Every device that uses 9Router must be on your tailnet. That is the cost of
the design, and for a single-operator setup it is a small one. If you need
access from a machine where you cannot install Tailscale, this repository is
not the right starting point.

Tracking `:latest` with an unattended redeploy means an upstream compromise
reaches your provider tokens without review. Pin a version tag and drop the
scheduled job if that trade is not one you want.

## Acknowledgements

- [9Router](https://github.com/decolua/9router) by decolua
- [Headroom](https://github.com/chopratejas/headroom) by chopratejas
- [Dokploy](https://dokploy.com) and [Tailscale](https://tailscale.com)

This project is not affiliated with or endorsed by any of them.

## Author

**Ali Rajabpour Sanati**
[Rajabpour.com](https://Rajabpour.com)

## License

[MIT](LICENSE) © Ali Rajabpour Sanati
