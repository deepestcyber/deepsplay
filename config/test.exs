import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :deepsplay, DeepsplayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "E+uHNahL0IOx7Jdem5d1jvIx+aHlfWXQJgNO1Rwdjrn6qMGGiGtS/0g9gUmHJveE",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Host configuration used unless DEEPSPLAY_CONFIG is set.
config :deepsplay, :host_config_path, Path.expand("../test/support/fixtures/host.toml", __DIR__)

# Tests use local repositories (ADR 6).
config :deepsplay, :git_transports, ["https", "ssh", "file"]
config :deepsplay, :allow_local_paths, true

# Tests fetch explicitly; no pollers or cache cleanup run on their own.
config :deepsplay, :start_pollers, false

# The upstream proxy talks to Req.Test stubs instead of the network.
config :deepsplay, :proxy_req_options, plug: {Req.Test, Deepsplay.UpstreamProxy}

# The shared upstream cache stays in memory; tests of persistence start their
# own cache with a directory.
config :deepsplay, :persist_upstream_cache, false

# Name resolution for upstreams declared in manifests (ADR 19), without DNS.
config :deepsplay, :proxy_resolver, &Deepsplay.TestResolver.resolve/1

# The shared state store stays in memory; tests of persistence start their own
# store with a directory.
config :deepsplay, :persist_state, false

# Tests set the host configuration directly; tests of reloading start their
# own watcher.
config :deepsplay, :watch_host_config, false
