# A container with its own Tailscale node

Giving one Docker service its own identity in the tailnet, so that node sharing
exposes only that service and not the machine it runs on.

Worked example: a self-hosted chat server with a TURN relay, shared with one
external person. All names and IPs are examples.

Read section 7 before building on this: tailnet-only publishing means every
client needs Tailscale running permanently, including on the local network.

---

## 1. Why

Node sharing hands out a whole node, never a single port. A service on the main
server's native Tailscale means sharing the node that runs everything else, and
on a subnet router also a path into the LAN. An ACL restricts that, but then the
home network depends on one ACL staying correct.

Tailscale as a container gives the service its own node on the same hardware.
Sharing it exposes no other service, no SSH, no subnet route. The service also
occupies no host port.

## 2. Layout

```
                       chat_tailscale  (node calc.<tailnet>.ts.net)
                       ├─ tailscale serve :443 ──► 127.0.0.1:8080
  phone ─ WireGuard ───┤
                       ├─ chat_server        (network_mode: service:tailscale)
                       └─ chat_coturn :3478  (network_mode: service:tailscale)
```

Three containers, one network namespace — the Tailscale container's.
`tailscale serve` terminates TLS with a Let's Encrypt certificate and proxies to
loopback. The app never sees a certificate.

Needs MagicDNS and HTTPS Certificates enabled in the tailnet; the first is a
precondition for the second.

```
/srv/docker/chat/
├── docker-compose.yml           # upstream, unchanged
├── docker-compose.override.yml  # the delta
├── .env                         # TS_AUTHKEY, TS_IP, TURN_USER, TURN_PASS (0600)
├── data/                        # owned by uid 1000
└── tailscale/
    ├── state/                   # node identity, must persist
    └── serve.json
```

## 3. Configuration

Compose delta: [`files/chat-compose-override.yml`](files/chat-compose-override.yml).
An override keeps the upstream file untouched, and keeps a project's own smoke
test unaffected as long as that test passes its `-f` files explicitly.

`tailscale/serve.json`, with `${TS_CERT_DOMAIN}` substituted by the entrypoint:

```json
{
  "TCP": { "443": { "HTTPS": true } },
  "Web": {
    "${TS_CERT_DOMAIN}:443": {
      "Handlers": { "/": { "Proxy": "http://127.0.0.1:8080" } }
    }
  }
}
```

Bring-up is two-stage: coturn needs the node's address, which does not exist
before the node has joined.

```sh
docker compose up -d --build tailscale chat
docker compose exec tailscale tailscale ip -4      # write into .env as TS_IP
docker compose up -d
```

Auth key from Settings → Keys: not reusable, not ephemeral. An ephemeral node
disappears as soon as it goes offline. After the node has joined, set **Disable
key expiry** on it, or the service drops off the tailnet months later without
warning.

## 4. Pitfalls

**`TS_USERSPACE: "false"`.** The image defaults to userspace networking, where
only traffic proxied through `serve` reaches the namespace. The web app works,
the TURN ports do not, and calls ring without connecting. Needs
`/dev/net/tun` and `cap_add: net_admin` alongside.

**Removing `ports:` drops the loopback binding.** `network_mode: service:`
forbids published ports, but `127.0.0.1:8080:8080` was what pinned the app to
loopback. A server listening on `:8080` is then reachable on the node's
Tailscale address, unencrypted and without a secure context. Set the listen
address explicitly (`LISTEN=127.0.0.1:8080`) and check:

```sh
docker compose exec tailscale ss -tulnH | grep 8080    # 127.0.0.1:8080
```

**Debian 13 has no `ip_tables` module.** The host is nftables-only, its
`iptables` is the `xtables-nft-multi` shim. The container ships legacy iptables
and picks it by itself (`router: default choosing iptables`), fails with
`can't initialize iptables table 'filter'` and leaves `wgengine: Reconfig:
router config failed` as a permanent health error. Both of these are required;
either alone only changes the message:

```yaml
TS_DEBUG_FIREWALL_MODE: nftables
volumes:
  - /lib/modules:/lib/modules:ro
```

**`--no-dtls` does not exist in coturn 4.18.** `turnserver` refuses to start,
prints its help and restart-loops. Use `--no-tls`; DTLS listeners do not come up
without a certificate. `--no-cli` is deprecated, see `--cli`.

