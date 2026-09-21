import exception
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import gleam/string
import logging
import relay_supervisor as relay
import tup/socket

pub type Relayed(user_state, user_message) {
  Relayed(
    transport: socket.Transport,
    socket: socket.ListenSocket,
    endpoint: socket.Endpoint,
  )
}

pub fn add_child(
  children: relay.Children(Nil),
  shutdown_timeout: Int,
) -> relay.Children(
  factory.Supervisor(
    Argument(user_state, user_message),
    process.Subject(Message(user_message)),
  ),
) {
  relay.Template(
    start: fn(_nil) { start(shutdown_timeout) },
    child_type: supervision.Supervisor,
  )
  |> relay.child
  |> relay.providing(fn(_relayed) { Nil })
  |> relay.returning(fn(_relayed, factory) { factory })
  |> relay.add(children, _)
}

pub type Argument(user_state, user_message) {
  Argument(
    transport: socket.Transport,
    socket: socket.Socket,
    acceptor: process.Pid,
    active_state: socket.ActiveState,
    handshake_timeout: socket.Timeout,
    handlers: Handlers(user_state, user_message),
  )
}

pub type Handlers(user_state, user_message) {
  Handlers(
    on_init: fn(Connection, process.Selector(user_message)) ->
      #(user_state, process.Selector(user_message)),
    handler: fn(Connection, user_state, HandlerMessage(user_message)) ->
      Next(user_state, user_message),
    on_close: fn(user_state) -> Nil,
    on_shutdown: fn(Connection, user_state) -> Nil,
  )
}

pub type Next(user_state, user_message) {
  Continue(
    state: user_state,
    selector: option.Option(process.Selector(user_message)),
    active_state: option.Option(socket.ActiveState),
  )
  NormalStop
  AbnormalStop(reason: String)
}

pub type Connection {
  Connection(
    transport: socket.Transport,
    socket: socket.Socket,
    local: socket.Endpoint,
    peer: socket.Endpoint,
  )
}

pub type HandlerMessage(user_message) {
  Incoming(BitArray)
  UserMessage(user_message)
}

fn start(
  shutdown_timeout: Int,
) -> Result(
  actor.Started(
    factory.Supervisor(
      Argument(user_state, user_message),
      process.Subject(Message(user_message)),
    ),
  ),
  actor.StartError,
) {
  factory.worker_child(start_worker)
  |> factory.restart_strategy(supervision.Temporary)
  |> factory.timeout(ms: shutdown_timeout)
  |> factory.start
}

pub type Message(user_message) {
  Ready
  AcceptorDown(process.Down)
  TrappedExit(process.ExitMessage)
  Received(socket.Message)
  User(user_message)
}

type State(user_state, user_message) {
  Initialised(
    transport: socket.Transport,
    socket: socket.Socket,
    parent: process.Pid,
    self: process.Subject(Message(user_message)),
    init_selector: process.Selector(Message(user_message)),
    active_state: socket.ActiveState,
    handshake_timeout: socket.Timeout,
    handlers: Handlers(user_state, user_message),
    monitor: process.Monitor,
  )
  Acknowledged(
    connection: Connection,
    parent: process.Pid,
    self: process.Subject(Message(user_message)),
    init_selector: process.Selector(Message(user_message)),
    active_state: socket.ActiveState,
    handlers: Handlers(user_state, user_message),
    user_state: user_state,
  )
}

