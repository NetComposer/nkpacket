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

-module(ws_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").
-include("../../nklib/include/nklib.hrl").
-include("nkpacket.hrl").

ws_test_() ->
  	{setup, spawn, 
    	fun() -> 
    		nkpacket_app:start(),
    		?debugMsg("Starting WS test")
		end,
		fun(_) -> 
			ok
		end,
	    fun(_) ->
		    [
				fun() -> basic() end,
				fun() -> wss() end,
				fun() -> multi() end,
				fun() -> ping() end,
				fun() -> large() end
			]
		end
  	}.


basic() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	% A "catch all" server (all hosts, all paths)
	% Should use default port for ws: 1238
	Url0 = "<test://all;transport=ws;idle_timeout=1000?header1=value1&h2>",
	{ok, Ws1} = nkpacket:start_listener(dom1, Url0, M1),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	[
		#nkport{
			domain=dom1, transp=ws, 
			local_ip={0,0,0,0}, local_port=1238,
			meta=#{idle_timeout:=1000,
				   uri_headers:=[{<<"header1">>,<<"value1">>},<<"h2">>]}
		} = Listen1
	] = nkpacket:get_all(dom1),
	
	Url1 = "<test://localhost;transport=ws;connect_timeout=200;idle_timeout=500>",
	{ok, Conn1} = nkpacket:send(dom2, Url1, msg1, M2),
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {unparse, msg1}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, msg1}}} -> ok after 1000 -> error(?LINE) end,

	#nkport{
		domain=dom2, transp=ws, 
		local_ip={127,0,0,1}, local_port=Port1,
        remote_ip={127,0,0,1}, remote_port=1238,
        listen_ip=undefined, listen_port=undefined,
        protocol=test_protocol, 
        meta=#{
        	connect_timeout := 200,
            idle_timeout := 500,
            ws_exts := #{}
        }
	} = Conn1,

	% We send some more data. The same connection is used.
	{ok, Conn1} = nkpacket:send(dom2, Conn1, msg1b),
	receive {Ref2, {unparse, msg1b}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, msg1b}}} -> ok after 1000 -> error(?LINE) end,

	% And in the opposite direction
	[Listen1, Conn1R] = nkpacket:get_all(dom1),
	{ok, Conn1R} = nkpacket:send(dom1, Conn1R, msg1c),
	receive {Ref1, {unparse, msg1c}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, {binary, msg1c}}} -> ok after 1000 -> error(?LINE) end,

	% Lets send directly to the connection
	ok = nkpacket_connection:send(Conn1, erlang:term_to_binary(msg1d)),
	receive {Ref1, {parse, {binary, msg1d}}} -> ok after 1000 -> error(?LINE) end,
	ok = nkpacket_connection:send(Conn1R, {text, <<"my text">>}),
	receive {Ref2, {parse, {text, <<"my text">>}}} -> ok after 1000 -> error(?LINE) end,

	% Since we use a different URL, it opens a new connection
	Url2 = "<test://127.0.0.1:1238/a/b;transport=ws;connect_timeout=200>",
	{ok, Conn2} = nkpacket:send(dom2, Url2, msg2, M2#{connect_timeout=>300}),
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {unparse, msg2}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, msg2}}} -> ok after 1000 -> error(?LINE) end,

	#nkport{
		domain=dom2, transp=ws, 
		local_ip={127,0,0,1}, local_port=Port2,
        remote_ip={127,0,0,1}, remote_port=1238,
        listen_ip=undefined, listen_port=undefined,
        % resource= <<"/a/b">>, protocol=test_protocol, 
        meta=#{
        	connect_timeout := 300,
        	path := <<"/a/b">>,
            idle_timeout := 180000,
            ws_exts := #{}
        }
	} = Conn2,
	true = Port1 /= Port2,

	receive {Ref1, conn_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_stop} -> ok after 1000 -> error(?LINE) end,

	ok = nkpacket:stop_listener(Ws1),
	receive {Ref1, listen_stop} -> ok after 1000 -> error(?LINE) end,
	test_util:ensure([Ref1, Ref2]).


