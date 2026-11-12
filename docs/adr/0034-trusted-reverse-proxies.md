# 34. Trusted reverse proxies

Date: 2026-11-12

## Status

Accepted

## Context

deepsplay serves plain HTTP on port 4000. For HTTPS, a reverse proxy such as
Caddy sits in front and forwards requests to deepsplay over HTTP.

The LiveView socket checks the browser's `Origin` header. By default
(`check_origin: :conn`) the origin must match the request in scheme, host
and port, so screens can reach deepsplay under any name or IP address
without configuration. Behind a proxy, the browser's origin is
`https://display.example.org` (port 443), while deepsplay sees
`http://display.example.org:4000`: the check fails and screens and the
status page cannot connect.

`DEEPSPLAY_ORIGINS="//display.example.org"` works around this by comparing
the host only, but every name has to be listed.

Proxies tell the backend the original scheme with `X-Forwarded-Proto`, some
also the port with `X-Forwarded-Port`. Caddy overwrites `X-Forwarded-Proto`
but passes a client's `X-Forwarded-Port` on unchanged. Any client can send
these headers, though, and screens on the internal network usually reach
deepsplay directly, without a proxy. Trusting the headers from everyone would let
those clients choose the scheme and port deepsplay believes in. Browsers
cannot set `X-Forwarded-*` on a WebSocket handshake and need a CORS
preflight for them on other cross-site requests, so the origin check itself
would still hold; but anything else that relies on the scheme, port or host
(absolute URLs, redirects, secure cookies, later code) would not. Taking the
host from `X-Forwarded-Host` is the most dangerous part (host header
injection), and proxies like Caddy pass the original `Host` on anyway.

`Plug.RewriteOn` trusts the headers from every client and only sets the
port to 443 if the request came in on port 80, which is not the case
behind a proxy that forwards to 4000.

## Decision

`DEEPSPLAY_TRUSTED_PROXIES` lists the reverse proxies whose headers
deepsplay trusts: IP addresses or CIDR ranges, separated by commas, IPv4 and
IPv6 (`10.0.0.2`, `172.16.0.0/12,fd00::/8`). Without it, no header is
trusted and nothing changes. An invalid entry stops deepsplay at start, so a
typo does not silently trust nobody.

For a request whose peer address is in the list:

- `X-Forwarded-Proto` (`http` or `https`) sets the scheme, and the port
  becomes the scheme's default port (443, 80);
- a missing, repeated or invalid header leaves the request unchanged;
- host and port are never taken from a header (`X-Forwarded-Host`,
  `X-Forwarded-Port`), and the client address (`X-Forwarded-For`) is not
  used either.

IPv4 peers on the dual-stack listener arrive as IPv4-mapped IPv6 addresses
and match IPv4 entries.

The rewrite runs at the start of `DeepsplayWeb.Endpoint.call/2`, not as a
plug: Phoenix dispatches sockets before the endpoint's plugs, and the origin
check needs the rewritten request.

## Consequences

- Behind a proxy that sends `X-Forwarded-Proto` (Caddy, nginx with
  `proxy_set_header X-Forwarded-Proto $scheme`, Traefik), setting the
  proxy's address is enough; `DEEPSPLAY_ORIGINS` is no longer needed.
- The proxy must overwrite `X-Forwarded-Proto` from its clients, not pass it
  on. Caddy does by default; with nginx the `proxy_set_header` line does.
- A proxy serving HTTPS on another port than 443 still fails the origin
  check; `DEEPSPLAY_ORIGINS` remains the way for that case.
- Trusting a whole network trusts every client in it. The list should name
  the proxy, not the screens' network.
- Screens behind the proxy still show the proxy's address on the status
  page, since `X-Forwarded-For` is not used.
