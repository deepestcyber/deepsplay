# deepsplay

A display application by and for [Deep Cyber](https://www.deepcyber.de): kiosk
screens show HTML pages from git repositories, rotating through them, and pick
up new commits on their own.

- Content repositories hold a manifest (`screen.toml`) and the pages in
  `pages/`; screens open `/` or `/c/<name>` and rotate the pages in the browser.
- Secrets stay on the server; pages reach external APIs through a proxy.
- `/status` shows configurations, connected screens and recent errors;
  `/catalog` documents every page and lets you preview and try them.

## Documentation

- [Outline](docs/outline.md): concept and design
- [Architecture decisions](docs/adr/)
- [Deployment](docs/deployment.md): container image, Docker Compose, NixOS,
  kiosk screens
- [Development plans and progress](docs/development/)
- [Changelog](CHANGELOG.md)

## Development

Requires Elixir 1.20 and Erlang/OTP 29; the watcher tests need `inotify-tools`.

```sh
mix setup                 # dependencies and asset tools
iex -S mix phx.server     # http://localhost:4000
mix precommit             # compile, format, tests
```

Dev uses `config/deepsplay.dev.toml`, or your own gitignored
`config/deepsplay.local.toml` if it exists. A configuration with
`path = "/abs/dir"` serves a local directory live, so every save shows at once.