wss() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	Url0 = "<test://all;transport=wss>",
	{ok, Ws1} = nkpacket:start_listener(dom1, Url0, M1),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	[
		#nkport{
			domain=dom1, transp=wss, 
			local_ip={0,0,0,0}, local_port=1239
		} = Listen1
	] = nkpacket:get_all(dom1),
	
	Url1 = "<test://localhost;transport=wss>",
	{ok, Conn1} = nkpacket:send(dom2, Url1, msg1, M2),
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {unparse, msg1}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, msg1}}} -> ok after 1000 -> error(?LINE) end,

	#nkport{
		domain=dom2, transp=wss, 
		local_ip={127,0,0,1}, local_port=_,
        remote_ip={127,0,0,1}, remote_port=1239,
        listen_ip=undefined, listen_port=undefined,
        protocol=test_protocol, socket={sslsocket, _, _}
	} = Conn1,

	% We send some more data. The same connection is used.
	{ok, Conn1} = nkpacket:send(dom2, Conn1, msg1b),
	receive {Ref2, {unparse, msg1b}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, msg1b}}} -> ok after 1000 -> error(?LINE) end,

	% And in the opposite direction
	[Listen1, Conn1R] = nkpacket:get_all(dom1),
	{ok, Conn1R} = nkpacket:send(dom1, Conn1R, msg1c),
	receive {Ref1, {unparse, msg1c}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, {binary, msg1c}}} -> ok after 1000 -> error(?LINE) end,

	ok = nkpacket:stop_listener(Ws1),
	receive {Ref1, conn_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, listen_stop} -> ok after 1000 -> error(?LINE) end,
	test_util:ensure([Ref1, Ref2]).



