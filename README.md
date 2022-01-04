# NkPACKET: Generic Erlang transport layer

NkPACKET is a generic transport layer for Erlang. 

It can be used to develop high perfomance, low latency network servers, clients and proxies. 

### Features:
* Support for UDP, TCP/TLS, SCTP and WS/WSS.
* STUN server.
* Connection-oriented (even for UDP).
* DNS engine with full support for NAPTR and SRV location, including priority and weights.
* URL-mapping of servers and connections.
* Wrap over [Cowboy](https://github.com/ninenines/cowboy) to write domain-specific, high perfomance http servers.

In order to write a server or client using NkPACKET, you must define a _protocol_, an Erlang module implementing some of the callback functions defined in [nkpacket_protocol.erl](src/nkpacket_protocol.erl). All callbacks are optional. In your protocol callback module, you can specify available transports, default ports and callback functions for your protocol.

Listeners and connections can belong to a _group_, and can then be managed together. When sending packets, if a previous connection exists belonging to the same group, it will be used instead of starting a new one.


## Registering the protocol

If you want to use a _scheme_ associated with your protocol (like in  `my_scheme://0.0.0.0:5315;transport=wss`) you must _register_ your protocol with NkPACKET calling `nkpacket:register_protocol/2,3`. Different goups can have different protocol implementations for the same scheme:

```erlang
nkpacket:register_protocol(my_scheme, my_protocol)
```
In this example, the module `my_protocol.erl` must exist.


## Writing a server

After defining your callback protocol module, you can start your server calling [nkpacket:start_listener/2](src/nkpacket.erl). You must provide a `nkpacket:user_connection()` network specification, for example:

```erlang
nkpacket:start_listener("my_scheme://0.0.0.0:5315;transport=wss", 
						#{tcp_listeners=>100, idle_timeout=>5000})
```
or
```erlang
nkpacket:start_listener({my_protocol, wss, {0,0,0,0}, 5315}, 
						#{group=>my_group, tcp_listeners=>100, idle_timeout=>5000})
```
or even
```erlang
nkpacket:start_listener(my_domain, "my_scheme://0.0.0.0:5315;transport=wss;tcp_listeners=100;idle_timeout=5000")
```

There are many available options, like setting connection timeouts, start STUN servers fot UDP, TLS parameters, maximum number of connections, etc. (See `nkpacket:listener_opts()`). The following options are allowed in urls: idle_timeout, connect_timeout, sctp_out_streams, sctp_in_streams, no_dns_cache, tcp_listeners, host, path, ws_proto, tls_certfile, tls_keyfile, tls_cacertfile, tls_password, tls_verify, tls_depth.

NkPACKET will then start the indicated transport. When a new connection arrives, a new _connection process_ will be started, and the `conn_init/0` callback function in your protocol callback function will be called.
Incoming data will be _parsed_ and sent to your protocol module.

You can use the option `user` to pass specific metadata to the callback `init` function. If you use the url format, you can use header values, and they will generate an erlang `list()`. The following are equivalent:

```erlang
nkpacket:start_listener(my_domain, "my_scheme://0.0.0.0:5315;transport=wss", 
						#{user=>[{<<"key1">>, <<"value1">>}, <<"key2">>]})
```
and
```erlang
nkpacket:start_listener(my_domain, "my_scheme://0.0.0.0:5315;transport=wss?key1=value1&key2", 
						#{})
```

You can send packets over the started connection calling `nkpacket:send/2,3`. Packets will be _encoded_ calling the corresponding function in the callback module.

After a configurable timeout, if no packets are sent or received, the connection is dropped. 
Incoming UDP packets will also (by default) generate a new _connection_, associated to that remote _ip_ and _port_. New packets to/from the same ip and port will be sent/received through the same _connection process_. You can disable this behaviour.


## Writing a client

After defining the callback protocol module (if it is not already defined) you can send any packet to a remote server calling [nkpacket:send/2,3](src/nkpacket.erl), for example:

```erlang
nkpacket:send("my_scheme://my_host:5315;transport=wss", my_msg)
```
(to use urls like in this example you need to register your protocol previously).


After resolving `my_host` using the local DNS engine (using NAPTR and SRV if available), your message will be _encoded_ (using the corresponding callback function on your protocol callback module), and, if a connection is already started for the same _group_, _transport_, _ip_ and _port_, the packet will be sent through it. If none is available, or no group was specified, a new one will be automatically started. 

NkPACKET offers a sofisticated mechanism to specify destinations, with multiple fallback routes, forcing new or old connections, trying tcp after udp failure, etc. (See `nkpacket:send_opts()`). You can also force a new connection to start without sending any packet yet, calling `nkpacket:connect/2`.


## Writing a web server

NkPACKET includes two _pseudo_transports_: `http` and `https`.

NkPACKET registers on start the included protocol [nkpacket_protocol_http](src/nkpacket_protocol_http.erl), associating it with the schema `http` (only for _pseudo-transport http_) and the schema `https`  (for _pseudo-transport https_). You can then start a server listening on this protocol and transport.

NkPACKET allows several different domains to share the same web server. You must use the options `host` and/or `path` to filter and select the right domain to send the request to (see `nkpacket:listener_opts()`). You must also use `cowboy_dispatch` to process the request as an standard _Cowboy_ request.

For more specific behaviours, use `cowboy_opts` instead of `cowbow_dispatch`, including any supported Cowboy middlewares and environment.

You can of course register your own protocol using tranports `http` and `https` (using schemas `http` and `https` or not), implementing the callback function `http_init/3` (see [nkpacket_protocol_http](src/nkpacket_protocol_http.erl) for an example).


## Application configurarion

There are several aspects of NkPACKET that can be configured globally, using standard Erlang application environment:

Option|Type|Default|Comment
---|---|---|---
max_connections|`integer()`|1024|Maximum globally number of connections.
dns_cache_ttl|`integer()`|30000|Time to cache DNS queries. 0 to disable cache (msecs).
udp_timeout|`integer()`|30000|(msecs)
tcp_timeout|`integer()`|180000|(msecs)
sctp_timeout|`integer()`|180000|(msecs)
ws_timeout|`integer()`|180000|(msecs)
http_timeout|`integer()`|180000|(msecs)
connect_timeout|`integer()`|30000|(msecs)
sctp_out_streams|`integer()`|10|Default SCTP out streams
sctp_in_streams|`integer()`|10|Default SCTP in streams
tcp_listeners|`integer()`|10|Default number of TCP listeners
tos|`integer()`|0|Default value for Type of Service
main_ip|`inet:ip4_address()`|auto|Main IPv4 of the host
main_ip6|`inet:ip6_address()`|auto|Main IPv6 of the host
ext_ip|`inet:ip4_address()`|auto|Public Ipv4 of the host
tls_certfile|`string()`|-|Custom certificate file
tls_keyfile|`string()`|-|Custom key file
tls_cacertfile|`string()`|-|Custom CA certificate file
tls_password|`string()`|-|Password fort the certificate
tls_verify|`boolean()`|false|If we must check certificate
tls_depth|`integer()`|0|TLS check depth

main_ip, main_ip6, if auto, are guessed from the main network cards.
ext_ip, if auto, is obtained using STUN.
None of them are used by nkpacket itself, but are available for client projects.


NkPACKET uses [lager](https://github.com/basho/lager) for log management. 

NkPACKET needs Erlang >= 17 and it is tested on Linux and OSX.




# Contributing

Please contribute with code, bug fixes, documentation fixes, testing or any other form. Use GitHub Issues and Pull Requests, forking this repository. Please make sure all tests pass and Dialyzer is happy after your patch.

