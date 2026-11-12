# Interrupts over MQTT

Status: proposed (2026-11-12)

Interrupts can be started by messages on an MQTT broker, next to the HTTP
trigger ([ADR 33](../adr/0033-interrupts-over-mqtt.md)). MQTT is optional:
without `[mqtt]` in the host configuration nothing connects and nothing
changes.

Background: [ADR 32](../adr/0032-interrupts.md) (interrupts),
[ADR 8](../adr/0008-secrets-only-on-host-via-upstream-proxy.md) (secrets),
[ADR 23](../adr/0023-reload-host-configuration-on-change.md) (reloading),
[pages.md](../pages.md) "Interrupts", [deployment.md](../deployment.md).

Status values: `open`, `in progress`, `done`.

| # | Part | Status |
| --- | --- | --- |
| 1 | Client library | open |
| 2 | Host configuration: `[mqtt]` and `mqtt_topic` | open |
| 3 | Interrupts: start from parameters, source of a trigger | open |
| 4 | Payload and topic handling | open |
| 5 | Connection, subscriptions and reloading | open |
| 6 | Status page and catalog | open |
| 7 | Docs | open |

Decisions taken in discussion (2026-11-12), recorded in ADR 33:

- One topic filter per configuration (`mqtt_topic`), ending in `/+`; the
  last level is the interrupt's name.
- The payload is a flat JSON object of page parameters, or empty. No query
  strings.
- MQTT only starts interrupts: no ending them, no publishing.
- User name and password over TLS; the password from the secrets.

Order: 1 first, since the library decides how 5 is built. 2 and 3 do not
need the library and can go in parallel. 4 builds on 3, 5 on 1, 2 and 4.
6 and 7 last.

## 1. Client library

Status: open

Goal: pick the MQTT client and prove it does what ADR 33 needs, before
anything depends on it.

Candidates:

- `tortoise311` (~> 0.12.3, MQTT 3.1.1, pure Elixir, SmartRent fork of
  `tortoise`).
- `emqtt` (~> 1.16, MQTT 5 and 3.1.1, Erlang, EMQX). Check that it builds
  without native code (QUIC support through `quicer` must stay off).

Must have:

- TLS with `verify: :verify_peer`, the system CA certificates
  (`:public_key.cacerts_get/0`) or a `cacertfile`, and host name checks.
- User name and password; clean session; QoS 1 subscriptions.
- The **retain flag** of incoming messages. `tortoise311`'s handler gets
  topic levels and payload; check whether the flag is reachable at all. If
  not, that rules it out.
- Subscribe and unsubscribe on a live connection.
- Control over reconnecting (our own delay of 1 to 60 s, or the library's
  if it can be configured that way), and a callback or message when the
  connection goes up or down, for the status page.
- No native code; builds in the container image (`Dockerfile`).

Check with a local `mosquitto` (installed here) with a TLS listener, a
self-signed CA and a password file, in the scratchpad. Record the choice
and its reasons here; add the dependency to `mix.exs`.

## 2. Host configuration: `[mqtt]` and `mqtt_topic`

Status: open

- `Deepsplay.HostConfig`: a new optional `[mqtt]` table, parsed into a
  struct (`Deepsplay.HostConfig.Mqtt`: `host`, `port`, `tls`, `username`,
  `password` (the template), `client_id`, `ca_file`). `nil` when absent.
- `url`: scheme `mqtts` (TLS, default port 8883) or `mqtt` (plain, 1883);
  a host, an optional port; no path, query or user info. Anything else is
  an error.
- `password`: only a template that is exactly one `{secret:<name>}`
  (`Deepsplay.Secrets.references/1`); a literal value is an error, so is an
  undefined secret. `password` without `username` is an error.
- `ca_file`: must exist and be readable when the configuration is loaded.
- `client_id`: optional string, 1 to 23 characters of `[0-9A-Za-z_-]` (the
  safe set of MQTT 3.1.1). Without it, the connection makes one at start
  (part 5); the host configuration stays free of random values, so
  reloading does not see a change.
- `Config`: new field `mqtt_topic` (string or `nil`). Valid: non-empty
  levels or `+`, last level `+`, no `#`, no leading `$`, at most 256
  characters. `mqtt_topic` without `[mqtt]` is an error.
- Unknown keys in `[mqtt]` are errors, as elsewhere.
- Tests in `host_config_test.exs` for each rule; `host.example.toml` gets a
  commented `[mqtt]` example and `mqtt_topic`.

## 3. Interrupts: start from parameters, source of a trigger

