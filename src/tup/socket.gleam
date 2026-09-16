//// Bindings to the Erlang modules for accepting and working with TCP and TLS
//// connections.
////
//// - [`gen_tcp`](https://www.erlang.org/doc/apps/kernel/gen_tcp.html)
//// - [`inet`](https://www.erlang.org/doc/apps/kernel/inet.html)
//// - [`ssl`](https://www.erlang.org/doc/apps/ssl/ssl.html)
//// - [`public_key`](https://www.erlang.org/doc/apps/public_key/public_key.html)
////
//// <script>
//// const docs = [
////   {
////     header: "Listening",
////     functions: [
////       "listen",
////       "listen_tls",
////       "accept",
////       "handshake",
////       "close_listener",
////       "sockname_listener"
////     ]
////   },
////   {
////     header: "Connections",
////     functions: [
////       "send",
////       "receive",
////       "close",
////       "shutdown",
////       "controlling_process",
////       "set_options",
////       "selector"
////     ]
////   },
////   {
////     header: "Information",
////     functions: [
////       "sockname",
////       "peername",
////       "negotiated_protocol",
////       "peer_certificate"
////     ]
////   },
////   {
////     header: "Certificates",
////     functions: [
////       "certificates_from_pem",
////       "private_key_from_pem",
////       "system_certificate_authorities"
////     ]
////   },
////   {
////     header: "Addresses",
////     functions: [
////       "ip_address_to_string",
////       "endpoint_to_string"
////     ]
////   },
////   {
////     header: "Errors",
////     functions: [
////       "describe_error",
////       "describe_alert_description",
////       "describe_pem_error"
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

import gleam/bytes_tree
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/option
import gleam/result
import gleam/string

/// A socket that accepts connections.
pub type ListenSocket

/// An accepted connection.
pub type Socket

/// Which Erlang module a socket belongs to. Returned by `listen` and `listen_tls`
/// and passed to everything else.
pub type Transport {
  /// Plain TCP.
  Tcp
  /// TLS.
  Ssl
}

