# NkPACKET: Generic Erlang transport layer

NkPACKET is a generic  transport layer for Erlang. 

It can be used to develop high perfomance, low lattency network servers, clients and proxies. 

### Features:
* Support for UDP, TCP/TLS, SCTP and WS/WSS.
* STUN server.
* Connection-oriented (even for UDP).
* DNS engine with full support for NAPTR and SRV location, including priority and weights.
* URL-mapping of servers and connections.
* Wrap over [Cowboy](https://github.com/ninenines/cowboy) to write domain-specific, high perfomance http servers.

In order to write a server or client using NkPACKET, you must define a _protocol_, an Erlang module implementing some of the callback functions defined in [nkpacket_protocol.erl](src/nkpacket_protocol.erl). All callbacks are optional. In your protocol callback module, you can specify available transports, default ports and callback functions for your protocol.

Each NkPACKET listening server or connection is associated with a _domain_. A domain can be any Erlang term.

## Registering the protocol

If you want to use a _scheme_ associated with your protocol (like in  `my_scheme://0.0.0.0:5315;transport=wss`) you must _register_ your protocol with NkPACKET calling `nkpacket_config:register_protocol/2,3` for a specfic domain or all domains. Different domains can have different protocol implementations fot the same scheme:

```erlang
nkpacket_config:register_protocol(my_scheme, my_protocol)
```
In this example, the module my_protocol.erl must exist.


## Writing a server

After defining your callback protocol module, you can start your server calling [nkpacket:start_listener/3](src/nkpacket.erl). You must associate your server to a _domain_ (any erlang term), and provide a `nkpacket:user_connection()` network specification, like:

```erlang
nkpacket:start_listener(my_domain, "my_scheme://0.0.0.0:5315;transport=wss", 
						#{tcp_listeners=>100, idle_timeout=>5000})
```
or
```erlang
nkpacket:start_listener(mydomain, {my_protocol, wss, {0,0,0,0}, 5315}, 
						#{tcp_listeners=>100, idle_timeout=>5000})
```
or even
```erlang
nkpacket:start_listener(my_domain, "my_scheme://0.0.0.0:5315;transport=wss;tcp_listeners=100;idle_timeout=5000")
```

There are may available options like using your own supervisor, set connection timeouts, start STUN servers fot UDP, TLS parameters, maximum number of connections, etc. (See `nkpacket:listener_opts()`) 

NkPACKET will then start the indicated transport. When a new connection arrives, a new _connection process_ will be started, and the `conn_init/0` callback function in your protocol callback function will be called.
Incoming data will be _parsed_ and sent to your protocol module.

You can use the option `user` to pass specific metadata to the callback init function. If you use the url format, you can use header values, and they will generate an erlang list(). The following are equivalent:

```erlang
nkpacket:start_listener(my_domain, "my_scheme://0.0.0.0:5315;transport=wss", 
						#{user=>[{<<"key1">>, <<"value1">>}, <<"key2">>]})
```
and
```erlang
nkpacket:start_listener(my_domain, "my_scheme://0.0.0.0:5315;transport=wss?key1=value1&key2", 
						#{})
```

You can also send new packets over the started connection calling `nkpacket:send/3,4`. Packets will be _unparsed_ calling the corresponding function in the callback module.

After a configurable timeout, if no packets are sent or received, the connection is dropped. 

Incoming UDP packets will by default generate a new _connection_, associated to that remote _ip_ and _port_. New packets to/from the same IP and Port will be sent/received through the same _connection process_.


## Writing a client

After defining the callback protocol module (if it is not already defined) you can send any packet to a remote server calling [nkpacket:send/3,4](src/nkpacket.erl), for example:

```erlang
nkpacket:send(my_domain, "my_scheme://my_host:5315;transport=wss", my_msg)
```
(to use urls like in this example you need to register your protocol previously).


After resolving `my_host` using the local DNS engine (using NAPTR and SRV if available), your message will be _unparsed_ (using the corresponding callback function on your protocol callback module), and, if a connection is already started for the same _domain_, _transport_, _ip_ and _port_, the packet will be sent through it. If none is available, a new one will be automatically started. 

NkPACKET offers a sofisticated mechanism to specify destinations, with multiple fallback routes, forcing new or old connections, trying tcp after udp failure, etc. (See `nkpacket:send_opts()`). You can also force a new connection to start without sending any packet yet calling `nkpacket:connect/3`.


## Writing a web server

NkPACKET includes two _pseudo_transports_: `http` and `https`.

NkPACKET preconfigures the included protocol [nkpacket_protocol_http](src/nkpacket_protocol_http.erl), associating it with the schema 'http' (only for _pseudo-transport http_ and the schema 'https' for _pseudo-transport https_). You can then start a server listening on this protocol and transport.

NkPACKET allows several different domains to share the same web server. You must use the options `host` and/or `path` to filter and select the right domain to send the request to (see `nkpacket:listener_opts()`). You must also use `cowboy_dispatch` to process the request as an usual Cowboy request.

For more specific behaviours, use `cowboy_opts` instead of `cowbow_dispath`, including any supported Cowboy middlewares and environment.

You can also use your own protocol using tranports `http` and `https`, and implementing the callback function `http_init/3` (see [nkpacket_protocol_http](src/nkpacket_protocol_http.erl) for an example).


## Application configurarion

There are several aspects of NkPACKET that can be configured globally, using standard Erlang application environment:

Option|Type|Default|Comment
---|---|---|---
global_max_connections|`integer()`|1024|Maximum globally number of connections.
dns_cache_ttl|`integer()`|30000|Time to cache DNS queries. 0 to disable cache (msecs).
udp_timeout|`integer()`|30000|(msecs)
tcp_timeout|`integer()`|180000|(msecs)
sctp_timeout|`integer()`|180000|(msecs)
ws_timeout|`integer()`|180000|(msecs)
http_timeout|`integer()`|180000|(msecs)
connect_timeout|`integer()`|30000|(msecs)
max_connections|`integer()`|1024|Per domain.

Except for `global_max_connections`, all of these options can be modified for any specific domain individually, calling `nkpacket_config:load_domain/2`.

NkPACKET uses [lager](https://github.com/basho/lager) for log management. 

NkPACKET needs Erlang >= 17.