Status: open

- `DeepsplayWeb.Interrupts.start/3` takes the raw query string today.
  Split it: `start(config, name, params, source)` with `params` a map of
  strings (as `parse_query/1` returns it) and `source` `:http` or `:mqtt`;
  the controller parses the query (2 KB limit stays there) and calls it.
- `record/4` keeps the source in the last-trigger entry; `describe/1`
  prints it ("MQTT 2026-11-12 10:00:00 UTC, started on 2 screens" next to
  "POST …, 202 to 2 screens"). For MQTT, the outcome is worded instead of
  an HTTP status: started, unknown interrupt, invalid parameters (with the
  reasons), too soon.
- The rate limit stays per configuration and interrupt, shared by both
  sources.
- Tests: existing controller tests unchanged; new unit tests for `start/4`
  with `:mqtt` and the recorded source.

## 4. Payload and topic handling

Status: open

A pure module (`DeepsplayWeb.InterruptMessage` or similar), no connection
involved, so all of it is unit tested:

- `match(filter, topic)`: whether a topic matches a filter with `+`
  levels; returns the interrupt name (the last level) or `:nomatch`.
- `params(payload)`: `""` gives `%{}`; otherwise `Jason.decode/1`, must be
  a map; values: string as is, integer and float as text (`5`, `2.5`),
  `true`/`false` as `"true"`/`"false"`, `nil` dropped; lists and maps are
  errors. Payloads over 2 KB are errors before decoding.
- `dispatch(topic, payload, retain?)`: retained messages are dropped; for
  each configuration whose `mqtt_topic` matches, `Interrupts.start/4` with
  `:mqtt`, and a log line with the outcome. A payload error is logged and,
  for each matching configuration that declares the interrupt, recorded as
  its last trigger, so the status page shows it.
- Names that are not valid interrupt names (ADR 32) are logged and
  dropped.

## 5. Connection, subscriptions and reloading

Status: open

- A process under the application supervisor (`DeepsplayWeb.Mqtt`), always
  started; idle when the host configuration has no `[mqtt]`.
- On start and on `{:host_config_changed}` (`HostConfig.Watcher.topic/0`):
  compare the wanted state (`[mqtt]` with the resolved password, the set of
  `mqtt_topic` filters) with the current one:
  - `[mqtt]` added: connect; removed: disconnect; changed (including the
    password value): reconnect;
  - only filters changed: subscribe the new, unsubscribe the gone, on the
    live connection.
- The generated `client_id` (`deepsplay-` + 8 random characters) is made
  once per process start and kept across reconnects.
- Reconnect after loss or failure with a delay of 1, 2, 4 … up to 60 s,
  reset after a successful connect.
- Messages go to part 4's `dispatch/3`, in the connection process or a
  task; a crash while handling one message must not drop the connection.
- State for the status page: configured or not, broker (`host:port`, TLS
  or plain), connected / connecting / waiting since, last error, the
  subscribed filters.
- Tests: the reconcile logic as a pure function (old state, new
  configuration, list of actions). An integration test against a local
  `mosquitto`, tagged and excluded by default (`@tag :mqtt`), started with
  a generated configuration in a temporary directory: connect with TLS and
  password, publish, a screen gets the interrupt; retained message ignored;
  filter change without reconnect.

## 6. Status page and catalog

Status: open

- Status page: an MQTT section when `[mqtt]` is configured: broker, state
  with time, last error, subscribed filters. The last trigger of each
  interrupt shows its source (part 3).
- Catalog of a configuration with `mqtt_topic`: per interrupt the topic
  (filter with the last `+` replaced by the name, other `+` left as they
  are) next to the trigger URL, and a `mosquitto_pub` example with a JSON
  payload from the page's variants or parameters.
- LiveView tests for both, as in dev-0007 part 6.

## 7. Docs

Status: open

- `pages.md` "Interrupts": triggering over MQTT, the payload rules, that
  retained messages are ignored and the publisher gets no answer.
- `deployment.md`: `[mqtt]`, the secret, `ca_file`, `mqtt_topic`; that the
  broker's access rules decide who can trigger; a test with
  `mosquitto_pub`.
- `deploy/host.example.toml` (from part 2), CHANGELOG.
- This file: status `done`, renamed to `-completed`.

## Open questions

- Whether a configuration may want more than one filter
  (`mqtt_topic = [...]`). Not now; a string can become a list later
  without breaking.
- Whether the status page should show messages that matched no interrupt
  (wrong name), beyond the log.
