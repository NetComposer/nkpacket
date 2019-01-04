%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(tcp_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-compile(nowarn_export_all).
-include_lib("eunit/include/eunit.hrl").
-include("nkpacket.hrl").

tcp_test_() ->
  	{setup, spawn, 
    	fun() -> 
    		ok = nkpacket_app:start(),
    		?debugMsg("Starting TCP test")
		end,
		fun(_) -> 
			ok
		end,
	    fun(_) ->
		    [
				fun() -> basic() end,
				fun() -> tls() end,
				fun() -> send() end
			]
		end
  	}.


basic() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	{ok, _, Tcp1} = nkpacket:start_listener(#nkconn{protocol=test_protocol, transp=tcp, ip={0,0,0,0}, port=0,
						   			     opts=M1#{class=>dom1, idle_timeout=>1000}}),
	{ok, _, Tcp2} = nkpacket:start_listener(#nkconn{protocol=test_protocol, transp=tcp, ip={0,0,0,0}, port=0,
						   			     opts=M2#{class=>dom2}}),
	timer:sleep(100),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_init} -> ok after 1000 -> error(?LINE) end,
	
	[Listen1] = nkpacket:get_class_ids(dom1),
	{ok, #nkport{transp=tcp, 
	       	class = dom1,
			local_ip={0,0,0,0}, local_port=ListenPort1, 
			listen_ip={0,0,0,0}, listen_port=ListenPort1,
			remote_ip=undefined, remote_port=undefined, pid=Tcp1
	}} = nkpacket:get_nkport(Listen1),

	[Listen2] = nkpacket:get_class_ids(dom2),
	{ok, #nkport{transp=tcp, 
	       	class = dom2,
			local_port=ListenPort2, pid=Tcp2, 
			listen_ip={0,0,0,0}, listen_port=ListenPort2,
			remote_ip=undefined, remote_port=undefined
	}} = nkpacket:get_nkport(Listen2),

	{ok, {_, _, _, ListenPort1}} = nkpacket:get_local(Tcp1),	
	{ok, {_, _, _, ListenPort2}} = nkpacket:get_local(Tcp2),	
	case ListenPort1 of
		1235 -> ok;
		_ -> lager:warning("Could not open port 1235")
	end,

	Uri = "<test://localhost:"++integer_to_list(ListenPort1)++";transport=tcp>",
	{ok, _} = nkpacket:send(Uri, msg1, M2#{idle_timeout=>5000, class=>dom2, debug=>true, base_nkport=>true}),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, msg1}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {encode, msg1}} -> ok after 1000 -> error(?LINE) end,

	[{_, Conn2}] = nkpacket_connection:get_all_class(dom2),
	{ok, #nkport{
	       	class = dom2,
			transp=tcp, pid=Conn2,
			local_ip={127,0,0,1}, local_port=LPort2,
			remote_ip={127,0,0,1}, remote_port=ListenPort1,
			listen_ip={0,0,0,0}, listen_port=ListenPort2
	}} = nkpacket:get_nkport(Conn2),

	[{_, Conn1}] = nkpacket_connection:get_all_class(dom1),
	{ok, #nkport{
       		class = dom1,
			transp=tcp, pid=Conn1,
			local_ip={127,0,0,1}, local_port=_LPort1,
			remote_ip={127,0,0,1}, remote_port=LPort2,
			listen_ip={0,0,0,0}, listen_port=ListenPort1
	}} = nkpacket:get_nkport(Conn1),

	Time1 = nkpacket_connection:get_timeout(Conn1),
	true = Time1 > 0 andalso Time1 =< 1000,
	Time2 = nkpacket_connection:get_timeout(Conn2),
	true = Time2 > 4000 andalso Time2 =< 5000,

	%% Connection 2 will stop after 1 sec, and will tear down conn1
	receive {Ref2, conn_stop} -> ok after 2000 -> error(?LINE) end,
	receive {Ref1, conn_stop} -> ok after 2000 -> error(?LINE) end,
	timer:sleep(50),
	[Listen2] = nkpacket:get_class_ids(dom2),
	[Listen1] = nkpacket:get_class_ids(dom1),
	test_util:ensure([Ref1, Ref2]),
	ok.



