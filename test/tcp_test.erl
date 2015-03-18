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
-include_lib("eunit/include/eunit.hrl").
-include("nkpacket.hrl").

tcp_test_() ->
  	{setup, spawn, 
    	fun() -> 
    		nkpacket_app:start(),
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
	{ok, Tcp1} = nkpacket:start_listener(dom1, 
										 {test_protocol, tcp, {0,0,0,0}, 0},
						   			     M1#{tcp_listeners=>1}),
	{ok, Tcp2} = nkpacket:start_listener(dom2, 
										 {test_protocol, tcp, {0,0,0,0}, 0},
						   			     M2#{idle_timeout=>1000}),
	timer:sleep(100),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_init} -> ok after 1000 -> error(?LINE) end,
	[Listen1] = nkpacket:get_all(dom1),
	#nkport{domain=dom1, transp=tcp, 
			local_ip={0,0,0,0}, local_port=ListenPort1, 
			listen_ip={0,0,0,0}, listen_port=ListenPort1,
			remote_ip=undefined, remote_port=undefined,
			pid=Tcp1, meta=#{idle_timeout:=180000, test:=_}
	} = Listen1,
	[Listen2] = nkpacket:get_all(dom2),
	#nkport{domain=dom2, transp=tcp, 
			local_port=ListenPort2, pid=Tcp2, 
			listen_ip={0,0,0,0}, listen_port=ListenPort2,
			remote_ip=undefined, remote_port=undefined,
			meta=#{idle_timeout:=1000, test:=_}
	} = Listen2,
	{ok, ListenPort1} = nkpacket:get_port(Tcp1),	
	{ok, ListenPort2} = nkpacket:get_port(Tcp2),	

	Uri = "<test://localhost:"++integer_to_list(ListenPort1)++";transport=tcp>",
	{ok, _} = nkpacket:send(dom2, Uri, msg1),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, msg1}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {unparse, msg1}} -> ok after 1000 -> error(?LINE) end,

	[
		Listen2,
		#nkport{domain=dom2, transp=tcp,
				local_ip={127,0,0,1}, local_port=LPort2,
				remote_ip={127,0,0,1}, remote_port=ListenPort1,
				listen_ip={0,0,0,0}, listen_port=ListenPort2,
				meta = #{idle_timeout:=1000, test:=_}}
	] = 
		lists:sort(nkpacket:get_all(dom2)),

	[
		Listen1,
		#nkport{domain=dom1, transp=tcp,
				local_ip={127,0,0,1}, local_port=_LPort1,
				remote_ip={127,0,0,1}, remote_port=LPort2,
				listen_ip={0,0,0,0}, listen_port=ListenPort1,
				meta = #{idle_timeout:=180000, test:=_}}
	] = 
		lists:sort(nkpacket:get_all(dom1)),

	%% Connection 2 will stop after 1 sec, and will tear down conn1
	receive {Ref2, conn_stop} -> ok after 2000 -> error(?LINE) end,
	receive {Ref1, conn_stop} -> ok after 2000 -> error(?LINE) end,
	timer:sleep(50),
	[Listen2] = nkpacket:get_all(dom2),
	[Listen1] = nkpacket:get_all(dom1),
	test_util:ensure([Ref1, Ref2]).



