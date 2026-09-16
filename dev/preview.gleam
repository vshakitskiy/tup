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