pub fn start_worker(argument: Argument(user_state, user_message)) {
  actor.new_with_initialiser(1000, fn(self) {
    process.trap_exits(True)

    let Argument(
      transport:,
      socket:,
      acceptor:,
      active_state:,
      handshake_timeout:,
      handlers:,
    ) = argument
    let monitor = process.monitor(acceptor)

    let selector =
      socket.selector(transport)
      |> process.map_selector(Received)
      |> process.select_specific_monitor(monitor, AcceptorDown)
      |> process.select_trapped_exits(TrappedExit)
      |> process.select(self)

    Initialised(
      transport:,
      socket:,
      parent: parent(),
      active_state:,
      handshake_timeout:,
      self:,
      init_selector: selector,
      handlers:,
      monitor:,
    )
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    case state, message {
      Initialised(
        transport:,
        socket:,
        parent:,
        active_state:,
        handshake_timeout:,
        self:,
        init_selector:,
        handlers:,
        monitor:,
      ),
        Ready
      -> {
        process.demonitor_process(monitor:)

        case socket.handshake(transport, socket, handshake_timeout) {
          Ok(socket) -> {
            let local = socket.sockname(transport, socket)
            let peer = socket.peername(transport, socket)
            case local, peer {
              Ok(local), Ok(peer) -> {
                use <- refresh_flow_control(transport, socket, active_state)

                let connection = Connection(transport:, socket:, local:, peer:)
                let #(state, user_selector) =
                  handlers.on_init(connection, process.new_selector())

                let selector =
                  process.map_selector(user_selector, User)
                  |> process.merge_selector(init_selector, _)

                Acknowledged(
                  connection:,
                  parent:,
                  self:,
                  init_selector:,
                  active_state:,
                  handlers:,
                  user_state: state,
                )
                |> actor.continue
                |> actor.with_selector(selector)
              }
              _local, _peer -> stop_before_ready(transport, socket)
            }
          }
          Error(_error) -> stop_before_ready(transport, socket)
        }
      }
      Initialised(..), AcceptorDown(_down) -> actor.stop()
      // During "Initialised" state, the only message that we could have 
      // possibly receive is from the connection supervisor.
      Initialised(..), TrappedExit(process.ExitMessage(reason:, ..)) ->
        exit_reason_to_dynamic(reason)
        |> exit
      Initialised(..), _remaining -> {
        logging.log(
          logging.Warning,
          "Unexpected behaviour! Worker under \"Initialised\" received incomming data or user message.",
        )

        actor.continue(state)
      }

      Acknowledged(connection:, handlers:, user_state:, ..),
        Received(socket.Incoming(data))
      -> {
        let rescued =
          exception.rescue(fn() {
            handlers.handler(connection, user_state, Incoming(data))
          })

        case rescued {
          Ok(next) -> handle_next(state, next, consumed_packet: True)
          Error(exception) -> {
            run_on_close(handlers, user_state)

            exception_to_string(exception, in: "the handler")
            |> dynamic.string
            |> exit
          }
        }
      }
      Acknowledged(user_state: state, handlers:, ..),
        Received(socket.Disconnected)
      -> {
        run_on_close(handlers, state)
        actor.stop()
      }
      Acknowledged(user_state: state, handlers:, ..),
        Received(socket.Failed(reason:))
      -> {
        run_on_close(handlers, state)
        { "Received socket failure: " <> socket.describe_error(reason) }
        |> dynamic.string
        |> exit
      }

      Acknowledged(
        connection: Connection(transport:, socket:, ..),
        active_state:,
        ..,
      ),
        Received(socket.Exhausted)
      -> {
        use <- refresh_flow_control(transport, socket, active_state)
        actor.continue(state)
      }
      Acknowledged(connection:, handlers:, user_state:, ..), User(message) -> {
        let rescued =
          exception.rescue(fn() {
            handlers.handler(connection, user_state, UserMessage(message))
          })

        case rescued {
          Ok(next) -> handle_next(state, next, consumed_packet: False)
          Error(exception) -> {
            run_on_close(handlers, user_state)

            exception_to_string(exception, in: "the handler")
            |> dynamic.string
            |> exit
          }
        }
      }
      Acknowledged(connection:, parent:, user_state:, handlers:, ..),
        TrappedExit(process.ExitMessage(pid:, reason:))
      -> {
        let Connection(transport:, socket:, ..) = connection
        case pid == parent, reason {
          // The connection supervisor is taking this connection down.
          True, reason -> {
            run_on_shutdown(handlers, connection, user_state)

            let _closed = socket.close(transport, socket)

            run_on_close(handlers, user_state)

            exit_reason_to_dynamic(reason)
            |> exit
          }

          // A process the handler spawned finished. This message should not 
          // affect the connection worker at all.
          False, process.Normal -> actor.continue(state)

          // A process the handler spawned crashed or was killed.
          False, reason -> {
            run_on_close(handlers, user_state)

            exit_reason_to_dynamic(reason)
            |> exit
          }
        }
      }
      Acknowledged(..), _remaining -> actor.continue(state)
    }
  })
  |> actor.start
}

@external(erlang, "tup_ffi", "parent")
fn parent() -> process.Pid

// erlang:exit never returns. Soooo the return type can be anything to match the 
// caller needs.
@external(erlang, "tup_ffi", "exit_with")
fn exit(reason: dynamic.Dynamic) -> actor.Next(state, message)

fn stop_before_ready(
  transport: socket.Transport,
  socket: socket.Socket,
) -> actor.Next(state, message) {
  let _closed = socket.close(transport, socket)
  actor.stop()
}

fn exit_reason_to_dynamic(reason: process.ExitReason) -> dynamic.Dynamic {
  case reason {
    process.Normal -> atom.to_dynamic(atom.create("normal"))
    process.Killed -> atom.to_dynamic(atom.create("killed"))
    process.Abnormal(reason:) -> reason
  }
}

fn rearm_flow_control(
  transport: socket.Transport,
  socket: socket.Socket,
  active_state: option.Option(socket.ActiveState),
  callback: fn() -> actor.Next(a, b),
) -> actor.Next(a, b) {
  case active_state {
    option.Some(active_state) ->
      refresh_flow_control(transport, socket, active_state, callback)
    option.None -> callback()
  }
}

fn refresh_flow_control(
  transport: socket.Transport,
  socket: socket.Socket,
  active_state: socket.ActiveState,
  callback: fn() -> actor.Next(a, b),
) {
  let refresh =
    socket.set_options(transport, socket, [
      socket.Active(active_state),
    ])

  case refresh {
    Ok(Nil) -> callback()
    Error(error) -> {
      { "Failed to follow the flow control: " <> socket.describe_error(error) }
      |> dynamic.string
      |> exit
    }
  }
}