tls() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	ok = nkpacket_config:register_protocol(test, test_protocol),
	{ok, Tls1} = nkpacket:start_listener(dom1, {test_protocol, tls, {0,0,0,0}, 0},
						   			     M1#{tcp_listeners=>1, idle_timeout=>5000}),
	{ok, ListenPort1} = nkpacket:get_port(Tls1),	
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,

	% Sending a request wihout a matching started listener
	Uri = "<test://localhost:"++integer_to_list(ListenPort1)++";transport=tls>",
	{ok, _} = nkpacket:send(dom2, Uri, msg1, M2#{idle_timeout=>1000}),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, msg1}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {unparse, msg1}} -> ok after 1000 -> error(?LINE) end,

	[
		#nkport{domain = dom1, transp = tls, 
				local_ip = {0,0,0,0}, local_port = ListenPort,
			    remote_ip = undefined, remote_port = undefined, 
			    listen_ip={0,0,0,0}, listen_port = ListenPort,
			    protocol = test_protocol, pid = Tls1,
			    socket = {sslsocket, _, _}, 
			    meta=#{idle_timeout:=5000, test:=_}
	    },
		#nkport{domain = dom1, transp = tls, 
				local_ip = {127,0,0,1}, local_port = _Dom1Port,
			    remote_ip = {127,0,0,1}, remote_port = Dom2Port, 
			    listen_ip = {0,0,0,0}, listen_port = ListenPort,
			    protocol = test_protocol, pid = _Dom1Pid,
			    socket = {sslsocket, _, _}, 
			    meta=#{idle_timeout:=5000, test:=_}
	    },
		#nkport{domain = dom2, transp = tls, 
				local_ip = {127,0,0,1}, local_port = Dom2Port,
			    remote_ip = {127,0,0,1}, remote_port = ListenPort, 
			    listen_ip = undefined, listen_port = undefined,
			    protocol = test_protocol, pid = _Dom2Pid,
			    socket = {sslsocket, _, _}, 
			    meta=#{idle_timeout:=1000, test:=_}
	    }
	] = 
		Conns1 = lists:sort(nkpacket:get_all()),

	% If we send another message, the same connection is reused
	{ok, _} = nkpacket:send(dom2, Uri, msg2),
	receive {Ref1, {parse, msg2}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {unparse, msg2}} -> ok after 1000 -> error(?LINE) end,
	Conns1 = lists:sort(nkpacket:get_all()),

	% Wait for the timeout
	timer:sleep(1500),
	[#nkport{pid=Tls1}] = nkpacket:get_all(),
	ok = nkpacket:stop_listener(Tls1),
	receive {Ref1, conn_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, listen_stop} -> ok after 1000 -> error(?LINE) end,
	test_util:ensure([Ref1, Ref2]).


send() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	ok = nkpacket_config:register_protocol(test, test_protocol),
	{ok, Udp1} = nkpacket:start_listener(dom1, 
										 {test_protocol, udp, {0,0,0,0}, 0},
						   			     M1#{tcp_listeners=>1, udp_starts_tcp=>true,
						   			         tcp_packet=>4}),
	{ok, Udp2} = nkpacket:start_listener(dom2, 
										 {test_protocol, udp, {0,0,0,0}, 0},
						   			     M2#{idle_timeout=>1000, udp_starts_tcp=>true, 
						   			         tcp_packet=>4}),
	timer:sleep(100),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_init} -> ok after 1000 -> error(?LINE) end,
	{ok, _Listen1} = nkpacket:get_port(Udp1),	
	{ok, Listen2} = nkpacket:get_port(Udp2),	

	% Invalid sends
	lager:warning("Next warning about a invalid send specification is expected"),
	{error, {invalid_send_specification, wrong}} = nkpacket:send(dom1, wrong, msg1),
	{error, no_transports} = 
		nkpacket:send(dom1, {current, {test_protocol, tcp, {0,0,0,0}, Listen2}}, msg1),
	{error, no_listening_transport} = 
		nkpacket:send(dom1, {test_protocol, sctp, {127,0,0,1}, Listen2}, msg1),
	Msg = crypto:rand_bytes(5000),
	{error, udp_too_large} = 
		nkpacket:send(dom1, {test_protocol, udp, {127,0,0,1}, Listen2},{msg1, Msg}),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {unparse, {msg1, Msg}}} -> ok after 1000 -> error(?LINE) end,

		% This is going to use tcp
	{ok, Conn1} = nkpacket:send(dom1, {test_protocol, udp, {127,0,0,1}, Listen2},
								{msg1, Msg}, #{udp_to_tcp=>true}),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {unparse, {msg1, Msg}}} -> ok after 1000 -> error(?LINE) end, % Udp
	receive {Ref1, {unparse, {msg1, Msg}}} -> ok after 1000 -> error(?LINE) end, % Tcp
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, {msg1, Msg}}} -> ok after 1000 -> error(?LINE) end,
	#nkport{transp=tcp} = Conn1,

	{ok, Conn1} = nkpacket:send(dom1, {test_protocol, tcp, {127,0,0,1}, Listen2},
				 				msg2),
	receive {Ref1, {unparse, msg2}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, msg2}} -> ok after 1000 -> error(?LINE) end,

	{ok, Conn1} = nkpacket:send(dom1, Conn1, msg3),
	receive {Ref1, {unparse, msg3}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, msg3}} -> ok after 1000 -> error(?LINE) end,

	{ok, Conn1} = nkpacket:send(dom1, {current, {test_protocol, tcp, {127,0,0,1}, Listen2}},
								msg4),
	receive {Ref1, {unparse, msg4}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, msg4}} -> ok after 1000 -> error(?LINE) end,

	% Force a new connection
	{ok, Conn2} = nkpacket:send(dom1, {test_protocol, tcp, {127,0,0,1}, Listen2}, 
								msg5, #{force_new=>true}),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {unparse, msg5}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, msg5}} -> ok after 1000 -> error(?LINE) end,
	true = Conn1#nkport.pid /= Conn2#nkport.pid,

	ok = nkpacket:stop_listener(Udp1),
	ok = nkpacket:stop_listener(Udp2),
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





















	