**A smoke test may assume an unconfigured environment.** Compose loads `.env`
from the project directory, so a test asserting "calls off when TURN_HOST is
unset" fails once a real `.env` exists. Shell variables win over `.env`:

```sh
TS_IP= TURN_USER= TURN_PASS= ./scripts/smoke.sh
```

## 5. ACL

Two grants. `grants` makes the tailnet default-deny, so only what is listed is
reachable.

```jsonc
"hosts": { "calc": "100.101.1.40" },      // a bare node name is not resolved in dst

"grants": [
    { "src": ["autogroup:shared"], "dst": ["calc"],
      "ip": ["tcp:443", "tcp:3478", "udp:3478", "udp:49160-49200"] },
    { "src": ["phone"],            "dst": ["calc"],
      "ip": ["tcp:443", "tcp:3478", "udp:3478", "udp:49160-49200"] },
]
```

The grant for your own phone is not optional. The app is reached by its MagicDNS
name, which resolves to the Tailscale address, so the traffic goes through
WireGuard and is filtered even on the same WLAN.

The ACL is also what keeps the TURN relay from becoming a stepping stone. coturn
denies RFC1918 peers but allows all of `100.64.0.0/10`, every tailnet address
included. No grant has the chat node as `src`, so traffic originating there is
dropped. Verify on the receiving node, where it must not appear as a source:

```sh
docker compose exec tailscale tailscale debug netmap | jq .PacketFilter
```

Set the ACL before sharing the node.

## 6. Host DNS

Enabling MagicDNS is tailnet-wide. Every node with `accept-dns` on gets its
`/etc/resolv.conf` rewritten to `100.100.100.100`, including Docker containers
that inherit DNS from the host. On a server running other services, freeze DNS
first:

```sh
sudo tailscale set --accept-dns=false
cat /etc/resolv.conf          # still the router
```

That host can then no longer resolve MagicDNS names. Health checks must not use
the URL:

```sh
docker inspect --format '{{.State.Health.Status}}' chat_server
```

## 7. Limitation: clients need Tailscale running

`tailscale serve` publishes tailnet-only. No address on the open internet, and
therefore Tailscale running on every client permanently, including at home on
the same WLAN. Without it the app does not load and no messages arrive — there
is no background delivery through a third-party push service.

For an occasional remote service that is fine. For an app used many times a day
on the local network it is the deciding drawback.

The requirement splits in two:

- The outside person needs a remote path. Node sharing covers it: no port
  forwarding, no public exposure, revocable in one click.
- At home, no VPN. That needs a second path over the LAN, with a certificate,
  because camera, microphone, WebRTC and `crypto.subtle` need a secure context.

| Second path | Trade-off |
|---|---|
| `tailscale funnel` | Public exposure |
| Public DNS name for a private IP, Let's Encrypt DNS-01, LAN reverse proxy | Needs a domain and DNS-01 automation; internal names appear in certificate transparency logs |
| Own CA (`mkcert`), trusted on both phones | Offline, no public footprint; installing a CA on a phone is a risk, and a shared guest cannot use it |

Both paths serve the same container, only the TLS front end differs.

## 8. Measured

Raspberry Pi 4, 4 GB, Debian 13, Docker 29.8 / Compose v5.5.

| | |
|---|---|
| Build, Go static into `scratch` | 3 min 45 s natively on the Pi |
| Memory, whole stack idle | 31 MB (app 2.4, coturn 5.4, tailscaled 23.4) |
| Host ports occupied | none |
| Certificate | Let's Encrypt via ACME dns-01, renewed by the container |

`FROM scratch` with a static binary has no base OS to patch, so a monthly
rebuild is pointless. Only `tailscale` and `coturn` need pulling, and replacing
the Tailscale container takes the whole stack down for a moment because the
others share its namespace:

```sh
docker compose pull tailscale coturn
docker compose up -d --force-recreate
```

## 9. Teardown

```sh
cd /srv/docker/chat
docker compose down
docker image rm chat-chat
```

Then, in order:

1. Machines → the node → Remove. The identity in `tailscale/state` is dead
   afterwards.
2. Revert the ACL: drop the `hosts` entry and both grants.
3. DNS → disable HTTPS Certificates, then MagicDNS.
4. On the host: `sudo tailscale set --accept-dns=true`.
5. Settings → Keys → revoke the auth key if still listed.

Keep `/srv/docker/chat/data/` if the content matters — database and media.
