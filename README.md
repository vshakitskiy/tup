# tup

A TCP and TLS acceptor pool for Gleam, built on `relay_supervisor`.

[![Package Version](https://img.shields.io/hexpm/v/tup)](https://hex.pm/packages/tup)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/tup/)

## Contents

- [Installation](#installation)
- [Usage](#usage)
  - [Getting Started](#getting-started)
  - [Custom Messages](#custom-messages)
  - [Flow Control](#flow-control)
  - [Who Is Connected](#who-is-connected)
  - [TLS](#tls)
  - [Unix Sockets](#unix-sockets)
  - [IPv6](#ipv6)
  - [Graceful Shutdown](#graceful-shutdown)
  - [Controlling a Running Server](#controlling-a-running-server)
  - [Memory and Throughput](#memory-and-throughput)
  - [Running Under Supervision](#running-under-supervision)
  - [Running as an OTP Application](#running-as-an-otp-application)
- [API Reference](#api-reference)

<h2 id="installation">Installation</h2>

```sh
gleam add tup@1 gleam_erlang gleam_otp
```

<h2 id="usage">Usage</h2>

<h3 id="getting-started">Getting Started</h3>

You describe a server with [`tup.new`](https://hexdocs.pm/tup/tup.html#new) and
run it with [`tup.start`](https://hexdocs.pm/tup/tup.html#start). `tup.new`
takes three callbacks, all of which run in the connection's own process:

- `on_init` is called once when the connection is set up and returns the state 
  the connection starts with.
- `handler` is called for every message and decides what happens next by
  returning [`tup.continue`](https://hexdocs.pm/tup/tup.html#continue),
  [`tup.stop`](https://hexdocs.pm/tup/tup.html#stop) or
  [`tup.stop_abnormal`](https://hexdocs.pm/tup/tup.html#stop_abnormal).
- `on_close` is called once the connection has ended.

Here is the example with a simple echo server.

```gleam
import gleam/bytes_tree
import gleam/erlang/process
import tup

pub fn main() {
  let assert Ok(_started) =
    tup.new(
      on_init: fn(_connection, selector) { #(Nil, selector) },
      handler: fn(connection, state, message) {
        case message {
          tup.Incoming(data) -> {
            let _sent = tup.send(connection, bytes_tree.from_bit_array(data))
            tup.continue(state)
          }
          tup.User(_message) -> tup.continue(state)
        }
      },
      on_close: fn(_state) { Nil },
    )
    |> tup.listening(on: tup.Tcp("0.0.0.0", 3000))
    |> tup.start

  process.sleep_forever()
}
```

[`tup.listening`](https://hexdocs.pm/tup/tup.html#listening) takes a
[`tup.Address`](https://hexdocs.pm/tup/tup.html#Address). Using port `0`, as in
`Tcp("0.0.0.0", 0)`, lets the system pick a free port. The default is
`Tcp("127.0.0.1", 3000)`.

[`tup.pool_size`](https://hexdocs.pm/tup/tup.html#pool_size) sets how many
acceptors wait for connections at the same time. The default is 20.

<h3 id="custom-messages">Custom Messages</h3>

`on_init` receives an empty selector, which you may use to 
[`tup.User`](https://hexdocs.pm/tup/tup.html#Message) messages to the connection.

```gleam
tup.new(
  on_init: fn(_connection, selector) {
    let client = process.new_subject()
    pubsub.subscribe(pubsub, client)

    #(client, process.select(selector, client))
  },
  handler: fn(connection, client, message) {
    case message {
      tup.User(broadcast) -> {
        let _sent = tup.send(connection, bytes_tree.from_string(broadcast))
        tup.continue(client)
      }
      tup.Incoming(_data) -> tup.continue(client)
    }
  },
  on_close: fn(client) { pubsub.unsubscribe(pubsub, client) },
)
```

To change the selector later, return the new selector with
[`tup.with_selector`](https://hexdocs.pm/tup/tup.html#with_selector):

```gleam
tup.continue(state)
|> tup.with_selector(selector)
```

<h3 id="flow-control">Flow Control</h3>

By default, a connection reads one packet at a time and only asks for the next
one once the handler has run. This way a client can never fill the connection's
mailbox faster than it is served.
[`tup.active_state`](https://hexdocs.pm/tup/tup.html#active_state) changes this
for every connection and
[`tup.with_active_state`](https://hexdocs.pm/tup/tup.html#with_active_state)
changes it for a single connection from the next message onwards.

| [`tup.ActiveState`](https://hexdocs.pm/tup/tup.html#ActiveState) | What it does |
| --- | --- |
| `Once` | One packet then the connection asks for the next. This is the default. |
| `Count(n)` | `n` packets then the connection asks for more. |
| `Active` | Every packet as soon as it arrives with no back pressure. |

```gleam
tup.continue(state)
|> tup.with_active_state(tup.Count(100))
```

<h3 id="who-is-connected">Who Is Connected</h3>

[`tup.peer`](https://hexdocs.pm/tup/tup.html#peer) and
[`tup.local`](https://hexdocs.pm/tup/tup.html#local) give you the two ends of a
connection as a [`tup.Endpoint`](https://hexdocs.pm/tup/tup.html#Endpoint). You 
can format the endpoint with
[`tup.endpoint_to_string`](https://hexdocs.pm/tup/tup.html#endpoint_to_string).

```gleam
fn describe(connection: tup.Connection) -> String {
  case tup.peer(connection) {
    tup.TcpEndpoint(ip_address:, port: _) ->
      // An IPv4 client on a dual-stack socket shows up as an IPv4-mapped IPv6
      // address so unmap it before comparing or logging it.
      tup.unmap_ipv4(ip_address)
      |> tup.ip_address_to_string
    tup.UnixEndpoint(path:) -> "unix:" <> path
  }
}
```

<h3 id="tls">TLS</h3>

[`tup.with_tls`](https://hexdocs.pm/tup/tup.html#with_tls) takes a
[`tup.Tls`](https://hexdocs.pm/tup/tup.html#Tls), which you build from a
[`tup.Certificate`](https://hexdocs.pm/tup/tup.html#Certificate). The
certificate and key are read and decoded before the server starts.

```gleam
tup.new(on_init:, handler:, on_close:)
|> tup.listening(on: tup.Tcp("0.0.0.0", 8443))
// Certificate and key files on disk.
|> tup.with_tls(tup.tls(tup.Disk("priv/localhost.crt", "priv/localhost.key")))
// Or encrypted on disk: tup.EncryptedDisk(cert, key, "password")
// Or PEM in memory:     tup.Pem(cert, key)
// Or DER in memory:     tup.Der([cert], tup.RsaPrivateKey(key))
|> tup.start
```

To request or require a client certificate, add
[`tup.verifying_clients`](https://hexdocs.pm/tup/tup.html#verifying_clients).
[`tup.with_alpn`](https://hexdocs.pm/tup/tup.html#with_alpn) offers protocols
during the handshake, and
[`tup.session_tickets`](https://hexdocs.pm/tup/tup.html#session_tickets)
controls how session resumption tickets are handled.

```gleam
tup.tls(tup.Disk("priv/localhost.crt", "priv/localhost.key"))
|> tup.verifying_clients(tup.Required(trusting: tup.TrustDisk("priv/ca.crt")))
|> tup.with_alpn(["h2", "http/1.1"])
```

<h3 id="unix-sockets">Unix Sockets</h3>

```gleam
|> tup.listening(on: tup.Unix("/tmp/app.sock"))
```

The path must not be empty, must be at most 107 bytes long and must not contain
a NUL byte. All of this is checked before the server starts.

A socket file left behind by a previous run is removed on start. If the path
holds anything else, such as a directory or a regular file, starting the server
returns an `Error` instead, and nothing is deleted.

The file stays on disk after the server stops, and connecting to it then gives
`econnrefused` until the next start clears it. Its permissions come from the
process umask, so the way to control access is through the permissions of the
directory that holds it.

[`tup.local`](https://hexdocs.pm/tup/tup.html#local) and
[`tup.listen_endpoint`](https://hexdocs.pm/tup/tup.html#listen_endpoint) return
`UnixEndpoint(path)`. `tup.peer` returns `UnixEndpoint("")`, since a client of a
unix socket has no address of its own.

<h3 id="ipv6">IPv6</h3>

An address written in IPv6 notation listens on IPv6: `"::1"` is the loopback
address and `"::"` means every interface. A `"::"` socket also accepts IPv4
clients, whose addresses arrive as IPv4-mapped IPv6 addresses that
[`tup.unmap_ipv4`](https://hexdocs.pm/tup/tup.html#unmap_ipv4) turns back into
IPv4.

`"0.0.0.0"` and `"localhost"` name IPv4 interfaces.
[`tup.force_ipv6`](https://hexdocs.pm/tup/tup.html#force_ipv6) makes them mean
every IPv6 interface and `"::1"` instead and refuses any IPv4 clients.

```gleam
|> tup.listening(on: tup.Tcp("0.0.0.0", 3000))
|> tup.force_ipv6
```

Combining it with any other IPv4 address, or with a unix socket path, makes
[`tup.start`](https://hexdocs.pm/tup/tup.html#start) return an `Error`.

<h3 id="graceful-shutdown">Graceful Shutdown</h3>

When the server shuts down, the acceptors stop and the listen socket closes
before any connection is asked to finish. Each connection then finishes the
message it is handling, runs `on_shutdown` and ends with `on_close`.

[`tup.on_shutdown`](https://hexdocs.pm/tup/tup.html#on_shutdown) is where a
protocol says goodbye, for example with a WebSocket close frame or an HTTP/2
GOAWAY.

```gleam
tup.new(on_init:, handler:, on_close:)
|> tup.on_shutdown(fn(connection, _state) {
  let _sent = tup.send(connection, bytes_tree.from_string("bye\n"))
  Nil
})
// How long a connection may take to finish. 15 seconds by default.
|> tup.shutdown_timeout(30_000)
```

A connection still running when the deadline passes is killed and neither
callback gets to finish.
[`tup.infinite_shutdown_timeout`](https://hexdocs.pm/tup/tup.html#infinite_shutdown_timeout)
waits for as long as it takes, which only makes sense when every handler is
guaranteed to return.

> [!NOTE]
> All of this happens when OTP shuts the server down, so the server has to be
> part of a supervision tree for a signal such as SIGTERM to reach it. See
> [Running as an OTP Application](#running-as-an-otp-application). If the server
> is started straight from `main`, the VM exits without any of this running.

<h3 id="controlling-a-running-server">Controlling a Running Server</h3>

Give the server a name with [`tup.named`](https://hexdocs.pm/tup/tup.html#named)
and the rest of your program can query it.

```gleam
let name = process.new_name("tup_server")

let assert Ok(_started) =
  tup.new(on_init:, handler:, on_close:)
  |> tup.named(name)
  |> tup.listening(on: tup.Tcp("0.0.0.0", 0))
  |> tup.start

// The port the system picked.
let assert Ok(endpoint) = tup.listen_endpoint(name, within: 1000)

// Stop accepting and close the listen socket, leaving open connections running.
let assert Ok(Nil) = tup.suspend(name)
let assert Ok(open) = tup.connection_count(name)

// Start accepting again.
let assert Ok(Nil) = tup.resume(name)
```

If the server was bound to port 0,
[`tup.resume`](https://hexdocs.pm/tup/tup.html#resume) binds to a new port.

<h3 id="memory-and-throughput">Memory and Throughput</h3>

Each connection costs about 27 KB of memory and a good part of it the read 
buffer which Erlang sizes at about 9 KB.
[`tup.buffer_size`](https://hexdocs.pm/tup/tup.html#buffer_size) lets you trade
memory for throughput.

```gleam
|> tup.buffer_size(131_072)
```

<h3 id="running-under-supervision">Running Under Supervision</h3>

[`tup.start`](https://hexdocs.pm/tup/tup.html#start) runs the server on its own.
To run it as part of a supervision tree alongside the rest of your program, use
[`tup.supervised`](https://hexdocs.pm/tup/tup.html#supervised) instead, which
returns a child specification.

```gleam
supervisor.new(supervisor.OneForOne)
|> supervisor.add(pubsub.worker(pubsub_name))
|> supervisor.add(
  tup.new(on_init:, handler:, on_close:)
  |> tup.listening(on: tup.Tcp("0.0.0.0", 3000))
  |> tup.supervised,
)
|> supervisor.start
```

<h3 id="running-as-an-otp-application">Running as an OTP Application</h3>

Starting the server from `main` with a `let assert` is the shortest thing that
works while you are trying tup out. A real service is better off letting the
[OTP application](https://www.erlang.org/doc/apps/kernel/application.html)
controller own the supervision tree: it brings the tree down in order on
shutdown, which is what makes [graceful shutdown](#graceful-shutdown) happen on
SIGTERM.

Point `application_start_module` in your `gleam.toml` at a module that exports
`start/2` and `stop/1`:

```toml
[erlang]
application_start_module = "my_app"
```

```gleam
import gleam/erlang/atom
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import tup

/// The Erlang/OTP application start callback. Starts the top supervisor and
/// hands its pid back to the application controller.
pub fn start(_type: a, _args: b) -> Result(process.Pid, actor.StartError) {
  case
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(
      tup.new(on_init:, handler:, on_close:)
      |> tup.listening(on: tup.Tcp("0.0.0.0", 3000))
      |> tup.supervised,
    )
    |> supervisor.start
  {
    Ok(actor.Started(pid:, ..)) -> Ok(pid)
    Error(reason) -> Error(reason)
  }
}

/// Called once every process in the tree is down.
pub fn stop(_state: a) -> atom.Atom {
  atom.create("ok")
}

/// The application is already running by the time this is called, so all that
/// is left for `main` to do is keep the node alive.
pub fn main() {
  process.sleep_forever()
}
```

<h2 id="api-reference">API Reference</h2>

For the full API documentation, see [hexdocs.pm/tup](https://hexdocs.pm/tup/tup.html).