/// An IPv4 or IPv6 address.
pub type IpAddress {
  /// Four octets.
  Ipv4(Int, Int, Int, Int)
  /// Eight 16 bit groups.
  Ipv6(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// Where a socket or its peer is bound.
pub type Endpoint {
  /// An address and port.
  TcpEndpoint(ip_address: IpAddress, port: Int)
  /// The path of a Unix domain socket.
  UnixEndpoint(path: String)
}

/// How long a blocking call may wait.
pub type Timeout {
  /// Give up after this many milliseconds.
  Milliseconds(Int)
  /// Wait forever.
  Never
}

/// Which direction of a connection `shutdown` closes.
pub type ShutdownMode {
  /// Stop receiving. Anything the peer sends from now on is discarded.
  Read
  /// Stop sending. The peer sees the end of the stream.
  Write
  /// Stop both.
  ReadWrite
}

/// Why a call failed. The variants starting with `E` are the operating 
/// system's errno values under their usual names.
pub type SocketError {
  /// The socket is closed.
  Closed
  /// The call's timeout ran out.
  Timeout
  /// The calling process does not own the socket.
  NotOwner
  /// An Erlang system limit was reached.
  SystemLimit
  /// The call does not exist on this transport.
  Unsupported
  /// No ALPN protocol was agreed.
  NotNegotiated
  /// The peer sent no certificate.
  NoPeerCertificate
  /// A TLS alert sent by the peer or raised locally. `detail` is Erlang's
  /// wording of it.
  TlsAlert(description: AlertDescription, detail: String)
  /// A `TlsOption` was rejected before the socket opened. This always indicates 
  /// a configuration mistake.
  BadTlsOption(option: String, detail: String)
  /// Permission denied.
  Eacces
  /// The address and port are already bound by another socket.
  Eaddrinuse
  /// The address is not one of this host's.
  Eaddrnotavail
  /// The address family is not supported.
  Eafnosupport
  /// The operation would block on a non-blocking socket.
  Eagain
  /// An operation is already in progress on the socket.
  Ealready
  /// The descriptor is not valid.
  Ebadf
  /// The connection was aborted before it was accepted.
  Econnaborted
  /// The peer refused the connection.
  Econnrefused
  /// The peer reset the connection.
  Econnreset
  /// The remote host is down.
  Ehostdown
  /// No route to the remote host.
  Ehostunreach
  /// The operation is in progress.
  Einprogress
  /// The call was interrupted by a signal.
  Eintr
  /// An argument was invalid.
  Einval
  /// An input or output error.
  Eio
  /// The socket is already connected.
  Eisconn
  /// The process ran out of file descriptors.
  Emfile
  /// The message is longer than the transport allows.
  Emsgsize
  /// The network is down.
  Enetdown
  /// The connection was reset by the network.
  Enetreset
  /// The network is unreachable.
  Enetunreach
  /// The system ran out of file descriptors.
  Enfile
  /// The system ran out of buffer space.
  Enobufs
  /// The system ran out of memory.
  Enomem
  /// The protocol does not know the option.
  Enoprotoopt
  /// The socket is not connected.
  Enotconn
  /// The descriptor is not a socket.
  Enotsock
  /// The operating system does not support the operation.
  Enotsup
  /// The operation is not permitted.
  Eperm
  /// The write end is closed.
  Epipe
  /// A protocol error.
  Eproto
  /// The protocol is not supported.
  Eprotonosupport
  /// The wrong protocol type for the socket.
  Eprototype
  /// The connection timed out.
  Etimedout
  /// The operation would block. The same as `Eagain` on most systems.
  Ewouldblock
  /// The inet driver was given a bad port.
  Exbadport
  /// The inet driver was given commands out of sequence.
  Exbadseq
  /// A reason with no fixed shape.
  Failure(reason: dynamic.Dynamic)
}

/// What a TLS alert says, as listed in
/// [RFC 8446](https://www.rfc-editor.org/rfc/rfc8446#section-6.2).
pub type AlertDescription {
  /// The sender is closing the connection cleanly.
  CloseNotify
  /// A message arrived out of order.
  UnexpectedMessage
  /// A record failed its authentication check.
  BadRecordMac
  /// A record was longer than the protocol allows.
  RecordOverflow
  /// No set of security parameters could be agreed.
  HandshakeFailure
  /// The certificate is corrupt.
  BadCertificate
  /// The certificate is of an unsupported type.
  UnsupportedCertificate
  /// The certificate was revoked by its signer.
  CertificateRevoked
  /// The certificate has expired or is not yet valid.
  CertificateExpired
  /// The certificate was rejected for an unspecified reason.
  CertificateUnknown
  /// A handshake field was out of range or inconsistent.
  IllegalParameter
  /// The certificate chain does not end at a trusted authority.
  UnknownCa
  /// The certificate is valid but was refused access.
  AccessDenied
  /// A message could not be decoded.
  DecodeError
  /// A cryptographic operation failed.
  DecryptError
  /// The peer offered an unsupported protocol version.
  ProtocolVersion
  /// The peer's security parameters are too weak.
  InsufficientSecurity
  /// A local error unrelated to the protocol or the peer.
  InternalError
  /// The peer attempted a version downgrade.
  InappropriateFallback
  /// The handshake was cancelled for a reason unrelated to the protocol.
  UserCanceled
  /// Renegotiation was refused.
  NoRenegotiation
  /// A required extension was absent.
  MissingExtension
  /// The peer returned an extension that was never offered.
  UnsupportedExtension
  /// The certificate could not be fetched.
  CertificateUnobtainable
  /// The server does not serve the requested SNI name.
  UnrecognizedName
  /// The OCSP response is invalid.
  BadCertificateStatusResponse
  /// The pre shared key identity is not known.
  UnknownPskIdentity
  /// A certificate was required and the client sent none.
  CertificateRequired
  /// The ALPN lists have no protocol in common.
  NoApplicationProtocol
  /// An alert with no fixed shape.
  UnknownAlert
}

/// Whether received data is delivered as `Message`s or read with `receive`.
pub type ActiveState {
  /// Nothing is delivered. Read the socket with `receive`.
  Passive
  /// Every message as it arrives.
  Always
  /// One message, then back to `Passive`.
  Once
  /// `count` messages, then back to `Passive`.
  Packets(count: Int)
}

/// Which local address a listen socket binds.
pub type Interface {
  /// The interface that has this address.
  Address(IpAddress)
  /// Every interface. The default.
  Any
  /// The loopback interface only.
  Loopback
  /// The path of a Unix domain socket. Needs `port` to be `0`.
  Local(String)
}

/// The address family of a socket.
pub type AddressFamily {
  /// IPv4.
  Inet
  /// IPv6.
  Inet6
}

/// Options for either transport. The ones marked "listen only" are fixed when
/// the socket opens. The rest can also be changed later with `set_options`.
///
/// Sockets are always opened in binary mode and deliver bytes unframed.
pub type TcpOption {
  /// Listen only. How many pending connections the kernel queues.
  Backlog(Int)
  /// Listen only. The local address to bind.
  BindAddress(Interface)
  /// Listen only. The address family which has to match `BindAddress`.
  Family(AddressFamily)
  /// Listen only. Refuse IPv4 mapped addresses on an IPv6 socket.
  Ipv6Only(Bool)
  /// Listen only. An already open file descriptor to listen on.
  FileDescriptor(Int)
  /// How received data reaches the owner.
  Active(ActiveState)
  /// Allow binding a port that is still in `TIME_WAIT`. That allows a restarted
  /// server to reclaim its port.
  ReuseAddress(Bool)
  /// Let several sockets bind the same port.
  ReusePort(Bool)
  /// Send small writes at once instead of coalescing them (Nagle's algorithm).
  NoDelay(Bool)
  /// Let the driver queue writes rather than sending each one immediately.
  DelaySend(Bool)
  /// Send periodic TCP keepalive probes.
  KeepAlive(Bool)
  /// Whether `close` blocks to flush unsent data and for how long.
  Linger(enabled: Bool, seconds: Int)
  /// How long a send waits on a peer that is not reading.
  SendTimeout(Timeout)
  /// Close the socket when a send times out.
  SendTimeoutClose(Bool)
  /// Whether the socket closes when the peer closes its end. `False` keeps
  /// the write side usable after the peer has finished sending.
  ExitOnClose(Bool)
  /// Report a reset as `Econnreset` instead of a plain close.
  ShowConnectionReset(Bool)
  /// The driver's user level receive buffer in bytes.
  Buffer(Int)
  /// The kernel receive buffer in bytes.
  ReceiveBuffer(Int)
  /// The kernel send buffer in bytes.
  SendBuffer(Int)
  /// The send queue size at which the port counts as busy.
  HighWatermark(Int)
  /// The send queue size at which the port counts as idle again.
  LowWatermark(Int)
  /// `HighWatermark` for the driver's message queue.
  HighMessageQueueWatermark(Int)
  /// `LowWatermark` for the driver's message queue.
  LowMessageQueueWatermark(Int)
}

/// Whether the server asks the client for a certificate.
pub type VerifyMode {
  /// No certificate is requested.
  VerifyNone
  /// A certificate is requested and checked.
  VerifyPeer
}

/// A TLS protocol version. 1.0 and 1.1 are deprecated by
/// [RFC 8996](https://www.rfc-editor.org/rfc/rfc8996) and are not offered.
pub type TlsVersion {
  /// TLS 1.3.
  Tls13
  /// TLS 1.2.
  Tls12
}

/// Whether a verified certificate is also checked against a revocation list.
/// Only applies with `Verify(VerifyPeer)`.
pub type CrlMode {
  /// No revocation check.
  CrlDisabled
  /// Check every certificate in the chain. A list that cannot be fetched
  /// fails the connection.
  CrlWholeChain
  /// Check the peer's own certificate only.
  CrlPeerOnly
  /// Check what can be checked. A list that cannot be fetched is ignored.
  CrlBestEffort
}

/// A group the key exchange may use. Either an elliptic curve or a finite
/// field Diffie-Hellman group from
/// [RFC 7919](https://www.rfc-editor.org/rfc/rfc7919).
pub type KeyExchangeGroup {
  /// Curve25519.
  X25519
  /// Curve448.
  X448
  /// NIST P-256.
  Secp256r1
  /// NIST P-384.
  Secp384r1
  /// NIST P-521.
  Secp521r1
  /// 2048 bit finite field.
  Ffdhe2048
  /// 3072 bit finite field.
  Ffdhe3072
  /// 4096 bit finite field.
  Ffdhe4096
  /// 6144 bit finite field.
  Ffdhe6144
  /// 8192 bit finite field.
  Ffdhe8192
}

/// Which TLS 1.3 session resumption the server offers.
pub type TicketMode {
  /// None.
  TicketsDisabled
  /// The server keeps the session state.
  Stateful
  /// The session state travels inside the ticket.
  Stateless
}

/// How much a TLS connection writes to the logger.
pub type LogLevel {
  /// Nothing.
  LogNothing
  /// Errors.
  LogError
  /// Errors and warnings.
  LogWarning
  /// The above and notices.
  LogNotice
  /// The above and informational messages.
  LogInformation
  /// The above and debug messages.
  LogDebug
  /// Everything.
  LogEverything
}

/// A certificate chain together with the private key of the certificate it
/// ends in.
pub type CertificateKey {
  /// PEM files on disk. `password` decrypts the key file when it is
  /// encrypted.
  CertificateFiles(
    certificate_file: String,
    key_file: String,
    password: option.Option(String),
  )

  /// DER in memory. The server's own certificate first and then each issuer.
  CertificateChain(chain: List(BitArray), key: PrivateKey)
}

/// A DER encoded private key named after the ASN.1 structure it is encoded
/// as. Encrypted keys have to be decrypted before they get here.
pub type PrivateKey {
  /// A PKCS #1 `RSAPrivateKey`.
  RsaPrivateKey(BitArray)
  /// A `DSAPrivateKey`.
  DsaPrivateKey(BitArray)
  /// A SEC 1 `ECPrivateKey`.
  EcPrivateKey(BitArray)
  /// A PKCS #8 `PrivateKeyInfo`.
  PrivateKeyInfo(BitArray)
}

/// Why a private key could not be read from PEM.
pub type PemError {
  /// The bytes hold no private key.
  NoPrivateKey
  /// The key is encrypted and no password was given.
  EncryptedPrivateKey
  /// The password does not decrypt the key.
  WrongPassword
}

/// The TLS options a listener takes alongside its `TcpOption`s.
pub type TlsOption {
  /// The server's own certificates and keys. It is required to have at least 
  /// one specified since an empty list opens a socket that accepts connections 
  /// and then fails every handshake.
  CertificateKeys(List(CertificateKey))
  /// Certificates to serve instead of `CertificateKeys` when the client asks
  /// for a particular name through SNI keyed by that name.
  ServerNameCertificates(List(#(String, CertificateKey)))
  /// A PEM file of trusted certificate authorities.
  CertificateAuthorityFile(String)
  /// Trusted certificate authorities as DER.
  CertificateAuthorities(List(BitArray))
  /// Whether the server tells the client which authorities it accepts when
  /// asking for a certificate. TLS 1.3 only.
  SendCertificateAuthorities(Bool)
  /// Whether the client is asked for a certificate.
  Verify(VerifyMode)
  /// With `VerifyPeer`, reject a client that sends no certificate.
  FailWithoutPeerCertificate(Bool)
  /// How many intermediate certificates a chain may have.
  Depth(Int)
  /// Whether a verified certificate is also checked against a revocation list.
  CrlCheck(CrlMode)
  /// The protocol versions the server accepts.
  Versions(List(TlsVersion))
  /// The groups the key exchange may use, most preferred first. Applies to
  /// TLS 1.3 and to the TLS 1.2 elliptic curve exchanges.
  SupportedGroups(List(KeyExchangeGroup))
  /// The protocols the server picks from the client's ALPN list, most
  /// preferred first.
  AlpnPreferredProtocols(List(BitArray))
  /// Use the server's cipher order rather than the client's.
  HonorCipherOrder(Bool)
  /// Allow TLS 1.2 session resumption.
  ReuseSessions(Bool)
  /// Refuse to renegotiate with a peer that does not support
  /// [RFC 5746](https://www.rfc-editor.org/rfc/rfc5746). TLS 1.2 only,
  /// since 1.3 has no renegotiation.
  SecureRenegotiate(Bool)
  /// Whether the client may ask to renegotiate. TLS 1.2 only.
  ClientRenegotiation(Bool)
  /// Which TLS 1.3 session resumption to offer.
  SessionTickets(TicketMode)
  /// A PEM file of Diffie-Hellman parameters.
  DiffieHellmanFile(String)
  /// Hibernate an idle connection process after this many milliseconds.
  HibernateAfter(Int)
  /// The largest handshake message accepted.
  MaximumHandshakeSize(Int)
  /// How much the connection writes to the logger.
  Logging(LogLevel)
}

/// What a non-`Passive` socket delivers to its owner. Build a selector for
/// them with `selector`.
pub type Message {
  /// Data received.
  Incoming(BitArray)
  /// The peer closed the connection.
  Disconnected
  /// The connection failed and is now closed.
  Failed(reason: SocketError)
  /// The socket has gone back to `Passive`.
  Exhausted
}

/// A `SocketError` as a lower case phrase that reads after a colon.
///
/// ```gleam
/// "Could not open the listen socket: " <> describe_error(error)
/// ```
pub fn describe_error(error: SocketError) -> String {
  case error {
    Closed -> "the socket is closed"
    Timeout -> "the call ran out of time"
    NotOwner -> "the calling process does not own the socket"
    SystemLimit -> "an Erlang system limit was reached"
    Unsupported -> "the call does not exist on this transport"
    NotNegotiated -> "the handshake agreed no ALPN protocol"
    NoPeerCertificate -> "the peer sent no certificate"
    TlsAlert(description:, detail:) ->
      "the TLS connection was closed by an alert, "
      <> describe_alert_description(description)
      <> " ("
      <> detail
      <> ")"
    BadTlsOption(option:, detail:) ->
      "the TLS option " <> option <> " was rejected, " <> detail
    Eacces -> "permission was denied"
    Eaddrinuse -> "the address is already bound by another socket"
    Eaddrnotavail -> "the address is not one of this host's"
    Eafnosupport -> "the address family is not supported"
    Eagain -> "the operation would block and the socket is not blocking"
    Ealready -> "an operation is already in progress on the socket"
    Ebadf -> "the descriptor is not valid"
    Econnaborted -> "the connection was aborted before it was accepted"
    Econnrefused -> "the peer refused the connection"
    Econnreset -> "the peer reset the connection"
    Ehostdown -> "the remote host is down"
    Ehostunreach -> "there is no route to the remote host"
    Einprogress -> "the operation is in progress"
    Eintr -> "the call was interrupted by a signal"
    Einval -> "an argument was invalid"
    Eio -> "an input or output error occurred"
    Eisconn -> "the socket is already connected"
    Emfile -> "the process ran out of file descriptors"
    Emsgsize -> "the message is longer than the transport allows"
    Enetdown -> "the network is down"
    Enetreset -> "the connection was reset by the network"
    Enetunreach -> "the network is unreachable"
    Enfile -> "the system ran out of file descriptors"
    Enobufs -> "the system ran out of buffer space"
    Enomem -> "the system ran out of memory"
    Enoprotoopt -> "the protocol does not know the option"
    Enotconn -> "the socket is not connected"
    Enotsock -> "the descriptor is not a socket"
    Enotsup -> "the operating system does not support the operation"
    Eperm -> "the operation is not permitted"
    Epipe -> "the write end is closed"
    Eproto -> "a protocol error occurred"
    Eprotonosupport -> "the protocol is not supported"
    Eprototype -> "the wrong protocol type for the socket"
    Etimedout -> "the connection timed out"
    Ewouldblock -> "the operation would block"
    Exbadport -> "the inet driver was given a bad port"
    Exbadseq -> "the inet driver was given commands out of sequence"
    Failure(reason:) ->
      "the call failed with "
      <> string.inspect(reason)
      <> ", which these bindings do not name"
  }
}

/// An `AlertDescription` as a lower case phrase that reads after a colon.
pub fn describe_alert_description(description: AlertDescription) -> String {
  case description {
    CloseNotify -> "the sender is closing the connection cleanly"
    UnexpectedMessage -> "a message arrived out of order"
    BadRecordMac -> "a record failed its authentication check"
    RecordOverflow -> "a record was longer than the protocol allows"
    HandshakeFailure -> "no acceptable set of security parameters was agreed"
    BadCertificate -> "the certificate was corrupt"
    UnsupportedCertificate -> "the certificate is of an unsupported type"
    CertificateRevoked -> "the certificate was revoked by its signer"
    CertificateExpired -> "the certificate has expired or is not yet valid"
    CertificateUnknown ->
      "the certificate was rejected for an unspecified reason"
    IllegalParameter -> "a handshake field was out of range or inconsistent"
    UnknownCa -> "the certificate chain led to no trusted authority"
    AccessDenied -> "a valid certificate was refused access"
    DecodeError -> "a message could not be decoded"
    DecryptError -> "a cryptographic operation failed"
    ProtocolVersion -> "the peer offered an unsupported protocol version"
    InsufficientSecurity -> "the peer's security parameters are too weak"
    InternalError -> "a local error unrelated to the protocol or the peer"
    InappropriateFallback -> "the peer attempted a version downgrade"
    UserCanceled ->
      "the handshake was cancelled for a reason unrelated to the protocol"
    NoRenegotiation -> "renegotiation was refused"
    MissingExtension -> "a required extension was absent"
    UnsupportedExtension ->
      "an extension was returned that the peer never offered"
    CertificateUnobtainable -> "the certificate could not be fetched"
    UnrecognizedName -> "the server does not serve the requested SNI name"
    BadCertificateStatusResponse -> "the OCSP response was invalid"
    UnknownPskIdentity -> "the pre shared key identity is not known"
    CertificateRequired ->
      "the client sent no certificate when one was required"
    NoApplicationProtocol -> "the ALPN lists had no protocol in common"
    UnknownAlert -> "the peer sent an alert these bindings do not name"
  }
}

/// A `PemError` as a lower case phrase that reads after a colon.
pub fn describe_pem_error(error: PemError) -> String {
  case error {
    NoPrivateKey -> "the bytes hold no private key"
    EncryptedPrivateKey -> "the key is encrypted and no password was given"
    WrongPassword ->
      "the key is encrypted and the password given does not decrypt it"
  }
}

/// An address as text, following
/// [RFC 5952](https://www.rfc-editor.org/rfc/rfc5952): the lower case hex, the
/// longest run of zero groups collapsed to `::` and IPv4 mapped addresses in
/// their mixed form such as `::ffff:192.0.2.1`.
///
/// [`inet:ntoa/1`](https://www.erlang.org/doc/apps/kernel/inet.html#ntoa/1)
@external(erlang, "tup_socket_ffi", "ip_address_to_string")
pub fn ip_address_to_string(address: IpAddress) -> String

/// An endpoint as text. IPv6 addresses are bracketed. An abstract Unix socket 
/// whose path starts with a NUL byte is written with a leading `@`. An unnamed 
/// Unix endpoint is the empty string.
pub fn endpoint_to_string(endpoint: Endpoint) -> String {
  case endpoint {
    TcpEndpoint(ip_address: Ipv4(..) as address, port:) ->
      ip_address_to_string(address) <> ":" <> int.to_string(port)
    TcpEndpoint(ip_address: Ipv6(..) as address, port:) ->
      "[" <> ip_address_to_string(address) <> "]:" <> int.to_string(port)
    UnixEndpoint(path: "\u{0}" <> name) -> "@" <> name
    UnixEndpoint(path:) -> path
  }
}

/// A selector for the messages of a socket on this transport. Merge it into
/// the selector of the process that owns a non-`Passive` socket.
pub fn selector(transport: Transport) -> process.Selector(Message) {
  let #(incoming, closed, failed, exhausted) = case transport {
    Tcp -> #("tcp", "tcp_closed", "tcp_error", "tcp_passive")
    Ssl -> #("ssl", "ssl_closed", "ssl_error", "ssl_passive")
  }

  process.new_selector()
  |> process.select_record(atom.create(incoming), 2, to_message)
  |> process.select_record(atom.create(closed), 1, to_message)
  |> process.select_record(atom.create(failed), 2, to_message)
  |> process.select_record(atom.create(exhausted), 1, to_message)
}

/// Open a TCP listen socket on `port` or on a port the system picks when
/// `port` is `0`. The socket belongs to the calling process and closes when
/// that process exits.
///
/// [`gen_tcp:listen/2`](https://www.erlang.org/doc/apps/kernel/gen_tcp.html#listen/2)
pub fn listen(
  port: Int,
  options: List(TcpOption),
) -> Result(#(Transport, ListenSocket), SocketError) {
  tcp_listen(port, options)
  |> result.map(fn(socket) { #(Tcp, socket) })
}

/// `listen` over TLS. A rejected TLS option fails as `BadTlsOption`.
///
/// [`ssl:listen/2`](https://www.erlang.org/doc/apps/ssl/ssl.html#listen/2)
pub fn listen_tls(
  port: Int,
  options: List(TcpOption),
  tls_options: List(TlsOption),
) -> Result(#(Transport, ListenSocket), SocketError) {
  ssl_listen(port, options, tls_options)
  |> result.map(fn(socket) { #(Ssl, socket) })
}

/// Wait for the next connection. On `Ssl` this accepts only the TCP
/// connection and the socket carries no data until `handshake` has run which 
/// leaves room to hand the socket to another process first.
///
/// [`gen_tcp:accept/2`](https://www.erlang.org/doc/apps/kernel/gen_tcp.html#accept/2),
/// [`ssl:transport_accept/2`](https://www.erlang.org/doc/apps/ssl/ssl.html#transport_accept/2)
pub fn accept(
  transport: Transport,
  socket: ListenSocket,
  timeout: Timeout,
) -> Result(Socket, SocketError) {
  case transport {
    Tcp -> tcp_accept(socket, timeout)
    Ssl -> ssl_accept(socket, timeout)
  }
}

/// Run the TLS handshake on an accepted socket. Use the socket it returns
/// from then on as the one passed in is consumed. On `Tcp` the socket is
/// returned unchanged so this function is safe to call on every transport.
///
/// [`ssl:handshake/2`](https://www.erlang.org/doc/apps/ssl/ssl.html#handshake/2)
pub fn handshake(
  transport: Transport,
  socket: Socket,
  timeout: Timeout,
) -> Result(Socket, SocketError) {
  case transport {
    Tcp -> Ok(socket)
    Ssl -> ssl_handshake(socket, timeout)
  }
}

/// Make `pid` the owner of the socket. Only the current owner may do this.
/// Messages already delivered stay in the caller's mailbox so transfer
/// before taking the socket out of `Passive`.
///
/// [`gen_tcp:controlling_process/2`](https://www.erlang.org/doc/apps/kernel/gen_tcp.html#controlling_process/2),
/// [`ssl:controlling_process/2`](https://www.erlang.org/doc/apps/ssl/ssl.html#controlling_process/2)
pub fn controlling_process(
  transport: Transport,
  socket: Socket,
  pid: process.Pid,
) -> Result(Nil, SocketError) {
  case transport {
    Tcp -> tcp_controlling_process(socket, pid)
    Ssl -> ssl_controlling_process(socket, pid)
  }
}

/// Close a connection. Unsent data is flushed or dropped according to
/// `Linger`.
///
/// [`gen_tcp:close/1`](https://www.erlang.org/doc/apps/kernel/gen_tcp.html#close/1),
/// [`ssl:close/1`](https://www.erlang.org/doc/apps/ssl/ssl.html#close/1)
pub fn close(transport: Transport, socket: Socket) -> Result(Nil, SocketError) {
  case transport {
    Tcp -> tcp_close(socket)
    Ssl -> ssl_close(socket)
  }
}

/// Close a listen socket and release its port. Every `accept` blocked on it
/// returns `Closed`.
///
/// [`gen_tcp:close/1`](https://www.erlang.org/doc/apps/kernel/gen_tcp.html#close/1),
/// [`ssl:close/1`](https://www.erlang.org/doc/apps/ssl/ssl.html#close/1)
pub fn close_listener(
  transport: Transport,
  socket: ListenSocket,
) -> Result(Nil, SocketError) {
  case transport {
    Tcp -> tcp_close_listener(socket)
    Ssl -> ssl_close_listener(socket)
  }
}

/// Close one or both directions of a connection.
///
/// [`gen_tcp:shutdown/2`](https://www.erlang.org/doc/apps/kernel/gen_tcp.html#shutdown/2),
/// [`ssl:shutdown/2`](https://www.erlang.org/doc/apps/ssl/ssl.html#shutdown/2)
pub fn shutdown(
  transport: Transport,
  socket: Socket,
  mode: ShutdownMode,
) -> Result(Nil, SocketError) {
  case transport {
    Tcp -> tcp_shutdown(socket, mode)
    Ssl -> ssl_shutdown(socket, mode)
  }
}

/// Send data. Blocking until it is queued or until `SendTimeout` elapses.
///
/// [`gen_tcp:send/2`](https://www.erlang.org/doc/apps/kernel/gen_tcp.html#send/2),
/// [`ssl:send/2`](https://www.erlang.org/doc/apps/ssl/ssl.html#send/2)
pub fn send(
  transport: Transport,
  socket: Socket,
  data: bytes_tree.BytesTree,
) -> Result(Nil, SocketError) {
  case transport {
    Tcp -> tcp_send(socket, data)
    Ssl -> ssl_send(socket, data)
  }
}

/// Read from a `Passive` socket. Blocking until `bytes` bytes have arrived or
/// `timeout` runs out. `0` takes whatever is there.
///
/// [`gen_tcp:recv/3`](https://www.erlang.org/doc/apps/kernel/gen_tcp.html#recv/3),
/// [`ssl:recv/3`](https://www.erlang.org/doc/apps/ssl/ssl.html#recv/3)
pub fn receive(
  transport: Transport,
  socket: Socket,
  bytes: Int,
  timeout: Timeout,
) -> Result(BitArray, SocketError) {
  case transport {
    Tcp -> tcp_receive(socket, bytes, timeout)
    Ssl -> ssl_receive(socket, bytes, timeout)
  }
}

/// Change the options of an open connection. Listen only options are rejected 
/// with `Einval`.
///
/// [`inet:setopts/2`](https://www.erlang.org/doc/apps/kernel/inet.html#setopts/2),
/// [`ssl:setopts/2`](https://www.erlang.org/doc/apps/ssl/ssl.html#setopts/2)
pub fn set_options(
  transport: Transport,
  socket: Socket,
  options: List(TcpOption),
) -> Result(Nil, SocketError) {
  case transport {
    Tcp -> tcp_set_options(socket, options)
    Ssl -> ssl_set_options(socket, options)
  }
}

/// The local address and port of a connection.
///
/// [`inet:sockname/1`](https://www.erlang.org/doc/apps/kernel/inet.html#sockname/1),
/// [`ssl:sockname/1`](https://www.erlang.org/doc/apps/ssl/ssl.html#sockname/1)
pub fn sockname(
  transport: Transport,
  socket: Socket,
) -> Result(Endpoint, SocketError) {
  case transport {
    Tcp -> tcp_sockname(socket)
    Ssl -> ssl_sockname(socket)
  }
}

/// The address and port a listen socket is bound to. This is how to learn
/// the port after listening on `0`.
///
/// [`inet:sockname/1`](https://www.erlang.org/doc/apps/kernel/inet.html#sockname/1),
/// [`ssl:sockname/1`](https://www.erlang.org/doc/apps/ssl/ssl.html#sockname/1)
pub fn sockname_listener(
  transport: Transport,
  socket: ListenSocket,
) -> Result(Endpoint, SocketError) {
  case transport {
    Tcp -> tcp_sockname_listener(socket)
    Ssl -> ssl_sockname_listener(socket)
  }
}

/// The address and port of the peer.
///
/// [`inet:peername/1`](https://www.erlang.org/doc/apps/kernel/inet.html#peername/1),
/// [`ssl:peername/1`](https://www.erlang.org/doc/apps/ssl/ssl.html#peername/1)
pub fn peername(
  transport: Transport,
  socket: Socket,
) -> Result(Endpoint, SocketError) {
  case transport {
    Tcp -> tcp_peername(socket)
    Ssl -> ssl_peername(socket)
  }
}

/// The protocol agreed through ALPN. Returns `NotNegotiated` when none was 
/// agreed and `Unsupported` on `Tcp`.
///
/// [`ssl:negotiated_protocol/1`](https://www.erlang.org/doc/apps/ssl/ssl.html#negotiated_protocol/1)
pub fn negotiated_protocol(
  transport: Transport,
  socket: Socket,
) -> Result(BitArray, SocketError) {
  case transport {
    Tcp -> Error(Unsupported)
    Ssl -> ssl_negotiated_protocol(socket)
  }
}

/// The peer's DER certificate. Only present when the listener asked for one
/// with `Verify(VerifyPeer)`. Returns `NoPeerCertificate` otherwise and 
/// `Unsupported` on `Tcp`.
///
/// [`ssl:peercert/1`](https://www.erlang.org/doc/apps/ssl/ssl.html#peercert/1)
pub fn peer_certificate(
  transport: Transport,
  socket: Socket,
) -> Result(BitArray, SocketError) {
  case transport {
    Tcp -> Error(Unsupported)
    Ssl -> ssl_peer_certificate(socket)
  }
}

/// Every certificate in a PEM file. Entries that are not certificates are 
/// skipped.
///
/// [`public_key:pem_decode/1`](https://www.erlang.org/doc/apps/public_key/public_key.html#pem_decode/1)
@external(erlang, "tup_socket_ffi", "certificates_from_pem")
pub fn certificates_from_pem(pem: BitArray) -> List(BitArray)

/// The first private key in a PEM file. `password` is needed when the key is 
/// encrypted.
///
/// [`public_key:pem_decode/1`](https://www.erlang.org/doc/apps/public_key/public_key.html#pem_decode/1)
/// and [`public_key:pem_entry_decode/2`](https://www.erlang.org/doc/apps/public_key/public_key.html#pem_entry_decode/2)
@external(erlang, "tup_socket_ffi", "private_key_from_pem")
pub fn private_key_from_pem(
  pem: BitArray,
  password: option.Option(String),
) -> Result(PrivateKey, PemError)

/// The certificates the operating system trusts. Raises when the host has no 
/// trust store to read.
///
/// [`public_key:cacerts_get/0`](https://www.erlang.org/doc/apps/public_key/public_key.html#cacerts_get/0)
@external(erlang, "tup_socket_ffi", "system_certificate_authorities")
pub fn system_certificate_authorities() -> List(BitArray)

@external(erlang, "tup_socket_ffi", "tcp_listen")
fn tcp_listen(
  port: Int,
  options: List(TcpOption),
) -> Result(ListenSocket, SocketError)

@external(erlang, "tup_socket_ffi", "tcp_accept")
fn tcp_accept(
  socket: ListenSocket,
  timeout: Timeout,
) -> Result(Socket, SocketError)

@external(erlang, "tup_socket_ffi", "tcp_controlling_process")
fn tcp_controlling_process(
  socket: Socket,
  pid: process.Pid,
) -> Result(Nil, SocketError)

@external(erlang, "tup_socket_ffi", "tcp_close")
fn tcp_close(socket: Socket) -> Result(Nil, SocketError)

@external(erlang, "tup_socket_ffi", "tcp_close")
fn tcp_close_listener(socket: ListenSocket) -> Result(Nil, SocketError)

@external(erlang, "tup_socket_ffi", "tcp_shutdown")
fn tcp_shutdown(socket: Socket, mode: ShutdownMode) -> Result(Nil, SocketError)

@external(erlang, "tup_socket_ffi", "tcp_send")
fn tcp_send(
  socket: Socket,
  data: bytes_tree.BytesTree,
) -> Result(Nil, SocketError)

@external(erlang, "tup_socket_ffi", "tcp_receive")
fn tcp_receive(
  socket: Socket,
  bytes: Int,
  timeout: Timeout,
) -> Result(BitArray, SocketError)

@external(erlang, "tup_socket_ffi", "tcp_set_options")
fn tcp_set_options(
  socket: Socket,
  options: List(TcpOption),
) -> Result(Nil, SocketError)

@external(erlang, "tup_socket_ffi", "tcp_sockname")
fn tcp_sockname(socket: Socket) -> Result(Endpoint, SocketError)

@external(erlang, "tup_socket_ffi", "tcp_sockname")
fn tcp_sockname_listener(socket: ListenSocket) -> Result(Endpoint, SocketError)

@external(erlang, "tup_socket_ffi", "tcp_peername")
fn tcp_peername(socket: Socket) -> Result(Endpoint, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_listen")
fn ssl_listen(
  port: Int,
  options: List(TcpOption),
  tls_options: List(TlsOption),
) -> Result(ListenSocket, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_accept")
fn ssl_accept(
  socket: ListenSocket,
  timeout: Timeout,
) -> Result(Socket, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_handshake")
fn ssl_handshake(
  socket: Socket,
  timeout: Timeout,
) -> Result(Socket, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_controlling_process")
fn ssl_controlling_process(
  socket: Socket,
  pid: process.Pid,
) -> Result(Nil, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_close")
fn ssl_close(socket: Socket) -> Result(Nil, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_close")
fn ssl_close_listener(socket: ListenSocket) -> Result(Nil, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_shutdown")
fn ssl_shutdown(socket: Socket, mode: ShutdownMode) -> Result(Nil, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_send")
fn ssl_send(
  socket: Socket,
  data: bytes_tree.BytesTree,
) -> Result(Nil, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_receive")
fn ssl_receive(
  socket: Socket,
  bytes: Int,
  timeout: Timeout,
) -> Result(BitArray, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_set_options")
fn ssl_set_options(
  socket: Socket,
  options: List(TcpOption),
) -> Result(Nil, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_sockname")
fn ssl_sockname(socket: Socket) -> Result(Endpoint, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_sockname")
fn ssl_sockname_listener(socket: ListenSocket) -> Result(Endpoint, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_peername")
fn ssl_peername(socket: Socket) -> Result(Endpoint, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_negotiated_protocol")
fn ssl_negotiated_protocol(socket: Socket) -> Result(BitArray, SocketError)

@external(erlang, "tup_socket_ffi", "ssl_peer_certificate")
fn ssl_peer_certificate(socket: Socket) -> Result(BitArray, SocketError)

@external(erlang, "tup_socket_ffi", "message")
fn to_message(message: dynamic.Dynamic) -> Message
