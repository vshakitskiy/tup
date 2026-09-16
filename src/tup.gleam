//// A TCP and TLS server. Describe it with `new` and the builder functions,
//// then run it with `start` or hand it to a supervisor with `supervised`.
////
//// <script>
//// const docs = [
////   {
////     header: "Builder",
////     functions: [
////       "new",
////       "listening",
////       "pool_size",
////       "active_state",
////       "buffer_size",
////       "shutdown_timeout",
////       "infinite_shutdown_timeout",
////       "on_shutdown",
////       "force_ipv6",
////       "with_tls",
////       "named"
////     ]
////   },
////  {
////     header: "TLS",
////     functions: [
////       "tls",
////       "verifying_clients",
////       "with_alpn",
////       "session_tickets"
////     ]
////   },
////   {
////     header: "Server",
////     functions: [
////       "start",
////       "supervised"
////     ]
////   },
////   {
////     header: "Running Server",
////     functions: [
////       "listen_endpoint",
////       "suspend",
////       "resume",
////       "connection_count"
////     ]
////   },
////   {
////     header: "Next",
////     functions: [
////       "continue",
////       "with_selector",
////       "with_active_state",
////       "stop",
////       "stop_abnormal"
////     ]
////   },
////   {
////     header: "Connection",
////     functions: [
////       "send",
////       "peer",
////       "local",
////       "socket"
////     ]
////   },
////   {
////     header: "Addresses",
////     functions: [
////       "ip_address_to_string",
////       "unmap_ipv4",
////       "endpoint_to_string"
////     ]
////   },
////   {
////     header: "Errors",
////     functions: [
////       "describe_socket_error"
////     ]
////   }
//// ]
//// const callback = () => {
////   const list = document.querySelector(".sidebar > ul:last-of-type")
////   const sortedLists = document.createDocumentFragment()
////   const sortedMembers = document.createDocumentFragment()
////
////   for (const section of docs) {
////     sortedLists.append((() => {
////       const node = document.createElement("h3")
////       node.append(section.header)
////       return node
////     })())
////     sortedMembers.append((() => {
////       const node = document.createElement("h2")
////       node.append(section.header)
////       return node
////     })())
////
////     const sortedList = document.createElement("ul")
////     sortedLists.append(sortedList)
////
////     const sortedFunctions = [...section.functions].sort()
////
////     for (const funcName of sortedFunctions) {
////       const href = `#${funcName}`
////       const member = document.querySelector(
////         `.member:has(h2 > a[href="${href}"])`
////       )
////       const sidebar = list.querySelector(`li:has(a[href="${href}"])`)
////       if (sidebar) sortedList.append(sidebar)
////       if (member) sortedMembers.append(member)
////     }
////   }
////
////   document.querySelector(".sidebar").insertBefore(sortedLists, list)
////   document
////     .querySelector(".module-members:has(#module-values)")
////     .insertBefore(
////       sortedMembers,
////       document.querySelector("#module-values").nextSibling
////     )
//// }
////
//// document.readyState !== "loading"
////   ? callback()
////   : document.addEventListener(
////     "DOMContentLoaded",
////     callback,
////     { once: true }
////   )
//// </script>

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import logging
import relay_supervisor as relay
import tup/internal/connection
import tup/internal/file
import tup/internal/listener
import tup/internal/pool
import tup/internal/tree
import tup/socket

