import gleam/dynamic
import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import relay_supervisor as relay
import tup/internal/file
import tup/socket

pub type Argument {
  Argument(
    address: Address,
    tls: option.Option(List(socket.TlsOption)),
    buffer_size: option.Option(Int),
  )
}

pub type Relayed {
  Relayed(transport: socket.Transport, socket: socket.ListenSocket)
}

pub type Address {
  Tcp(interface: socket.Interface, port: Int)
  Unix(path: String)
}

pub fn add_child(children: relay.Children(Nil), argument: Argument) {
  relay.Template(start:, child_type: supervision.Worker(shutdown_ms: 5000))
  |> relay.child
  |> relay.providing(fn(_nil) { argument })
  |> relay.add(children, _)
}

pub opaque type Message {
  GetEndpoint(reply: process.Subject(socket.Endpoint))
}

fn control_subject(listener: process.Pid) {
  process.unsafely_create_subject(listener, dynamic.string("tup_listener"))
}

fn start(argument: Argument) {
  actor.new_with_initialiser(1000, fn(_self) {
    use <- try_unlink_stale_socket(argument.address)

    let #(port, interface) = case argument.address {
      Tcp(interface:, port:) -> #(port, interface)
      Unix(path:) -> #(0, socket.Local(path))
    }

    let tcp_options = [
      socket.BindAddress(interface),
      socket.Active(socket.Passive),
      socket.SendTimeout(socket.Milliseconds(30_000)),
      socket.ReuseAddress(True),
      socket.SendTimeoutClose(True),
      socket.Backlog(1024),
      socket.NoDelay(True),
    ]
    let tcp_options = case argument.buffer_size {
      option.Some(bytes) -> [socket.Buffer(bytes), ..tcp_options]
      option.None -> tcp_options
    }

    let listen = case argument.tls {
      option.Some(tls_options) ->
        socket.listen_tls(port, tcp_options, tls_options)
      option.None -> socket.listen(port, tcp_options)
    }

    case listen {
      Ok(#(transport, socket)) -> {
        case socket.sockname_listener(transport, socket) {
          Ok(local) -> {
            let self = control_subject(process.self())

            let selector =
              process.new_selector()
              |> process.select(for: self)

            actor.initialised(local)
            |> actor.selecting(selector)
            |> actor.returning(Relayed(transport:, socket:))
            |> Ok
          }
          Error(error) ->
            Error(
              "Could not retrieve sockname: " <> socket.error_to_string(error),
            )
        }
      }
      Error(error) ->
        Error(
          "Could not open the listen socket: " <> socket.error_to_string(error),
        )
    }
  })
  |> actor.on_message(fn(local, message) {
    let GetEndpoint(reply) = message
    process.send(reply, local)
    actor.continue(local)
  })
  |> actor.start
}

pub fn endpoint(listener: process.Pid, within: Int) {
  let monitor = process.monitor(listener)
  let subject = control_subject(listener)
  let reply = process.new_subject()
  process.send(subject, GetEndpoint(reply:))

  let endpoint =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_down) { Error(Nil) })
    |> process.select_map(for: reply, mapping: fn(reply) { Ok(reply) })
    |> process.selector_receive(within:)
    |> result.flatten

  process.demonitor_process(monitor:)

  endpoint
}

pub type SocketPathError {
  PathNotSocket(kind: PathKind)
  PathNotInspected(reason: String)
  PathNotRemoved(reason: String)
}

pub type PathKind {
  Device
  Directory
  Regular
  Symlink
  UnknownKind
}

pub fn socket_path_error_to_string(error: SocketPathError) -> String {
  case error {
    PathNotSocket(kind:) ->
      "the path holds "
      <> path_kind_to_string(kind)
      <> " rather than a socket, so it was left untouched"
    PathNotInspected(reason:) ->
      "the path could not be inspected, " <> file.reason_to_string(reason)
    PathNotRemoved(reason:) ->
      "the stale socket could not be removed, " <> file.reason_to_string(reason)
  }
}

fn path_kind_to_string(kind: PathKind) -> String {
  case kind {
    Device -> "a device"
    Directory -> "a directory"
    Regular -> "a regular file"
    Symlink -> "a symbolic link"
    UnknownKind -> "a file of a kind these bindings do not name"
  }
}

fn try_unlink_stale_socket(
  address: Address,
  callback: fn() -> Result(a, String),
) -> Result(a, String) {
  case address {
    Unix(path:) -> {
      case unlink_stale_socket(path) {
        Ok(Nil) -> callback()
        Error(error) -> {
          Error(
            "Could not make the unix socket path "
            <> path
            <> " ready to bind: "
            <> socket_path_error_to_string(error),
          )
        }
      }
    }
    Tcp(..) -> callback()
  }
}

@external(erlang, "tup_ffi", "unlink_stale_socket")
fn unlink_stale_socket(path: String) -> Result(Nil, SocketPathError)
