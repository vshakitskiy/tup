import gleam/bytes_tree
import gleam/erlang/process
import gleam/int
import logging
import tup

pub fn main() -> Nil {
  logging.set_level(logging.Debug)
  logging.configure()

  let name = process.new_name("tup")

  echo tup.new(
      on_init: fn(_connection, selector) { #(1, selector) },
      handler: fn(connection, state, message) {
        panic
        echo message
          as { "Incomming message! (" <> int.to_string(state) <> ")" }
        let data = case message {
          tup.Incoming(data) -> bytes_tree.from_bit_array(data)
          tup.User(integer) -> bytes_tree.from_bit_array(<<integer>>)
        }
        case tup.send(connection, data) {
          Ok(Nil) -> tup.continue(state + 1)
          Error(socket) -> tup.stop_abnormal(tup.socket_error_to_string(socket))
        }
      },
      on_close: fn(state) {
        echo "Connection closed! (" <> int.to_string(state) <> ")"
        panic
        Nil
      },
    )
    |> tup.named(name)
    |> tup.listening(on: tup.Tcp(interface: "127.0.0.1", port: 3000))
    |> tup.start

  process.sleep_forever()
}
