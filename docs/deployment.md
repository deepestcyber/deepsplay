# Deployment

deepsplay runs as a container image built by GitHub Actions and published on
the GitHub Container Registry (ADR 13):

- `ghcr.io/deepestcyber/deepsplay:<version>` and `:latest` for version tags
  (`vX.Y.Z`), `:edge` for the main branch
- for `linux/amd64` and `linux/arm64` (e.g. a Raspberry Pi 5)

## What the container needs

| What | Where | Notes |
| --- | --- | --- |
| `SECRET_KEY_BASE` | environment | required; `openssl rand -base64 48` |
| Host configuration | `/etc/deepsplay/host.toml` (read-only mount) | or set `DEEPSPLAY_CONFIG`; start from [`deploy/host.example.toml`](../deploy/host.example.toml) |
| Cache | volume at `/var/lib/deepsplay` | set `cache_dir = "/var/lib/deepsplay/cache"` |
| Secrets (optional) | file at `DEEPSPLAY_SECRETS` (read-only mount, mode 0600), or `DEEPSPLAY_SECRET_<NAME>` variables | ADR 8 |
| Port | 4000 (`PORT`) | plain HTTP; put a reverse proxy in front for HTTPS |
| Allowed origins (optional) | `DEEPSPLAY_ORIGINS` | default: the request's own host, so screens can use an IP or any name |
| Trusted reverse proxies (optional) | `DEEPSPLAY_TRUSTED_PROXIES` | IP addresses or CIDR ranges whose `X-Forwarded-Proto` is trusted; see [Behind a reverse proxy](#behind-a-reverse-proxy) |

The container runs as user `deepsplay` (uid 10001). Files mounted into it must
be readable by that user; the secrets file can stay mode 0600 if it is owned by
uid 10001.

A missing or invalid host configuration does not stop the container: every
screen and `/status` show the errors.

Backends of content repositories (ADR 26, only for configurations with
`backend = true`) are Python processes started by deepsplay in the
container. The image includes `uv`, which downloads Python and packages at
runtime into `cache_dir`, so the container needs internet access for new
backends or changed dependencies. `backend_memory` limits a backend's
memory; `tini` reaps processes they leave behind. Backends run as the
deepsplay user and can read what it can: allow them only for trusted
repositories.

Interrupts (ADR 32) are triggered over HTTP with a bearer token. Backends
get one in `DEEPSPLAY_TOKEN`; for other systems, name a secret in the
configuration:

```toml
[[config]]
name            = "lobby"
repo            = "https://github.com/example/lobby-screen.git"
ref             = "main"
interrupt_token = "lobby_trigger"   # a secret (ADR 8), e.g. DEEPSPLAY_SECRET_LOBBY_TRIGGER
```

Use a long random value (`openssl rand -base64 32`). The token travels in
plain text over plain HTTP like everything else on port 4000: keep triggers
on the internal network, or let systems from outside go through a reverse
proxy with HTTPS.

Interrupts can also be started by MQTT messages (ADR 33). This is optional:
without an `[mqtt]` section deepsplay opens no connection. With one, it
connects to the broker and subscribes to the `mqtt_topic` of each
configuration that has one:

```toml
[mqtt]
url       = "mqtts://broker.example.org:8883"  # mqtt://… (plain) only for a local broker
username  = "deepsplay"
password  = "{secret:mqtt_password}"           # only as a secret reference
# ca_file   = "/etc/deepsplay/broker-ca.pem"   # for a private CA; default: system CAs
# client_id = "deepsplay-lobby"                # default: deepsplay- and a random suffix

[[config]]
name       = "lobby"
repo       = "https://github.com/example/lobby-screen.git"
ref        = "main"
mqtt_topic = "deepcyber/lobby/interrupts/+"    # last level: the interrupt's name
```

- TLS checks the broker's certificate and host name. Mount `ca_file` into
  the container if the broker uses a private CA.
- The filter must end in `/+`; other levels may be `+`, `#` is not
  allowed. Several configurations may share a filter: a message then starts
  the interrupt in each that has it.
- Whoever may publish to a configuration's topics can put pages on its
  screens: restrict the topics in the broker's access rules. deepsplay only
  subscribes and needs no publish rights.
- deepsplay reconnects on its own (after 1 s, growing to 60 s). Messages
  published meanwhile are lost; retained messages are ignored.
- `/status` shows the connection, its last error and the subscribed
  filters; the catalog shows each interrupt's topic with a `mosquitto_pub`
  example. To test:
  `mosquitto_pub -h broker.example.org -p 8883 --capath /etc/ssl/certs -u <user> -P <password> -t deepcyber/lobby/interrupts/doorbell -m '{"who": "Ada"}'`.
- Changes to `[mqtt]` or the password secret reconnect; changed filters are
  subscribed without reconnecting.

Changes to the host configuration and the secrets file are picked up while
running, within about 5 seconds (ADR 23); `SIGHUP` (e.g. `docker kill -s HUP
deepsplay`) checks at once. An invalid change is not applied: the last good
version keeps running and `/status` shows the errors. Screens of changed
configurations reload on their own. A changed `cache_dir` or `state_dir`
needs a restart, and so do `DEEPSPLAY_*` environment variables. Mount the
directory rather than the single file if your editor or tooling replaces
files by renaming, so the container sees the new file.

## Behind a reverse proxy

deepsplay itself serves plain HTTP. For HTTPS, put a reverse proxy in front,
for example Caddy:

```caddy
display.example.org {
	reverse_proxy deepsplay-host:4000
}
```

Screens and the status page connect to deepsplay over a WebSocket, which
checks the browser's origin against the request: same scheme, host and
port. Behind the proxy, the browser uses `https://display.example.org`
while deepsplay sees `http://display.example.org:4000`, and the check fails.
Tell deepsplay the proxy's address, so it takes the scheme from the proxy's
`X-Forwarded-Proto` header (ADR 34):

```sh
DEEPSPLAY_TRUSTED_PROXIES=10.0.0.2          # or ranges: 172.16.0.0/12,fd00::/8
```

- Name the proxy, not the screens' network: every address in the list may
  set the scheme. Screens that reach port 4000 directly keep working.
- Only `X-Forwarded-Proto` is used, and the port becomes 443 (or 80). Host
  and port are never taken from headers, and the proxy must pass the
  original `Host` on, which Caddy does by default. For nginx:
  `proxy_set_header Host $host;` and
  `proxy_set_header X-Forwarded-Proto $scheme;`.
- In a container, the proxy's address is the one deepsplay sees, e.g. the
  Docker network's gateway or the proxy container's address.
- HTTPS on another port than 443: set
  `DEEPSPLAY_ORIGINS=//display.example.org` instead, which compares the host
  only.
- An invalid value stops deepsplay at start.
- The status page shows the proxy's address for screens that come through
  it.

## Docker Compose (any host, including Raspberry Pi OS)

1. Install Docker (on Raspberry Pi OS 64-bit: `curl -fsSL https://get.docker.com | sh`).
2. Copy [`deploy/compose.yaml`](../deploy/compose.yaml) and
   [`deploy/host.example.toml`](../deploy/host.example.toml) (as `host.toml`)
   to a directory, adjust `host.toml`, and create `.env` with
   `SECRET_KEY_BASE=...`.
3. `docker compose up -d`; open `http://<host>:4000/status`.

Update: `docker compose pull && docker compose up -d`. To pin a version, use
`image: ghcr.io/deepestcyber/deepsplay:0.5.0` instead of `latest`.

## NixOS

Declared in the system configuration with `virtualisation.oci-containers`:

```nix
{
  virtualisation.oci-containers = {
    backend = "docker"; # or "podman"
    containers.deepsplay = {
      image = "ghcr.io/deepestcyber/deepsplay:0.5.0";
      ports = [ "4000:4000" ];
      environmentFiles = [ "/etc/deepsplay/env" ]; # SECRET_KEY_BASE=..., mode 0600
      environment = {
        DEEPSPLAY_SECRETS = "/etc/deepsplay/secrets.toml";
      };
      volumes = [
        "/etc/deepsplay/host.toml:/etc/deepsplay/host.toml:ro"
        "/etc/deepsplay/secrets.toml:/etc/deepsplay/secrets.toml:ro"
        "deepsplay-cache:/var/lib/deepsplay"
      ];
    };
  };

  networking.firewall.allowedTCPPorts = [ 4000 ];
}
```

Keep `host.toml`, `secrets.toml` and `env` out of the Nix store (it is
world-readable); create them on the machine, e.g. with your secret management.
Update by changing the image tag and running `nixos-rebuild switch`.

## Screens (kiosk)

A screen is a browser in kiosk mode that opens `http://<server>:4000/` (default
configuration) or `/c/<name>`. Add `?screen=<label>` to name it on the status
page.

- Chromium, started by systemd or the desktop session and restarted on crash:
  `chromium --kiosk --noerrdialogs --disable-infobars
  --disable-session-crashed-bubble --autoplay-policy=no-user-gesture-required
  http://<server>:4000/?screen=lobby`
- Turn off screen blanking and power saving.
- deepsplay hides the pointer once the shell has loaded (ADR 9). To hide it
  before that as well, use `unclutter` (X11) or a kiosk compositor such as
  `cage` (Wayland).
- A screen keeps rotating with what it has when the server is unreachable, and
  reconnects by itself. After an update of deepsplay, it loads the page again
  when it reconnects, to get the new shell.
- Keep the screen's clock synchronised (NTP) and its time zone set: time
  windows use the screen's local time, to the second where a manifest asks
  for it (ADR 30).

## Releasing

1. Update `version` in `mix.exs` and the `CHANGELOG.md`.
2. Archive the page helper of the new version, so pages pinning it keep
   working after later releases (ADR 14): `mix assets.deploy`, then copy
   `priv/lib/deepsplay.js` to `priv/lib/archive/deepsplay@X.Y.Z.js` and commit
   it.
3. Tag the commit `vX.Y.Z` and push the tag.
4. The CI workflow tests, builds both architectures and publishes the image.

If the image build fails in `mix assets.setup` with `Couldn't fetch
https://github.com/tailwindlabs/tailwindcss/releases/download/...` (seen as
`504 Gateway Time-out` while GitHub's API still worked), the Dockerfile falls
back to `docker/fetch_tailwind.exs`, which downloads the same Tailwind
executable through the GitHub API. CI passes its `GITHUB_TOKEN` as the build
secret `github_token` for the API's rate limit; local builds work without it
(60 anonymous requests per hour). The fallback can be removed once the
download is reliable again.

The first published image is private by default on some accounts: make the
package public once under the repository's or organisation's package settings.