multi() ->
	{Ref1, M1, Ref2, M2, Ref3, M3} = test_util:reset_3(),

	% Start Listeners
	{ok, Ws1} = nkpacket:start_listener(dom1, {test_protocol, ws, {0,0,0,0}, 1234},
						   			    M1#{path=>"/dom1/more"}),
	{ok, Ws2} = nkpacket:start_listener(dom2, "<test://all:1234/dom2;transport=ws>",
										M2#{idle_timeout=>1000}),
	U3 = "<test://all:1234/any;transport=ws;host=localhost; path= \"dom3, test\"; "
		 "ws_proto=proto1>",
	{ok, Ws3} = nkpacket:start_listener(dom3, U3, M3),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref3, listen_init} -> ok after 1000 -> error(?LINE) end,
	[
		#nkport{
			domain = dom1,transp = ws,
			local_ip = {0,0,0,0}, local_port = 1234,
			remote_ip = undefined, remote_port = undefined,
			listen_ip = {0,0,0,0}, listen_port = 1234,
			protocol = test_protocol, pid = Ws1, 
			meta = #{path := <<"/dom1/more">>}
		} = Listen1
	] = nkpacket:get_all(dom1),
 	[
 		#nkport{
 			domain = dom2,transp = ws,
          	local_ip = {0,0,0,0},local_port = 1234,
          	listen_ip = {0,0,0,0},listen_port = 1234,
          	protocol = test_protocol, pid = Ws2, 
          	meta = #{
				path := <<"/dom2">>,
          		idle_timeout := 1000
          	}
        } = Listen2
    ] = nkpacket:get_all(dom2),
 	[
 		#nkport{domain = dom3,transp = ws,
			local_ip = {0,0,0,0}, local_port = 1234,
			listen_ip = {0,0,0,0},listen_port = 1234,
			protocol = test_protocol, pid = Ws3, 
			meta = #{
				path := <<"dom3, test">>,
				host := <<"localhost">>,
				ws_proto := <<"proto1">>
			}
		}
	] = nkpacket:get_all(dom3),

	% Now we send a message from dom4 to dom1
	{ok, Conn1} = nkpacket:send(dom4, {test_protocol, ws, {127,0,0,1}, 1234}, msg1,
								#{path=>"/dom1/more", idle_timeout=>500}),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, msg1}}} -> ok after 1000 -> error(?LINE) end,

    [Conn1] = nkpacket:get_all(dom4),
	#nkport{
		domain = dom4, transp = ws,
        local_ip = {127,0,0,1}, local_port = Conn1Port,
        remote_ip = {127,0,0,1}, remote_port = 1234,
        listen_ip = undefined, listen_port = undefined,
        meta = #{
        	idle_timeout := 500, 
        	path := <<"/dom1/more">>,
        	ws_exts := #{}
        }
    } = Conn1,
    [
    	Listen1,
    	#nkport{
			domain = dom1, transp = ws,
         	local_ip = {0,0,0,0}, local_port = 1234,
         	remote_ip = {127,0,0,1}, remote_port = Conn1Port,
         	listen_ip = {0,0,0,0}, listen_port = 1234,
         	meta = #{path := <<"/dom1/more">>}
        }
    ] = nkpacket:get_all(dom1),
	receive {Ref1, conn_stop} -> ok after 1000 -> error(?LINE) end,
	timer:sleep(100),
	[Listen1] = nkpacket:get_all(dom1),
    [] = nkpacket:get_all(dom4),

    % No one is listening here
    {error, closed} = 
    	nkpacket:send(dom4, {test_protocol, ws, {127,0,0,1}, 1234}, msg1),
    {error, closed} = 
    	nkpacket:send(dom4, {test_protocol, ws, {127,0,0,1}, 1234}, msg1, #{path=>"/"}),
    {error, closed} = 
    	nkpacket:send(dom4, {test_protocol, ws, {127,0,0,1}, 1234}, msg1, #{path=>"/dom1"}),

    % Now we connect to dom2
	{ok, Conn2} = nkpacket:send(dom1, "<test://127.0.0.1:1234/dom2;transport=ws>", msg2),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {unparse, msg2}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, {binary, msg2}}} -> ok after 1000 -> error(?LINE) end,
	#nkport{
		domain = dom1, transp = ws,
        local_ip = {127,0,0,1}, local_port = Conn2Port,
        remote_ip = {127,0,0,1}, remote_port = 1234,
        listen_ip = {0,0,0,0}, listen_port = 1234,
        protocol = test_protocol,
        meta = #{
        	idle_timeout := 180000,
        	path := <<"/dom2">>,
        	ws_exts := #{}
        }
    } = Conn2, 								% Outgoing
    [Listen1, Conn2] = nkpacket:get_all(dom1),
    [
    	Listen2,
    	#nkport{
    		domain = dom2,transp = ws,
          	local_ip = {0,0,0,0}, local_port = 1234,
          	remote_ip = {127,0,0,1}, remote_port = Conn2Port,
          	listen_ip = {0, 0, 0, 0}, listen_port = 1234,
        	meta = #{
	        	idle_timeout := 1000,
    	    	path := <<"/dom2">>
    	    }
        }
    ] = nkpacket:get_all(dom2),
	receive {Ref1, conn_stop} -> ok after 2000 -> error(?LINE) end,
	receive {Ref2, conn_stop} -> ok after 2000 -> error(?LINE) end,

	% We connect to dom3, but the host must be 'localhost'
	{error, closed} = 
		nkpacket:send(dom4, "<test://127.0.0.1:1234/dom3;transport=ws>", msg3),
	% It also needs a WS protocol
	{error, closed} = 
		nkpacket:send(dom4, "<test://localhost:1234/dom3;transport=ws>", msg3),
	{error, closed} = 
		nkpacket:send(dom4, "<test://localhost:1234/dom3;transport=ws>", msg3,
					  #{ws_proto=>proto2}),
	{ok, Conn3} = 
		nkpacket:send(dom4, "<test://localhost:1234/dom3;transport=ws>", msg3,
					  #{ws_proto=>proto1}),

	receive {Ref3, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref3, {parse, {binary, msg3}}} -> ok after 1000 -> error(?LINE) end,

	% Send a new message, must use the same transport
	{ok, Conn3} = nkpacket:send(dom4, "<test://127.0.0.1:1234/dom3;transport=ws>", msg4),
	receive {Ref3, {parse, {binary, msg4}}} -> ok after 1000 -> error(?LINE) end,

	% Sent to the other url, starts a new connection
	{ok, Conn4} = 
		nkpacket:send(dom4, "<test://localhost:1234/test;transport=ws;ws_proto=proto1>", 
					  msg5),
	receive {Ref3, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref3, {parse, {binary, msg5}}} -> ok after 1000 -> error(?LINE) end,

	nkpacket_connection:stop(Conn3, normal),
	nkpacket_connection:stop(Conn4, normal),
	receive {Ref3, conn_stop}  -> ok after 1000 -> error(?LINE) end,
	receive {Ref3, conn_stop}  -> ok after 1000 -> error(?LINE) end,

	ok = nkpacket:stop_listener(Listen1),
	ok = nkpacket:stop_listener(Listen2),
	ok = nkpacket:stop_listener(Ws3),
	receive {Ref1, listen_stop}  -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_stop}  -> ok after 1000 -> error(?LINE) end,
	receive {Ref3, listen_stop}  -> ok after 1000 -> error(?LINE) end,
	{error, unknown_listener} = nkpacket:stop_listener(Listen1),
	{error, unknown_listener} = nkpacket:stop_listener(Ws3),
	test_util:ensure([Ref1, Ref2, Ref3]).


ping() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	% Should use default port for ws: 1238
	Url = "<test://localhost;transport=ws>",
	{ok, Ws1} = nkpacket:start_listener(dom1, Url, M1),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,

	{ok, _Conn1} = nkpacket:send(dom2, Url, {nkraw, {ping, <<"ping1">>}}, M2),
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {unparse, {ping, _}}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {pong, <<"ping1">>}} -> ok after 1000 -> error(?LINE) end,
	%% WE HAVE AND ADDITIONAL PONG... WHY???
	receive {Ref2, {pong, <<"ping1">>}} -> ok after 1000 -> error(?LINE) end,

	[_, Conn1R] = nkpacket:get_all(dom1),
	nkpacket_connection:send(Conn1R, {ping, <<"ping2">>}),
	receive {Ref1, {pong, <<"ping2">>}} -> ok after 1000 -> error(?LINE) end,

	nkpacket_connection:send(Conn1R, {close, 1000, <<>>}),
	timer:sleep(50),
	receive {Ref1, conn_stop}  -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_stop}  -> ok after 1000 -> error(?LINE) end,

	ok = nkpacket:stop_listener(Ws1),
	receive {Ref1, listen_stop}  -> ok after 1000 -> error(?LINE) end,
	test_util:ensure([Ref1, Ref2]).


large() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	% Should use default port for ws: 1238
	Url = "<test://localhost;transport=ws>",
	{ok, Ws1} = nkpacket:start_listener(dom1, Url, M1),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,

	LargeMsg = binary:copy(<<"abcdefghij">>, 1000),
	{ok, Conn1} = nkpacket:send(dom2, Url, LargeMsg, M2),
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {unparse, LargeMsg}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, LargeMsg}}} -> ok after 1000 -> error(?LINE) end,

    #nkport{meta=#{ws_exts:=Exts1}} = Conn1,
	10008 = byte_size(list_to_binary(
		nkpacket_connection_ws:encode({binary, LargeMsg}, Exts1))),
	nkpacket_connection:send(Conn1, {close, 1000, <<>>}),
	receive {Ref1, conn_stop}  -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_stop}  -> ok after 1000 -> error(?LINE) end,

	{ok, Conn2} = nkpacket:send(dom2, Url, LargeMsg, M2#{ws_opts=>#{compress=>true}}),
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {unparse, LargeMsg}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, LargeMsg}}} -> ok after 1000 -> error(?LINE) end,

    #nkport{meta=#{ws_exts:=Exts2}} = Conn2,
	42 = byte_size(list_to_binary(
		nkpacket_connection_ws:encode({binary, LargeMsg}, Exts2))),
	nkpacket_connection:stop(Conn2, normal),
	receive {Ref1, conn_stop}  -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_stop}  -> ok after 1000 -> error(?LINE) end,

	ok = nkpacket:stop_listener(Ws1),
	receive {Ref1, listen_stop}  -> ok after 1000 -> error(?LINE) end,
	test_util:ensure([Ref1, Ref2]).







	




