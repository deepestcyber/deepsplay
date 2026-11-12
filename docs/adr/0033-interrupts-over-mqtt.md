# 33. Interrupts over MQTT

Date: 2026-11-12

## Status

Accepted

Amends [5](0005-toml-for-host-config-and-screen-manifest.md),
[8](0008-secrets-only-on-host-via-upstream-proxy.md) and
[32](0032-interrupts.md).

## Context

Interrupts (ADR 32) are triggered over HTTP. Many of the systems that learn
of events, such as doorbells, sensors, Home Assistant and Node-RED, already
talk to an MQTT broker and publish there. For them, an HTTP call with a
bearer token is an extra integration; a message on a topic is not.

deepsplay runs without any broker today and must keep doing so.

## Decision

deepsplay can connect to one MQTT broker and start interrupts from messages
on topics that configurations subscribe to. MQTT is optional: without an
`[mqtt]` section in the host configuration, deepsplay opens no connection
and nothing changes.

The host configuration:

```toml
[mqtt]
url       = "mqtts://broker.example.org:8883"
username  = "deepsplay"
password  = "{secret:mqtt_password}"
# client_id = "deepsplay-lobby"
# ca_file   = "/etc/deepsplay/broker-ca.pem"

[[config]]
name       = "lobby"
repo       = "https://github.com/example/lobby-screen.git"
mqtt_topic = "deepcyber/lobby/interrupts/+"
```

The connection (`[mqtt]`):

- `url` (required): `mqtts://host[:port]` with TLS, port 8883 by default.
  `mqtt://host[:port]` (plain, port 1883) is accepted for a broker on the
  same host or for testing; user name and password then travel in plain
  text.
- TLS verifies the broker's certificate and host name against the system's
  CA certificates, or against `ca_file` for a private CA. Client
  certificates are not supported.
- `username` and `password` (both optional, but `password` needs
  `username`): the password is taken from the secrets (ADR 8) and can only
  be given as a `{secret:<name>}` reference, never as a literal value.
- `client_id` (optional): by default `deepsplay-` followed by a random
  suffix that is created at each start, so two instances never push each
  other off the broker.
- MQTT 3.1.1, clean session, subscriptions with QoS 1. Messages published
  while deepsplay is not connected are lost: interrupts stay events (ADR 32),
  and an old doorbell is not worth showing.
- deepsplay connects at start and reconnects with a growing delay (1 second
  up to 60 seconds) after the connection is lost or cannot be established.
  The rest of deepsplay does not depend on the connection.
- deepsplay only subscribes; it publishes nothing.

The topic filter (`mqtt_topic` of a `[[config]]`, optional):

- A configuration with `mqtt_topic` subscribes to it; one without it is not
  reachable over MQTT.
- The filter must end in `/+`: the last level of a topic is the name of the
  interrupt. Other levels may be `+`, `#` is not allowed.
- Several configurations may use the same or overlapping filters. A message
  then starts the interrupt in each of them that declares it.
- `mqtt_topic` without an `[mqtt]` section makes the host configuration
  unusable, as do an invalid `url`, `ca_file` or filter, and a reference to
  an undefined secret.

The payload:

- Empty: the interrupt starts without parameters.
- Otherwise a JSON object whose keys are page parameters, for example
  `{"who": "Ada", "message": "Parcel for the workshop"}`. Strings are used
  as they are; numbers and booleans are turned into their text (`5` into
  `"5"`, `true` into `"true"`); `null` counts as not given.
- The parameters are then checked like the query of an HTTP trigger (ADR
  32): only parameters the page declares, values that fit their definition,
  with precedence over the query in the manifest path.
- Rejected: invalid JSON, JSON that is not an object, nested objects or
  arrays, and payloads larger than 2 KB.
- Retained messages are ignored. The broker sends them on every subscribe,
  so they would start an interrupt again after each reconnect.

Handling:

- A message is treated like a `POST` of the interrupt: the same lookup
  (unknown or disabled interrupt, configuration without a revision), the
  same rate limit of 2 seconds per interrupt, shared with HTTP, and the same
  event to the screens.
- MQTT has no answer to the publisher. The outcome (started with the number
  of screens, or the reason it was not) is logged and kept as the last
  trigger of the interrupt, with MQTT as its source.
- Ending an interrupt early is not possible over MQTT; `DELETE` over HTTP
  and `Deepsplay.done()` stay the ways to do it.
- Who may trigger an interrupt over MQTT is decided by the broker: whoever
  may publish to a configuration's topics. No `interrupt_token` is needed or
  checked for MQTT.

Reloading (ADR 23): a changed `[mqtt]` section closes the connection and
opens a new one; changed `mqtt_topic` filters are subscribed and
unsubscribed without reconnecting. A changed password secret also
reconnects.

Visibility: the status page shows whether MQTT is configured, the broker,
the state of the connection with the last error, and the subscribed
filters. The last trigger of an interrupt shows its source (HTTP or MQTT).
The catalog shows, next to the trigger URL, the MQTT topic of each
interrupt of a configuration with `mqtt_topic`, its last level replaced by
the interrupt's name.

## Consequences

- Systems on a broker can put a page on all screens of a configuration with
  one publish, without a token or an HTTP client.
- deepsplay depends on an MQTT client library, used only when `[mqtt]` is
  configured. The library must be pure Elixir or Erlang, so the container
  build needs no native code.
- The broker becomes part of the trust boundary: its access rules decide who
  can trigger interrupts. A topic open to everyone opens the screens to
  everyone.
- Publishers learn nothing about the outcome; the status page and the log
  are the only feedback. A typo in a parameter fails silently for the
  publisher.
- Interrupts sent while deepsplay is disconnected from the broker are
  lost, like interrupts sent to a screen that is disconnected (ADR 32).
- Starting interrupts is the only thing deepsplay does with MQTT. Ending
  interrupts, publishing (for example when an interrupt ends or a page calls
  `Deepsplay.done()`), and topics for anything else would each need their
  own decision.
