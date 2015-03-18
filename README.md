# NkPACKET: Generic Erlang transport layer

NkPACKET is a generic UDP, TCP/TLS, SCTP and WS/WSS transport layer for Erlang. It can be used to develop high perfomance, low lattency network servers, clients and proxies. 

It order to use NkPACKET, you must supply a _protocol_, as a callback module based on [nkpacket_protocol.erl](src/nkpacket_protocol.erl).

NkPACKET also includes a buit-in implementation of a flexible http server, using Cowboy as backend.

More documentation will be available soon.

