import gleam/erlang/process
import gleam/int
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import logging
import relay_supervisor as relay
import tup/internal/connection
import tup/internal/listener
import tup/socket

pub fn add_child(
  children: relay.Children(
    factory.Supervisor(
      connection.Argument(user_state, user_message),
      process.Subject(connection.Message(user_message)),
    ),
  ),
  listener_argument: listener.Argument,
  pool_argument: Argument(user_state, user_message),
) {
  relay.Template(start: start_relay, child_type: supervision.Supervisor)
  |> relay.child
  |> relay.providing(fn(factory) {
    #(factory, listener_argument, pool_argument)
  })
  |> relay.returning(fn(_factory, _relay) { Nil })
  |> relay.add(children, _)
}

fn start_relay(
  argument: #(
    factory.Supervisor(
      connection.Argument(user_state, user_message),
      process.Subject(connection.Message(user_message)),
    ),
    listener.Argument,
    Argument(user_state, user_message),
  ),
) -> Result(actor.Started(relay.Supervisor), actor.StartError) {
  let #(factory, listener_argument, pool_argument) = argument

  relay.new(fn(children) {
    listener.add_child(children, listener_argument)
    |> add_pool(pool_argument, factory)
  })
  |> relay.start
}

pub type Argument(user_state, user_message) {
  Argument(
    pool_size: Int,
    active_state: socket.ActiveState,
    handlers: connection.Handlers(user_state, user_message),
  )
}

fn add_pool(
  children: relay.Children(listener.Relayed),
  argument: Argument(user_state, user_message),
  factory: factory.Supervisor(
    connection.Argument(user_state, user_message),
    process.Subject(connection.Message(user_message)),
  ),
) -> relay.Children(Nil) {
  relay.Template(start: start_pool, child_type: supervision.Supervisor)
  |> relay.child
  |> relay.providing(fn(relayed) { #(relayed, argument, factory) })
  |> relay.returning(fn(_relayed, _supervisor) { Nil })
  |> relay.add(children, _)
}

fn start_pool(
  argument: #(
    listener.Relayed,
    Argument(user_state, user_message),
    factory.Supervisor(
      connection.Argument(user_state, user_message),
      process.Subject(connection.Message(user_message)),
    ),
  ),
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  let #(relayed, argument, factory) = argument

  supervisor.new(supervisor.OneForOne)
  |> int.range(
    from: 0,
    to: argument.pool_size,
    with: _,
    run: fn(supervisor, _index) {
      supervision.worker(fn() { start_acceptor(relayed, argument, factory) })
      |> supervision.restart(supervision.Transient)
      |> supervisor.add(supervisor, _)
    },
  )
  |> supervisor.start
}

type Message {
  Accept
}

type State(user_state, user_message) {
  State(
    transport: socket.Transport,
    socket: socket.ListenSocket,
    factory: factory.Supervisor(
      connection.Argument(user_state, user_message),
      process.Subject(connection.Message(user_message)),
    ),
    active_state: socket.ActiveState,
    pid: process.Pid,
    self: process.Subject(Message),
    handlers: connection.Handlers(user_state, user_message),
  )
}

fn start_acceptor(
  relayed: listener.Relayed,
  argument: Argument(user_state, user_message),
  factory: factory.Supervisor(
    connection.Argument(user_state, user_message),
    process.Subject(connection.Message(user_message)),
  ),
) {
  actor.new_with_initialiser(1000, fn(self) {
    process.send(self, Accept)

    let listener.Relayed(transport:, socket:) = relayed
    let Argument(active_state:, handlers:, ..) = argument

    State(
      transport:,
      socket:,
      factory:,
      active_state:,
      pid: process.self(),
      self:,
      handlers:,
    )
    |> actor.initialised
    |> actor.returning(Nil)
    |> Ok
  })
  |> actor.on_message(fn(state, _message) {
    let State(transport:, socket:, factory:, active_state:, pid:, handlers:, ..) =
      state

    case socket.accept(transport, socket, socket.Milliseconds(30_000)) {
      Ok(socket) -> {
        let argument =
          connection.Argument(
            transport:,
            socket:,
            acceptor: pid,
            active_state:,
            handlers:,
          )
        case factory.start_child(factory, argument) {
          Ok(actor.Started(pid:, data:)) -> {
            case socket.controlling_process(transport, socket, pid) {
              Ok(Nil) -> {
                process.send(data, connection.Ready)
                loop(state)
              }
              Error(error) -> {
                actor.stop_abnormal(
                  "Failed to transfer socket ownership: "
                  <> socket.error_to_string(error),
                )
              }
            }
          }
          Error(error) ->
            actor.stop_abnormal(
              "Failed to start a connection worker: "
              <> actor_start_error_to_string(error),
            )
        }
      }

      Error(socket.Timeout) | Error(socket.Econnaborted) -> loop(state)
      Error(socket.Closed) | Error(socket.Einval) -> actor.stop()
      Error(socket.Emfile as error) | Error(socket.Enfile as error) -> {
        { "Failed to accept the connection: " <> socket.error_to_string(error) }
        |> logging.log(logging.Error, _)

        loop_after(state, 100)
      }
      Error(error) ->
        { "Failed to accept the connection: " <> socket.error_to_string(error) }
        |> actor.stop_abnormal
    }
  })
  |> actor.start
}

fn loop(state: State(user_state, user_message)) {
  process.send(state.self, Accept)
  actor.continue(state)
}

fn loop_after(state: State(user_state, user_message), milliseconds: Int) {
  process.send_after(state.self, milliseconds, Accept)
  actor.continue(state)
}

fn actor_start_error_to_string(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "timeout"
    actor.InitFailed(reason) ->
      "initialisation process failed with reason \"" <> reason <> "\""
    actor.InitExited(process.Normal) -> "initialisation process exited normally"
    actor.InitExited(process.Killed) -> "initialisation process was killed"
    actor.InitExited(process.Abnormal(reason: _reason)) ->
      "initialisation process was killed abnormally!"
  }
}
