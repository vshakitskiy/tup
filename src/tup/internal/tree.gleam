//// Supervisor operations on a running server.

import gleam/erlang/process

// The constants describe the order the children are added inside the `tup.start` 
// relay supervisor. If we plan to update the tree, we also need to update 
// those constants as well.
//
// The current tree implies:
//
// ┆
// ┆
// └─ Root Supervisor, RestForOne outer relay_supervisor
//    ^^^^^^^^^^^^^^^ This is our relay supervisor from `tup.start`.
//    ├─ Connection Supervisor, OneForOne Transient factory_supervisor
//    │  ^^^^^^^^^^^^^^^^^^^^^ (1) First child of the root.
//    └─ Acceptor Pool, RestForOne inner relay_supervisor
//       ^^^^^^^^^^^ (2) this is our acceptor pool which we would address for the
//       │               listener child.
//       ├─ Listener, worker
//       │  ^^^^^^^^ (1) First child of the acceptor pool.
//       └─ Pool, OneForOne static_supervisor
//         ├─ ...
//         ...

/// The connection supervisor which is the first child of the root.
pub const connection_supervisor = 1

/// The inner relay holding the listener and the acceptors which is the second 
/// child of the root. Terminating it stops accepting and closes the listen socket.
pub const acceptor_pool = 2

/// The listener which is the first child of the acceptor pool.
pub const listener = 1

/// The pid of the running child with `id`. A child that was terminated or is
/// between a crash and its restart has no pid.
@external(erlang, "tup_ffi", "child_pid")
pub fn child(supervisor: process.Pid, id: Int) -> Result(process.Pid, Nil)

/// Stop the child with `id` without restarting it.
@external(erlang, "tup_ffi", "terminate_child")
pub fn terminate_child(supervisor: process.Pid, id: Int) -> Result(Nil, Nil)

/// Start a child that was terminated. A child that is already running counts
/// as restarted.
@external(erlang, "tup_ffi", "restart_child")
pub fn restart_child(supervisor: process.Pid, id: Int) -> Result(Nil, Nil)

/// How many children are alive.
@external(erlang, "tup_ffi", "active_children")
pub fn active_children(supervisor: process.Pid) -> Result(Int, Nil)