/// An IPv4 or IPv6 address.
pub type IpAddress {
  /// Four octets.
  Ipv4(Int, Int, Int, Int)
  /// Eight 16 bit groups.
  Ipv6(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// Formats an address as text.
///
/// ```gleam
/// tup.ip_address_to_string(Ipv4(127, 0, 0, 1))
/// // -> "127.0.0.1"
/// ```
pub fn ip_address_to_string(address: IpAddress) {
  to_socket_ip_address(address)
  |> socket.ip_address_to_string
}

/// Extracts the IPv4 address inside an IPv4 mapped IPv6 address.
/// 
/// ```gleam
/// tup.unmap_ipv4(Ipv6(0, 0, 0, 0, 0, 0xffff, 0x7f00, 0x0001))
/// // -> Ipv4(127, 0, 0, 1)
/// ```
pub fn unmap_ipv4(address: IpAddress) -> IpAddress {
  case address {
    Ipv6(0, 0, 0, 0, 0, 0xffff, high, low) ->
      Ipv4(
        int.bitwise_shift_right(high, 8),
        int.bitwise_and(high, 0xff),
        int.bitwise_shift_right(low, 8),
        int.bitwise_and(low, 0xff),
      )
    Ipv4(..) | Ipv6(..) -> address
  }
}

/// Converts a `socket.IpAddress` into an `IpAddress`.
fn from_socket_ip_address(address: socket.IpAddress) {
  case address {
    socket.Ipv4(a, b, c, d) -> Ipv4(a, b, c, d)
    socket.Ipv6(a, b, c, d, e, f, g, h) -> Ipv6(a, b, c, d, e, f, g, h)
  }
}

/// Converts an `IpAddress` into a `socket.IpAddress`.
fn to_socket_ip_address(address: IpAddress) {
  case address {
    Ipv4(a, b, c, d) -> socket.Ipv4(a, b, c, d)
    Ipv6(a, b, c, d, e, f, g, h) -> socket.Ipv6(a, b, c, d, e, f, g, h)
  }
}

/// An accepted client connection handed to every callback. Write to it with
/// `send` and look up either end of it with `peer` and `local`.
pub opaque type Connection {
  Connection(
    transport: socket.Transport,
    socket: socket.Socket,
    local: Endpoint,
    peer: Endpoint,
  )
}

/// Converts an internal connection into a `Connection`.
fn from_internal_connection(connection: connection.Connection) -> Connection {
  case connection {
    connection.Connection(transport:, socket:, local:, peer:) ->
      Connection(
        transport:,
        socket:,
        local: from_socket_endpoint(local),
        peer: from_socket_endpoint(peer),
      )
  }
}

/// The transport and the socket behind a connection.
///
/// ```gleam
/// let #(transport, socket) = tup.socket(connection)
/// socket.send(transport, socket, data)
/// ```
pub fn socket(connection: Connection) {
  #(connection.transport, connection.socket)
}

/// One end of a connection.
pub type Endpoint {
  /// An address and a port on a TCP socket.
  TcpEndpoint(ip_address: IpAddress, port: Int)
  /// The path of a Unix domain socket.
  UnixEndpoint(path: String)
}

/// Formats an endpoint as text: the address and port of a TCP endpoint or
/// the path of a Unix one.
///
/// ```gleam
/// tup.endpoint_to_string(TcpEndpoint(Ipv4(127, 0, 0, 1), 3000))
/// // -> "127.0.0.1:3000"
/// ```
pub fn endpoint_to_string(endpoint: Endpoint) {
  to_socket_endpoint(endpoint)
  |> socket.endpoint_to_string
}

/// Converts a `socket.Endpoint` into an `Endpoint`.
fn from_socket_endpoint(endpoint: socket.Endpoint) -> Endpoint {
  case endpoint {
    socket.TcpEndpoint(ip_address:, port:) ->
      TcpEndpoint(ip_address: from_socket_ip_address(ip_address), port:)
    socket.UnixEndpoint(path:) -> UnixEndpoint(path:)
  }
}

/// Converts an `Endpoint` into a `socket.Endpoint`.
fn to_socket_endpoint(endpoint: Endpoint) -> socket.Endpoint {
  case endpoint {
    TcpEndpoint(ip_address:, port:) ->
      socket.TcpEndpoint(ip_address: to_socket_ip_address(ip_address), port:)
    UnixEndpoint(path:) -> socket.UnixEndpoint(path:)
  }
}

/// The client's end of a connection.
///
/// ```gleam
/// tup.peer(connection)
/// // -> TcpEndpoint(Ipv4(192, 168, 1, 20), 51234)
/// ```
pub fn peer(connection: Connection) {
  connection.peer
}

/// The server's end of a connection.
///
/// ```gleam
/// tup.local(connection)
/// // -> TcpEndpoint(Ipv4(127, 0, 0, 1), 3000)
/// ```
pub fn local(connection: Connection) {
  connection.local
}

/// Sends data to the client. Returns the socket error when the write fails.
///
/// ```gleam
/// tup.send(connection, bytes_tree.from_string("hello\n"))
/// // -> Ok(Nil)
/// ```
pub fn send(connection: Connection, data: bytes_tree.BytesTree) {
  socket.send(connection.transport, connection.socket, data)
}

/// Describes a socket error as text.
///
/// ```gleam
/// case tup.send(connection, data) {
///   Ok(Nil) -> Nil
///   Error(error) -> io.println(describe_socket_error(error))
/// }
/// ```
pub fn describe_socket_error(error: socket.SocketError) {
  socket.describe_error(error)
}

/// What a connection does once the handler has run. Build one with
/// `continue`, `stop` or `stop_abnormal`.
pub opaque type Next(user_state, user_message) {
  /// Keep the connection open with `state`, optionally with a new selector
  /// or active state.
  Continue(
    state: user_state,
    selector: option.Option(process.Selector(user_message)),
    active_state: option.Option(socket.ActiveState),
  )
  /// Close the connection.
  NormalStop
  /// Close the connection and exit abnormally with `reason`.
  AbnormalStop(reason: String)
}

/// Keeps the connection open and carries `state` into the next message.
///
/// ```gleam
/// fn handler(_connection, count, message) {
///   case message {
///     Incoming(_data) -> tup.continue(count + 1)
///     User(_message) -> tup.continue(count)
///   }
/// }
/// ```
pub fn continue(state: user_state) {
  Continue(state:, selector: option.None, active_state: option.None)
}

/// Sets the selector the connection receives user messages on from now on. Has 
/// no effect on a stop.
///
/// ```gleam
/// let selector =
///   process.new_selector()
///   |> process.select(subject)
///
/// tup.continue(state)
/// |> tup.with_selector(selector)
/// ```
pub fn with_selector(
  next: Next(user_state, user_message),
  selector: process.Selector(user_message),
) {
  case next {
    Continue(..) as next -> Continue(..next, selector: option.Some(selector))
    remaining -> remaining
  }
}

/// Sets the socket's active state from now on. Has no effect on a stop.
///
/// ```gleam
/// tup.continue(state)
/// |> tup.with_active_state(Count(10))
/// ```
pub fn with_active_state(
  next: Next(user_state, user_message),
  active_state: ActiveState,
) {
  case next {
    Continue(..) as next ->
      Continue(
        ..next,
        active_state: option.Some(to_socket_active_state(active_state)),
      )
    remaining -> remaining
  }
}

/// Closes the connection.
///
/// ```gleam
/// case message {
///   Incoming(<<"quit\n">>) -> tup.stop()
///   _message -> tup.continue(state)
/// }
/// ```
pub fn stop() {
  NormalStop
}

/// Closes the connection and exits abnormally with `reason`.
///
/// ```gleam
/// tup.stop_abnormal("client sent an invalid frame")
/// ```
pub fn stop_abnormal(reason: String) {
  AbnormalStop(reason:)
}

/// Converts a `Next` into the internal representation.
fn to_internal_next(
  next: Next(user_state, user_message),
) -> connection.Next(user_state, user_message) {
  case next {
    Continue(state:, selector:, active_state:) ->
      connection.Continue(state:, selector:, active_state:)
    NormalStop -> connection.NormalStop
    AbnormalStop(reason:) -> connection.AbnormalStop(reason:)
  }
}

/// A message delivered to the handler.
pub type Message(user_message) {
  /// Bytes read from the socket.
  Incoming(BitArray)
  /// A message picked up by the connection's selector.
  User(user_message)
}

/// Converts an internal handler message into a `Message`.
fn from_internal_message(
  message: connection.HandlerMessage(user_message),
) -> Message(user_message) {
  case message {
    connection.Incoming(data) -> Incoming(data)
    connection.UserMessage(message) -> User(message)
  }
}

/// The type a server's `process.Name` is tagged with.
pub type Server

/// How long connections get to finish their work once the server starts
/// shutting down.
type ShutdownTimeout {
  /// Kill whatever is still running after this many milliseconds.
  ShutdownAfter(milliseconds: Int)
  /// Wait for every connection, however long it takes.
  ShutdownNever
}

/// A server being described. Start from `new`, adjust it with the builder
/// functions and hand it to `start` or `supervised`.
pub opaque type Builder(user_state, user_message) {
  Builder(
    address: Address,
    tls: option.Option(Tls),
    active_state: socket.ActiveState,
    pool_size: Int,
    shutdown_timeout: ShutdownTimeout,
    buffer_size: option.Option(Int),
    ipv6: Bool,
    handlers: connection.Handlers(user_state, user_message),
    name: option.Option(process.Name(Server)),
  )
}

/// Creates a builder from the callbacks every connection runs.
///
/// `on_init` runs once the connection is accepted. It receives the connection
/// and a selector and returns the initial state together with the selector
/// user messages are received on. 
/// 
/// `handler` runs for every `Message` and returns what the connection does next. 
/// 
/// `on_close` runs once the connection has ended.
///
/// By default the server listens on 127.0.0.1 port 3000 over plain TCP, starts 
/// every connection in the `Once` active state, runs 20 acceptors and gives
/// connections 15 seconds to finish on shutdown. Each of these can be changed 
/// with the builder function.
///
/// ```gleam
/// tup.new(
///   on_init: fn(_connection, selector) { #(0, selector) },
///   handler: fn(connection, count, message) {
///     case message {
///       Incoming(data) -> {
///         let _ = tup.send(connection, bytes_tree.from_bit_array(data))
///         tup.continue(count + 1)
///       }
///       User(_message) -> tup.continue(count)
///     }
///   },
///   on_close: fn(_count) { Nil },
/// )
/// ```
pub fn new(
  on_init on_init: fn(Connection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  handler handler: fn(Connection, user_state, Message(user_message)) ->
    Next(user_state, user_message),
  on_close on_close: fn(user_state) -> Nil,
) -> Builder(user_state, user_message) {
  Builder(
    address: Tcp(interface: "127.0.0.1", port: 3000),
    tls: option.None,
    active_state: socket.Once,
    pool_size: 20,
    shutdown_timeout: ShutdownAfter(15_000),
    buffer_size: option.None,
    ipv6: False,
    handlers: connection.Handlers(
      on_init: fn(connection, selector) {
        let connection = from_internal_connection(connection)
        on_init(connection, selector)
      },
      handler: fn(connection, state, message) {
        let connection = from_internal_connection(connection)
        let message = from_internal_message(message)
        handler(connection, state, message)
        |> to_internal_next
      },
      on_close:,
      on_shutdown: fn(_connection, _state) { Nil },
    ),
    name: option.None,
  )
}

/// How many acceptors wait for connections at once. Defaults to 20. Must be
/// greater than zero.
///
/// ```gleam
/// builder
/// |> tup.pool_size(100)
/// ```
pub fn pool_size(builder: Builder(user_state, user_message), pool_size: Int) {
  Builder(..builder, pool_size:)
}

/// How long each connection gets to finish when the server shuts down before
/// it is killed. A connection still running at the deadline is killed without
/// `on_shutdown` or `on_close` completing. Defaults to 15 seconds. Must not be
/// negative.
///
/// ```gleam
/// builder
/// |> tup.shutdown_timeout(5000)
/// ```
pub fn shutdown_timeout(
  builder: Builder(user_state, user_message),
  milliseconds: Int,
) {
  Builder(..builder, shutdown_timeout: ShutdownAfter(milliseconds))
}

/// Wait for every connection to finish when the server shuts down, however
/// long that takes. A connection that never finishes keeps the shutdown from
/// ever completing, so only use this when every handler is sure to return.
///
/// ```gleam
/// builder
/// |> tup.infinite_shutdown_timeout
/// ```
pub fn infinite_shutdown_timeout(builder: Builder(user_state, user_message)) {
  Builder(..builder, shutdown_timeout: ShutdownNever)
}

/// The most bytes one read hands to your handler. Erlang's default is about 
/// 9 KB.
///
/// A larger buffer means fewer and bigger `Incoming` messages which pays off 
/// when clients send a lot of data. It costs the memory on every connection
/// so provide careful values.
///
/// ```gleam
/// builder
/// |> tup.buffer_size(65_536)
/// ```
pub fn buffer_size(builder: Builder(user_state, user_message), bytes: Int) {
  Builder(..builder, buffer_size: option.Some(bytes))
}

/// Listen only on IPv6. IPv4 clients are refused.
///
/// Starting fails when the address is an IPv4 or a unix socket path.
pub fn force_ipv6(builder: Builder(user_state, user_message)) {
  Builder(..builder, ipv6: True)
}

/// Sets a callback that runs in every open connection when the server shuts
/// down, ahead of `on_close` and within the shutdown timeout. Nothing runs by
/// default.
///
/// ```gleam
/// builder
/// |> tup.on_shutdown(fn(connection, _state) {
///   let _ = tup.send(connection, bytes_tree.from_string("bye\n"))
///   Nil
/// })
/// ```
pub fn on_shutdown(
  builder: Builder(user_state, user_message),
  on_shutdown: fn(Connection, user_state) -> Nil,
) {
  let on_shutdown = fn(connection, state) {
    let connection = from_internal_connection(connection)
    on_shutdown(connection, state)
  }

  Builder(
    ..builder,
    handlers: connection.Handlers(..builder.handlers, on_shutdown:),
  )
}

/// Where the server listens.
pub type Address {
  /// A TCP socket bound to `interface`; an IPv4 or IPv6 address or
  /// `"localhost"`. With port 0 the system picks a free port.
  Tcp(interface: String, port: Int)
  /// A Unix domain socket at `path`. The path must be 1 to 107 bytes long
  /// with no NUL in it.
  Unix(path: String)
}

/// Sets where the server listens. Defaults to TCP on 127.0.0.1 port 3000.
///
/// ```gleam
/// builder
/// |> tup.listening(on: Tcp(interface: "0.0.0.0", port: 8080))
/// ```
pub fn listening(
  builder: Builder(user_state, user_message),
  on address: Address,
) {
  Builder(..builder, address:)
}

/// How the socket feeds packets to the handler. Each mode is the matching
/// `active` socket option in Erlang.
pub type ActiveState {
  /// One packet at a time. The connection arms the socket again after each
  /// handler run.
  Once
  /// `n` packets at a time. The connection arms the socket again after the
  /// batch.
  Count(n: Int)
  /// Every packet as soon as it arrives with no pause.
  Active
}

/// Converts an `ActiveState` into a `socket.ActiveState`.
fn to_socket_active_state(active_state: ActiveState) -> socket.ActiveState {
  case active_state {
    Once -> socket.Once
    Count(n:) -> socket.Packets(count: n)
    Active -> socket.Always
  }
}

/// Sets the active state every connection starts in. Defaults to `Once`.
///
/// ```gleam
/// builder
/// |> tup.active_state(Count(10))
/// ```
pub fn active_state(
  builder: Builder(user_state, user_message),
  active_state: ActiveState,
) {
  Builder(..builder, active_state: to_socket_active_state(active_state))
}

/// TLS settings for the server. Create them with `tls` and refine them with
/// `verifying_clients`, `with_alpn` and `session_tickets`.
pub opaque type Tls {
  Tls(
    certificate: Certificate,
    client_certificates: option.Option(ClientCertificates),
    alpn: List(String),
    session_tickets: TicketMode,
  )
}

/// Where the server's certificate chain and private key come from. Every
/// source must hold at least one certificate.
pub type Certificate {
  /// PEM files on disk.
  Disk(cert: String, key: String)
  /// PEM files on disk, the key encrypted with `password`.
  EncryptedDisk(cert: String, key: String, password: String)
  /// PEM encoded bytes.
  Pem(cert: BitArray, key: BitArray)
  /// PEM encoded bytes, the key encrypted with `password`.
  EncryptedPem(cert: BitArray, key: BitArray, password: String)
  /// A DER encoded chain with the server's own certificate first, and its key.
  Der(chain: List(BitArray), key: TlsPrivateKey)
}

/// A DER encoded private key tagged with its format.
pub type TlsPrivateKey {
  /// A PKCS #1 `RSAPrivateKey`.
  RsaPrivateKey(BitArray)
  /// A `DSAPrivateKey`.
  DsaPrivateKey(BitArray)
  /// A SEC 1 `ECPrivateKey`.
  EcPrivateKey(BitArray)
  /// A PKCS #8 `PrivateKeyInfo`.
  PrivateKeyInfo(BitArray)
}

/// Converts a `TlsPrivateKey` into a `socket.PrivateKey`.
fn to_internal_key(key: TlsPrivateKey) -> socket.PrivateKey {
  case key {
    RsaPrivateKey(key) -> socket.RsaPrivateKey(key)
    DsaPrivateKey(key) -> socket.DsaPrivateKey(key)
    EcPrivateKey(key) -> socket.EcPrivateKey(key)
    PrivateKeyInfo(key) -> socket.PrivateKeyInfo(key)
  }
}

/// Creates TLS settings around `certificate`. By default the clients are not 
/// asked for a certificate, no ALPN protocols are offered and session tickets 
/// are stateless. Every TLS server speaks TLS 1.2 and 1.3, applies its own 
/// cipher order and refuses client renegotiation.
///
/// ```gleam
/// tup.tls(tup.Disk(cert: "priv/cert.pem", key: "priv/key.pem"))
/// ```
pub fn tls(certificate: Certificate) {
  Tls(
    certificate:,
    client_certificates: option.None,
    alpn: [],
    session_tickets: Stateless,
  )
}

/// Whether clients are asked for a certificate and what happens to a client
/// that sends none.
pub type ClientCertificates {
  /// Ask for a certificate and check it against `trusting` when one comes. A 
  /// client that sends none is let through.
  Requested(trusting: TrustStore)
  /// Ask for a certificate and refuse the handshake when none comes or it fails 
  /// the check against `trusting`.
  Required(trusting: TrustStore)
}

/// The authorities client certificates are checked against. Must hold at least 
/// one certificate.
pub type TrustStore {
  /// The authorities installed on the operating system.
  SystemTrustStore
  /// A PEM file on disk.
  TrustDisk(path: String)
  /// PEM encoded bytes.
  TrustPem(bytes: BitArray)
  /// DER encoded certificates.
  TrustDer(certificates: List(BitArray))
}

/// Asks clients for a certificate and verifies it against a trust store.
///
/// ```gleam
/// tup.tls(tup.Disk(cert: "priv/cert.pem", key: "priv/key.pem"))
/// |> tup.verifying_clients(on: tup.Required(trusting: tup.TrustDisk("priv/ca.pem")))
/// ```
pub fn verifying_clients(tls: Tls, on: ClientCertificates) {
  Tls(..tls, client_certificates: option.Some(on))
}

/// Sets the ALPN protocols the server offers, most preferred first. Each must
/// be 1 to 255 bytes long. Duplicates are dropped.
///
/// ```gleam
/// tls(certificate)
/// |> with_alpn(["h2", "http/1.1"])
/// ```
pub fn with_alpn(tls: Tls, protocols: List(String)) {
  Tls(..tls, alpn: protocols)
}

/// How session tickets are issued for TLS session resumption.
pub type TicketMode {
  /// No tickets are issued.
  NoTickets
  /// Tickets point at session state kept on the server.
  Stateful
  /// Tickets carry the session state themselves, encrypted.
  Stateless
}

/// Converts a `TicketMode` into a `socket.TicketMode`.
fn to_internal_ticket_mode(mode: TicketMode) -> socket.TicketMode {
  case mode {
    NoTickets -> socket.TicketsDisabled
    Stateful -> socket.Stateful
    Stateless -> socket.Stateless
  }
}

/// Sets how session tickets are issued. Defaults to `Stateless`.
///
/// ```gleam
/// tls(certificate)
/// |> tup.session_tickets(NoTickets)
/// ```
pub fn session_tickets(tls: Tls, mode: TicketMode) {
  Tls(..tls, session_tickets: mode)
}

/// Wraps every connection in TLS with the given settings.
///
/// ```gleam
/// builder
/// |> tup.with_tls(tup.tls(tup.Disk(cert: "priv/cert.pem", key: "priv/key.pem")))
/// ```
pub fn with_tls(builder: Builder(user_state, user_message), tls: Tls) {
  Builder(..builder, tls: option.Some(tls))
}

/// Registers the started server under `name`. `listen_endpoint`, `suspend`,
/// `resume` and `connection_count` look the server up by it.
///
/// ```gleam
/// let name = process.new_name("tup")
///
/// builder
/// |> tup.named(name)
/// ```
pub fn named(
  builder: Builder(user_state, user_message),
  name: process.Name(Server),
) {
  Builder(..builder, name: option.Some(name))
}

/// The endpoint the named server listens on, with the port the system picked
/// when the server was started on port 0. Waits up to `timeout` milliseconds
/// for the listener to answer.
///
/// Returns `Error(Nil)` when no server runs under `name`, when it is suspended 
/// or when the listener does not answer in time.
///
/// ```gleam
/// let name = process.new_name("tup")
/// let assert Ok(_started) =
///   builder
///   |> tup.listening(on: Tcp(interface: "127.0.0.1", port: 0))
///   |> tup.named(name)
///   |> tup.start
///
/// tup.listen_endpoint(name, within: 1000)
/// // -> Ok(TcpEndpoint(Ipv4(127, 0, 0, 1), 54321))
/// ```
pub fn listen_endpoint(
  name: process.Name(Server),
  within timeout: Int,
) -> Result(Endpoint, Nil) {
  use root <- result.try(process.named(name))
  use pool <- result.try(tree.child(root, tree.acceptor_pool))
  use listener <- result.try(tree.child(pool, tree.listener))
  listener.endpoint(listener, timeout)
  |> result.map(with: from_socket_endpoint)
}

/// Stop accepting connections and close the listen socket. Connections that
/// are already open keep running.
/// 
/// While suspended the new clients are refused and `listen_endpoint` returns 
/// `Error(Nil)`.
///
/// Returns `Error(Nil)` when no server is running under the `name`.
///
/// ```gleam
/// let assert Ok(Nil) = tup.suspend(name)
///
/// tup.listen_endpoint(name, within: 1000)
/// // -> Error(Nil)
/// ```
pub fn suspend(name: process.Name(Server)) -> Result(Nil, Nil) {
  use root <- result.try(process.named(name))
  tree.terminate_child(root, tree.acceptor_pool)
}

/// Open the listen socket again and start accepting connections after `suspend`. 
/// With port 0 the system picks a new port.
///
/// Returns `Error(Nil)` when no server is running under `name` or when the 
/// socket can't be opened again, for example because another program took the 
/// port while the server was suspended.
///
/// ```gleam
/// tup.resume(name)
/// // -> Ok(Nil)
/// ```
pub fn resume(name: process.Name(Server)) -> Result(Nil, Nil) {
  use root <- result.try(process.named(name))
  tree.restart_child(root, tree.acceptor_pool)
}

/// How many connections are open right now. Returns `Error(Nil)` when no
/// server is running under `name`.
///
/// ```gleam
/// tup.connection_count(name)
/// // -> Ok(12)
/// ```
pub fn connection_count(name: process.Name(Server)) -> Result(Int, Nil) {
  use root <- result.try(process.named(name))
  use connections <- result.try(tree.child(root, tree.connection_supervisor))
  tree.active_children(connections)
}

/// A child specification that runs the server under a supervisor.
///
/// ```gleam
/// static_supervisor.new(static_supervisor.OneForOne)
/// |> static_supervisor.add(tup.supervised(builder))
/// |> static_supervisor.start
/// ```
pub fn supervised(builder: Builder(user_state, user_message)) {
  use <- supervision.supervisor
  start(builder)
}

/// Starts the server linked to the calling process.
///
/// Fails with `actor.InitFailed` when a setting is out of range, a
/// certificate, key or trust store cannot be read or holds nothing, an ALPN
/// protocol is malformed, or `name` is already registered. A listen socket
/// that cannot be opened comes back as an `Error` as well, instead of
/// crashing the caller.
///
/// ```gleam
/// let assert Ok(_started) = tup.start(builder)
/// process.sleep_forever()
/// ```
pub fn start(builder: Builder(user_state, user_message)) {
  let Builder(
    address:,
    tls:,
    active_state:,
    pool_size:,
    shutdown_timeout:,
    buffer_size:,
    ipv6:,
    handlers:,
    name:,
  ) = builder

  use pool_size <- try_pool_size(pool_size)
  use shutdown_timeout <- try_shutdown_timeout(shutdown_timeout)
  use buffer_size <- try_buffer_size(buffer_size)

  use address <- result.try(case address {
    Tcp(interface:, port:) -> {
      use <- try_port(port)
      use interface <- try_interface(interface, ipv6)
      Ok(listener.Tcp(interface:, port:))
    }
    Unix(path:) -> {
      use <- try_unix_ipv6(ipv6)
      use <- try_unix_path(path)
      Ok(listener.Unix(path:))
    }
  })
  use tls <- try_tls(tls)

  let listener_argument = listener.Argument(address:, tls:, buffer_size:, ipv6:)
  let pool_argument = pool.Argument(pool_size:, active_state:, handlers:)

  use <- try_name(name)

  // The current supervision tree design is:
  //
  // ┆
  // ┆
  // └─ Root Supervisor, RestForOne outer relay_supervisor
  //    ├─ Connection Supervisor, OneForOne Transient factory_supervisor
  //    │  └─ Spawned Connection, worker N
  //    └─ Acceptor Pool, RestForOne inner relay_supervisor
  //       ├─ Listener, worker
  //       └─ Pool, OneForOne static_supervisor
  //         ├─ Acceptor, worker 1
  //         ├─ Acceptor, worker 2
  //         ┆
  //         ┆
  //         └─ Acceptor, worker N
  //
  // At the time of writing the documentation lines, current implementation 
  // provides these solutions over Glisten:
  //
  // - There is no enforced process naming in Tup. Relay supervisors allows the 
  //   children to accept and return arguments to the next children in the order.
  //   *However*! This comes with a small tradeoff. Relay supervisors are using 
  //   RestForOne strategies. On a connection supervisor restart the restart 
  //   cascased through the inner relay and the listen socket is reopened. 
  //   Glisten's acceptor uses a name for referencing its connection supervisor 
  //   and allows each child survive the restarts without touching the port. 
  //
  // - Accept errors are handled properly. Glisten kills the acceptor on any 
  //   accept error. In Tup I decided that on Closed or Einval we can stop 
  //   normally, on Emfile or Enfile it's better to wait some time, around 100ms.
  //   On Timeout or Econnaborted there is no reason to abnormally crash, just
  //   continue looping over the acceptor.
  //   
  //   This matters most under descriptor exhaustion. Glisten treats Emfile as
  //   abnormal and its acceptors are Permanent so every acceptor crashes and
  //   is restarted straight back into the same error until the pool supervisor
  //   reaches its restart intensity and dies.
  //
  // - Any handoff race is pretty much resolved. Glisten's connection waits for
  //   Ready with no monitor or timeout, so an acceptor dying mid handoff leaks
  //   a connection process or, in the worst timing when acceptor died after 
  //   transfering socket controls, a fd. Tup monitors the acceptor and 
  //   demonitors on Ready.
  //
  // - The shutdown order is changed. Glisten kills the connections first while
  //   acceptors still accept and the port is still open. This can create a 
  //   scenario during the shutdown phase when the connections are accepted, 
  //   leading them to fail. Tup kills acceptor and socket first and only after 
  //   that deals with connections.
  //
  // - Glisten has no timeout on accepting the connection. It may seem okay at
  //   first but there is no way to use the tracing and debugging features in
  //   OTP that actor abstraction provides while the accept is infinitely 
  //   waiting for the new connection. Tup has 30 seconds accept timeout that 
  //   can at least provide some interval for reading incomming OTP messages.
  //
  use <- trapping_exits

  relay.new(fn(children) {
    case name {
      option.Some(name) -> {
        case process.register(process.self(), name) {
          Ok(Nil) -> Nil
          Error(Nil) ->
            logging.log(
              logging.Error,
              "Failed to bind the acceptor pool to the name provided! The name has already been registered.",
            )
        }
      }
      option.None -> Nil
    }

    connection.add_child(children, shutdown_timeout)
    |> pool.add_child(listener_argument, pool_argument)
  })
  |> relay.start
}

/// Run `start` with exits trapped. The main reason why is so a server that 
/// fails to start returns an `Error` instead of killing the caller through the 
/// link.
@external(erlang, "tup_ffi", "trapping_exits")
fn trapping_exits(start: fn() -> a) -> a

/// Rejects a buffer size that is not greater than zero.
fn try_buffer_size(
  buffer_size: option.Option(Int),
  callback: fn(option.Option(Int)) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case buffer_size {
    option.Some(bytes) if bytes <= 0 ->
      Error(actor.InitFailed("Provided buffer size is negative or equals to 0."))
    buffer_size -> callback(buffer_size)
  }
}

/// Rejects a negative timeout. `ShutdownNever` becomes `-1` which gleam_otp
/// treats as infinity.
fn try_shutdown_timeout(
  shutdown_timeout: ShutdownTimeout,
  callback: fn(Int) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case shutdown_timeout {
    ShutdownAfter(milliseconds:) if milliseconds < 0 ->
      Error(actor.InitFailed(
        "Provided shutdown timeout is negative. Use infinite_shutdown_timeout to wait for connections without a limit.",
      ))
    ShutdownAfter(milliseconds:) -> callback(milliseconds)
    ShutdownNever -> callback(-1)
  }
}

/// Rejects a pool size that is not greater than zero.
fn try_pool_size(
  pool_size: Int,
  callback: fn(Int) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case pool_size {
    pool_size if pool_size <= 0 ->
      Error(actor.InitFailed("Provided pool size is negative or equals to 0."))
    pool_size -> callback(pool_size)
  }
}

/// Rejects a port outside 0..65535.
fn try_port(
  port: Int,
  callback: fn() -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case port {
    port if port < 0 || port > 65_535 ->
      Error(actor.InitFailed("Port provided outside of a 0..65535 window."))
    _port -> callback()
  }
}

/// Resolves the interface string. `"0.0.0.0"` is `Any`, `"localhost"` and
/// `"127.0.0.1"` are `Loopback`, any other valid address is bound as given.
fn try_interface(
  interface: String,
  ipv6: Bool,
  callback: fn(socket.Interface) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case interface, parse_address(interface) {
    "0.0.0.0", _parsed -> callback(socket.Any)
    "localhost", _parsed | "127.0.0.1", _parsed -> callback(socket.Loopback)
    _interface, Ok(socket.Ipv4(..)) if ipv6 ->
      "Provided interface is an IPv4 address, which force_ipv6 cannot listen on. Use an IPv6 address or drop force_ipv6."
      |> actor.InitFailed
      |> Error
    _interface, Ok(ip_address) -> callback(socket.Address(ip_address))
    _interface, Error(Nil) ->
      "Invalid interface provided. The value must be a valid IPv4/IPv6 address or \"localhost\""
      |> actor.InitFailed
      |> Error
  }
}

/// Parses an IPv4 or IPv6 address from text.
@external(erlang, "tup_ffi", "parse_address")
fn parse_address(interface: String) -> Result(socket.IpAddress, Nil)

/// A unix socket has no address family to force.
fn try_unix_ipv6(
  ipv6: Bool,
  callback: fn() -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case ipv6 {
    True ->
      "A unix socket cannot listen on IPv6. Drop force_ipv6."
      |> actor.InitFailed
      |> Error
    False -> callback()
  }
}

/// Rejects an empty path, a path over 107 bytes, or one containing NUL.
fn try_unix_path(
  path: String,
  callback: fn() -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case path, string.byte_size(path) {
    "", _length -> Error(actor.InitFailed("Empty unix path is not allowed."))
    _path, length if length > 107 ->
      Error(actor.InitFailed("Unix path must not be over 107 bytes limit."))
    path, _length -> {
      case string.contains(does: path, contain: "\u{000000}") {
        True -> Error(actor.InitFailed("Unix containing NUL is not allowed."))
        False -> callback()
      }
    }
  }
}

/// Options every TLS server gets: TLS 1.2 and 1.3 only, the server's cipher
/// order, no client renegotiation.
const default_tls_options = [
  socket.Versions([socket.Tls12, socket.Tls13]),
  socket.HonorCipherOrder(True),
  socket.ClientRenegotiation(False),
]

/// Builds the TLS option list from the settings. `None` passes through for
/// plain TCP.
fn try_tls(
  tls: option.Option(Tls),
  callback: fn(option.Option(List(socket.TlsOption))) ->
    Result(a, actor.StartError),
) {
  case tls {
    option.Some(Tls(certificate:, client_certificates:, alpn:, session_tickets:)) -> {
      use certificate <- try_certificate(certificate)
      use client_certificates <- try_client_certificates(client_certificates)
      use alpn <- try_alpn(alpn)

      let tls_options = [
        socket.CertificateKeys([certificate]),
        socket.SessionTickets(to_internal_ticket_mode(session_tickets)),
        ..client_certificates
      ]

      let tls_options = case alpn {
        [] -> tls_options
        alpn -> [socket.AlpnPreferredProtocols(alpn), ..tls_options]
      }

      callback(option.Some(list.append(default_tls_options, tls_options)))
    }
    option.None -> callback(option.None)
  }
}

/// Encodes the protocols as bytes, dropping duplicates and rejecting names
/// that are empty or over 255 bytes.
fn try_alpn(
  alpn: List(String),
  callback: fn(List(BitArray)) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  list.unique(alpn)
  |> list.try_map(with: fn(protocol) {
    case protocol, string.byte_size(protocol) {
      "", _length -> Error(actor.InitFailed("Empty ALPN protocol provided."))
      _protocol, length if length > 255 ->
        Error(actor.InitFailed(
          "\"" <> protocol <> "\" ALPN protocol exceeded 255 byte limit.",
        ))
      _protocol, _length -> Ok(bit_array.from_string(protocol))
    }
  })
  |> result.try(callback)
}

/// Loads the certificate chain and key from whichever source was given.
fn try_certificate(
  tls: Certificate,
  callback: fn(socket.CertificateKey) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case tls {
    Disk(cert:, key:) -> try_disk_certificate(cert, key, option.None, callback)
    EncryptedDisk(cert:, key:, password:) ->
      try_disk_certificate(cert, key, option.Some(password), callback)
    Pem(cert:, key:) -> try_pem_certificate(cert, key, option.None, callback)
    EncryptedPem(cert:, key:, password:) ->
      try_pem_certificate(cert, key, option.Some(password), callback)
    Der(chain:, key:) -> try_der_certificate(chain, key, callback)
  }
}

/// Reads the certificate and key files and decodes them as PEM.
fn try_disk_certificate(
  certificate_file: String,
  key_file: String,
  password: option.Option(String),
  callback: fn(socket.CertificateKey) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  use certificate <- try_read(certificate_file)
  use key <- try_read(key_file)

  try_pem_certificate(certificate, key, password, callback)
}

/// Reads a file. A failure becomes an `InitFailed` naming the path.
fn try_read(
  path: String,
  callback: fn(BitArray) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case file.read(path) {
    Ok(bytes) -> callback(bytes)
    Error(reason) ->
      Error(actor.InitFailed(
        "Could not read "
        <> path
        <> ": "
        <> file.reason_to_string(reason)
        <> ".",
      ))
  }
}

/// Error for a certificate source that holds no certificate.
const no_certificate = "No certificate was given. A listener with no certificate accepts connections and then fails every handshake."

/// Decodes a PEM chain and private key, with `password` when the key is
/// encrypted.
fn try_pem_certificate(
  cert: BitArray,
  key: BitArray,
  password: option.Option(String),
  callback: fn(socket.CertificateKey) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case socket.certificates_from_pem(cert) {
    [] -> Error(actor.InitFailed(no_certificate))
    chain ->
      case socket.private_key_from_pem(key, password) {
        Ok(key) -> callback(socket.CertificateChain(chain:, key:))
        Error(pem_error) ->
          Error(actor.InitFailed(
            "Could not read the private key: "
            <> socket.describe_pem_error(pem_error)
            <> ".",
          ))
      }
  }
}

/// Wraps a DER chain and its key, rejecting an empty chain.
fn try_der_certificate(
  chain: List(BitArray),
  key: TlsPrivateKey,
  callback: fn(socket.CertificateKey) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case chain {
    [] -> Error(actor.InitFailed(no_certificate))
    chain ->
      callback(socket.CertificateChain(chain:, key: to_internal_key(key)))
  }
}

/// Builds the peer verification options for the client certificate policy.
/// None when clients are not verified.
fn try_client_certificates(
  client_certificates: option.Option(ClientCertificates),
  callback: fn(List(socket.TlsOption)) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case client_certificates {
    option.Some(Requested(trusting:)) ->
      try_trust_store(trusting, False, callback)
    option.Some(Required(trusting:)) ->
      try_trust_store(trusting, True, callback)
    option.None -> callback([])
  }
}

/// Error for a trust store that holds no certificate.
const no_trust_store = "The trust store holds no certificate. There is no authority to check client certificates against, so every client would be rejected."

/// Loads the trust store and pairs it with the peer verification options.
/// `required` decides whether a client without a certificate is refused.
fn try_trust_store(
  store: TrustStore,
  required: Bool,
  callback: fn(List(socket.TlsOption)) -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  let options = [
    socket.Verify(socket.VerifyPeer),
    socket.FailWithoutPeerCertificate(required),
  ]

  case store {
    SystemTrustStore -> {
      let authorities =
        socket.CertificateAuthorities(socket.system_certificate_authorities())
      callback([authorities, ..options])
    }
    TrustDisk(path:) -> {
      use bytes <- try_read(path)
      try_pem_trust_store(bytes, options, callback)
    }
    TrustPem(bytes:) -> try_pem_trust_store(bytes, options, callback)
    TrustDer(certificates:) ->
      case certificates {
        [] -> Error(actor.InitFailed(no_trust_store))
        certificates ->
          callback([socket.CertificateAuthorities(certificates), ..options])
      }
  }
}

/// Decodes PEM encoded authorities, rejecting an empty bundle.
fn try_pem_trust_store(
  bytes: BitArray,
  options: List(socket.TlsOption),
  callback: fn(List(socket.TlsOption)) -> Result(a, actor.StartError),
) {
  case socket.certificates_from_pem(bytes) {
    [] -> Error(actor.InitFailed(no_trust_store))
    certificates ->
      callback([socket.CertificateAuthorities(certificates), ..options])
  }
}

/// Rejects a name that is already registered.
fn try_name(
  name: option.Option(process.Name(Server)),
  callback: fn() -> Result(a, actor.StartError),
) -> Result(a, actor.StartError) {
  case name {
    option.Some(name) ->
      case process.named(name) {
        Ok(_pid) ->
          "name provided to the acceptor pool is already registered"
          |> actor.InitFailed
          |> Error
        Error(Nil) -> callback()
      }

    option.None -> callback()
  }
}