fn handle_next(
  state: State(user_state, user_message),
  next: Next(user_state, user_message),
  consumed_packet consumed_packet: Bool,
) {
  case state, next {
    Acknowledged(
      connection: Connection(transport:, socket:, ..),
      init_selector: selector,
      active_state: current,
      ..,
    ) as state,
      Continue(state: user_state, selector: user_selector, active_state: asked)
    -> {
      let rearm = case asked, consumed_packet, current {
        option.Some(active_state), _consumed, _current ->
          option.Some(active_state)
        option.None, True, socket.Once -> option.Some(socket.Once)
        option.None, _consumed, _current -> option.None
      }
      let state =
        Acknowledged(
          ..state,
          user_state:,
          active_state: option.unwrap(asked, current),
        )

      use <- rearm_flow_control(transport, socket, rearm)
      let next = actor.continue(state)
      case user_selector {
        option.Some(user_selector) -> {
          process.map_selector(user_selector, User)
          |> process.merge_selector(selector, _)
          |> actor.with_selector(next, _)
        }
        option.None -> next
      }
    }
    Acknowledged(user_state: state, handlers:, ..), NormalStop -> {
      run_on_close(handlers, state)
      actor.stop()
    }
    Acknowledged(user_state: state, handlers:, ..), AbnormalStop(reason:) -> {
      run_on_close(handlers, state)

      dynamic.string(reason)
      |> exit
    }
    // This function should be called after the Ready message, so we assume these
    // branches are unreachable.
    Initialised(..), Continue(..) -> actor.continue(state)
    Initialised(..), NormalStop -> actor.stop()
    Initialised(..), AbnormalStop(reason:) ->
      dynamic.string(reason)
      |> exit
  }
}

fn run_on_shutdown(
  handlers: Handlers(user_state, user_message),
  connection: Connection,
  state: user_state,
) -> Nil {
  case exception.rescue(fn() { handlers.on_shutdown(connection, state) }) {
    Ok(Nil) -> Nil
    Error(exception) ->
      logging.log(
        logging.Error,
        "The connection was shut down without sending its goodbye. "
          <> exception_to_string(exception, in: "on_shutdown"),
      )
  }
}

fn run_on_close(
  handlers: Handlers(user_state, user_message),
  state: user_state,
) -> Nil {
  case exception.rescue(fn() { handlers.on_close(state) }) {
    Ok(Nil) -> Nil
    Error(exception) ->
      logging.log(
        logging.Error,
        "The connection was closed without finishing its cleanup. "
          <> exception_to_string(exception, in: "on_close"),
      )
  }
}

/// Describe an exception raised by user code in a way the actual error reaches 
/// the log or exit reason. The runtime error Gleam raises for `panic`, `todo`, 
/// `let assert` and `assert`.
type GleamError {
  GleamError(
    kind: GleamErrorKind,
    message: String,
    module: String,
    function: String,
    file: String,
    line: Int,
    /// The value that did not match for `let assert`.
    value: option.Option(dynamic.Dynamic),
  )
}

type GleamErrorKind {
  Panic
  Todo
  LetAssert
  Assert
}

@external(erlang, "tup_ffi", "gleam_error")
fn gleam_error(error: dynamic.Dynamic) -> Result(GleamError, Nil)

/// What Erlang code raised in Erlang syntax.
@external(erlang, "tup_ffi", "erlang_term_to_string")
fn erlang_term_to_string(term: dynamic.Dynamic) -> String

fn gleam_error_to_string(error: GleamError, in location: String) -> String {
  let GleamError(kind:, message:, module:, function:, file:, line:, value:) =
    error
  let happened = case kind {
    Panic -> " panicked in "
    Todo -> " reached a todo in "
    LetAssert -> " failed a let assert in "
    Assert -> " failed an assert in "
  }
  let unmatched = case value {
    option.Some(value) -> " Unmatched value: " <> string.inspect(value)
    option.None -> ""
  }
  location
  <> happened
  <> module
  <> "."
  <> function
  <> " ("
  <> file
  <> ":"
  <> int.to_string(line)
  <> "): "
  <> message
  <> unmatched
}

fn exception_to_string(
  exception: exception.Exception,
  in location: String,
) -> String {
  case exception {
    exception.Errored(error) ->
      case gleam_error(error) {
        Ok(gleam_error) -> gleam_error_to_string(gleam_error, in: location)
        Error(Nil) ->
          "An error was raised in "
          <> location
          <> ": "
          <> erlang_term_to_string(error)
          <> ". This can be caused by calling Erlang code that fails."
      }
    exception.Thrown(value) ->
      "A value was thrown in "
      <> location
      <> ": "
      <> erlang_term_to_string(value)
      <> "."
    exception.Exited(reason) ->
      "An exit was raised in "
      <> location
      <> ": "
      <> erlang_term_to_string(reason)
      <> "."
  }
}
