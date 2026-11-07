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

Changes to the host configuration and the secrets file are picked up while
running, within about 5 seconds (ADR 23); `SIGHUP` (e.g. `docker kill -s HUP
deepsplay`) checks at once. An invalid change is not applied: the last good
version keeps running and `/status` shows the errors. Screens of changed
configurations reload on their own. A changed `cache_dir` or `state_dir`
needs a restart, and so do `DEEPSPLAY_*` environment variables. Mount the
directory rather than the single file if your editor or tooling replaces
files by renaming, so the container sees the new file.

## Docker Compose (any host, including Raspberry Pi OS)

1. Install Docker (on Raspberry Pi OS 64-bit: `curl -fsSL https://get.docker.com | sh`).
2. Copy [`deploy/compose.yaml`](../deploy/compose.yaml) and
   [`deploy/host.example.toml`](../deploy/host.example.toml) (as `host.toml`)
   to a directory, adjust `host.toml`, and create `.env` with
   `SECRET_KEY_BASE=...`.
3. `docker compose up -d`; open `http://<host>:4000/status`.

Update: `docker compose pull && docker compose up -d`. To pin a version, use
`image: ghcr.io/deepestcyber/deepsplay:0.2.0` instead of `latest`.

## NixOS

Declared in the system configuration with `virtualisation.oci-containers`:

```nix
{
  virtualisation.oci-containers = {
    backend = "docker"; # or "podman"
    containers.deepsplay = {
      image = "ghcr.io/deepestcyber/deepsplay:0.2.0";
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
  reconnects by itself.

## Releasing

1. Update `version` in `mix.exs` and the `CHANGELOG.md`.
2. Archive the page helper of the new version, so pages pinning it keep
   working after later releases (ADR 14): `mix assets.deploy`, then copy
   `priv/lib/deepsplay.js` to `priv/lib/archive/deepsplay@X.Y.Z.js` and commit
   it.
3. Tag the commit `vX.Y.Z` and push the tag.
4. The CI workflow tests, builds both architectures and publishes the image.

The first published image is private by default on some accounts: make the
package public once under the repository's or organisation's package settings.