tls() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	ok = nkpacket:register_protocol(test, test_protocol),
	{ok, _, Tls1} = nkpacket:start_listener(#nkconn{protocol=test_protocol, transp=tls, ip={0,0,0,0}, port=0,
						   			     opts=M1#{class=>dom1, tcp_listeners=>1}}),
	{ok, {_, _, _, ListenPort1}} = nkpacket:get_local(Tls1),
	case ListenPort1 of
		1236 -> ok;
		_ -> lager:warning("Could not open port 1236")
	end,
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	timer:sleep(1000),

	% Sending a request without a matching started listener

	Uri = "<test://localhost:"++integer_to_list(ListenPort1)++";transport=tls>",
	{ok, _} = nkpacket:send(Uri, msg1, M2#{idle_timeout=>1000, class=>dom2, base_nkport=>false}),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, msg1}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {encode, msg1}} -> ok after 1000 -> error(?LINE) end,

	[Listen1] = nkpacket:get_class_ids(dom1),
	{ok, #nkport{
	       	class = dom1,
			transp = tls, 
			local_ip = {0,0,0,0}, local_port = ListenPort,
		    remote_ip = undefined, remote_port = undefined, 
		    listen_ip={0,0,0,0}, listen_port = ListenPort,
		    protocol = test_protocol, pid = Tls1,
		    socket = {sslsocket, _, _}
	}} = nkpacket:get_nkport(Listen1),

	[{_, Conn1}] = nkpacket_connection:get_all_class(dom1),
	{ok, #nkport{
       	class = dom1,
		transp = tls, 
		local_ip = {127,0,0,1}, local_port = _Dom1Port,
	    remote_ip = {127,0,0,1}, remote_port = Dom2Port, 
	    listen_ip = {0,0,0,0}, listen_port = ListenPort,
	    protocol = test_protocol, pid = _Dom1Pid,
	    socket = {sslsocket, _, _}
	}} = nkpacket:get_nkport(Conn1),

	[{_, Conn2}] = nkpacket_connection:get_all_class(dom2),
	{ok, #nkport{
	       	class = dom2,
			transp = tls, 
			local_ip = {127,0,0,1}, local_port = Dom2Port,
		    remote_ip = {127,0,0,1}, remote_port = ListenPort, 
		    listen_ip = undefined, listen_port = undefined,
		    protocol = test_protocol, pid = _Dom2Pid,
		    socket = {sslsocket, _, _}
	}} = nkpacket:get_nkport(Conn2),

	% If we send another message, the same connection is reused
	{ok, _} = nkpacket:send(Uri, msg2, #{class=>dom2}),
	receive {Ref1, {parse, msg2}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {encode, msg2}} -> ok after 1000 -> error(?LINE) end,
	[{_, Conn1}] = nkpacket_connection:get_all_class(dom1),

	% Wait for the timeout
	timer:sleep(1500),
	[{IdTls1, _, Tls1}] = nkpacket:get_all(),
	[Tls1] = nkpacket:get_id_pids(IdTls1),
	ok = nkpacket:stop_listeners(Tls1),
	receive {Ref1, conn_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, listen_stop} -> ok after 1000 -> error(?LINE) end,
	test_util:ensure([Ref1, Ref2]).


send() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	ok = nkpacket:register_protocol(test, test_protocol),
	{ok, _, Udp1} = nkpacket:start_listener(#nkconn{protocol=test_protocol, transp=udp, ip={0,0,0,0}, port=0,
						   			     opts=M1#{class=>dom1, udp_starts_tcp=>true}}),
	% Since '1234' is not available, a random one is used
	% (Oops, in linux it allows to open it again, the old do not receive more packets!)
	Port2 = test_util:get_port(udp),
	{ok, _, Udp2} = nkpacket:start_listener(#nkconn{protocol=test_protocol, transp=udp, ip={0,0,0,0}, port=Port2,
						   			     opts=M2#{class=>dom2, idle_timeout=>1000, udp_starts_tcp=>true, tcp_packet=>4}}),
	timer:sleep(100),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_init} -> ok after 1000 -> error(?LINE) end,
%%	{ok, {_, _, _, Listen1}} = nkpacket:get_local(Udp1),
	{ok, {_, udp, _, Listen2}} = nkpacket:get_local(Udp2),


	% Invalid sends
	lager:warning("Next warning about a invalid send specification is expected"),
	{error, {invalid_uri, wrong}} = nkpacket:send(wrong, msg1),
	Base0 = #nkconn{protocol=test_protocol, transp=tcp, ip={0,0,0,0}, port=Listen2},
	Base1 = Base0#nkconn{ip={127,0,0,1}},
	{error, no_transports} = nkpacket:send({current, Base0}, msg1),
	{error, no_listening_transport} = nkpacket:send(Base1#nkconn{transp=sctp}, msg1, #{base_nkport=>true}),
	Msg = crypto:strong_rand_bytes(5000),
	% No class

%%	{ok, _, _Udp3} = nkpacket:start_listener(#nkconn{protocol=test_protocol, transp=udp, opts=#{class=>dom3}}),
	{error, no_listening_transport} = nkpacket:send(Base1#nkconn{transp=udp, opts=M1}, {msg1, Msg}),

    {error, udp_too_large} = nkpacket:send({connect, Base1#nkconn{transp=udp, opts=M1#{class=>dom1, udp_max_size=>1500}}}, {msg1, Msg}, #{base_nkport=>true}),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {encode, {msg1, Msg}}} -> ok after 1000 -> error(?LINE) end,

	receive {Ref1, conn_stop} -> ok after 1000 -> error(?LINE) end,


	% This is going to use tcp
	{ok, Conn1Pid} = nkpacket:send(Base1#nkconn{transp=udp, opts=M1#{class=>dom1, udp_to_tcp=>true, tcp_packet=>4,
																	 udp_max_size=>1500, base_nkport=>true}},
								{msg1, Msg}),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {encode, {msg1, Msg}}} -> ok after 1000 -> error(?LINE) end, % Udp
	receive {Ref1, {encode, {msg1, Msg}}} -> ok after 1000 -> error(?LINE) end, % Tcp
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, {msg1, Msg}}} -> ok after 1000 -> error(?LINE) end,
	{ok, #nkport{transp=tcp}} = nkpacket:get_nkport(Conn1Pid),

	% Conn1A = Conn1#nkport{meta=#{}},
	{ok, Conn1Pid} = nkpacket:send(Base1#nkconn{opts=M1#{class=>dom1}}, msg2),
	receive {Ref1, {encode, msg2}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, msg2}} -> ok after 1000 -> error(?LINE) end,

%%	{ok, Conn1Pid} = nkpacket:send(Conn1Pid, msg3, M1#{class=>dom1}),
	{ok, Conn1Pid} = nkpacket:send(Conn1Pid, msg3),
	receive {Ref1, {encode, msg3}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, msg3}} -> ok after 1000 -> error(?LINE) end,

	{ok, Conn1Pid} = nkpacket:send({current, Base1#nkconn{opts=M1#{class=>dom1}}}, msg4),
	receive {Ref1, {encode, msg4}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, msg4}} -> ok after 1000 -> error(?LINE) end,

	% Force a new connection
	{ok, Conn2Pid} = nkpacket:send({connect, Base1#nkconn{opts=M1#{tcp_packet=>4, class=>dom1}}}, msg5),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {encode, msg5}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, msg5}} -> ok after 1000 -> error(?LINE) end,
	true = Conn1Pid /= Conn2Pid,

	ok = nkpacket:stop_listeners(Udp1),
	ok = nkpacket:stop_listeners(Udp2),
	receive {Ref1, conn_stop} -> ok after 1000 -> error(?LINE) end,  % First UDP
	receive {Ref1, conn_stop} -> ok after 1000 -> error(?LINE) end,  % Second TCP
	receive {Ref2, conn_stop} -> ok after 1000 -> error(?LINE) end,  % Second TCP-R
	receive {Ref1, conn_stop} -> ok after 1000 -> error(?LINE) end,  % Third TCP
	receive {Ref2, conn_stop} -> ok after 1000 -> error(?LINE) end,  % Third TCP-R

	receive {Ref1, listen_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, listen_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_stop} -> ok after 1000 -> error(?LINE) end,

    test_util:ensure([Ref1, Ref2]).





