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
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").

ws_test_() ->
  	{setup, spawn, 
    	fun() -> 
    		ok = nkpacket_app:start(),
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
	Url0 = "<test://all;transport=ws>",
	{ok, _, Ws1} = nkpacket:start_listener(Url0, M1#{class=>dom1}),
	{ok, {_, ws, {0,0,0,0}, LPort1}} = nkpacket:get_local(Ws1),
	case LPort1 of
		1238 -> ok;
		_ -> lager:warning("Could not open port 1238")
	end,
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	[
		#nkport{
	       	class = dom1,
			transp=ws, 
			local_ip={0,0,0,0}, local_port=LPort1
		} = _Listen1
	] = test_util:listeners(dom1),
	
	Url1 = "test://localhost:"++integer_to_list(LPort1)++
			";transport=ws;connect_timeout=2000;idle_timeout=1000",
	{ok, Conn1} = nkpacket:send(Url1, msg1, M2#{class=>dom2, base_nkport=>false}),
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {encode, msg1}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, msg1}}} -> ok after 1000 -> error(?LINE) end,
%%
	{ok, #nkport{
		class    = dom2,
		transp   = ws,
		local_ip = {127,0,0,1}, local_port= Port1,
		remote_ip= {127,0,0,1}, remote_port= LPort1,
		listen_ip= undefined, listen_port= undefined,
		protocol = test_protocol,
		opts     = #{path := <<"/">>}
	}} = nkpacket:get_nkport(Conn1),

	[
		#nkport{
	       	class = dom1,
			transp = ws,
			local_ip = {0,0,0,0}, local_port = LPort1,
	        remote_ip = {127,0,0,1}, remote_port = Port1,
	        listen_ip = {0,0,0,0}, listen_port = LPort1,
	        protocol = test_protocol,
	        pid = Conn1R
	        % We don't store the path at the server
	    }
	] = test_util:conns(dom1),

	% We send some more data. The same connection is used.
	{ok, Conn1} = nkpacket:send(Conn1, msg1b, #{class=>dom2}),
	receive {Ref2, {encode, msg1b}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, msg1b}}} -> ok after 1000 -> error(?LINE) end,

	% And in the opposite direction
	{ok, Conn1R} = nkpacket:send(Conn1R, msg1c, #{class=>dom1}),
	receive {Ref1, {encode, msg1c}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, {binary, msg1c}}} -> ok after 1000 -> error(?LINE) end,

	Conn1T = nkpacket_connection:get_timeout(Conn1),
	true = Conn1T > 0 andalso Conn1T =< 1000,
	Conn1RT = nkpacket_connection:get_timeout(Conn1R),
	true = Conn1RT > 179000 andalso Conn1RT =< 180000,

	% Let's send directly to the connection
	ok = nkpacket_connection:send(Conn1, msg1d),
	receive {Ref2, {encode, msg1d}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, msg1d}}} -> ok after 1000 -> error(?LINE) end,
	ok = nkpacket_connection:send(Conn1R, {nkraw, {text, <<"my text">>}}),
	receive {Ref1, {encode, {text, <<"my text">>}}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, {text, <<"my text">>}}} -> ok after 1000 -> error(?LINE) end,

	% Since we use a different URL, it opens a new connection
	Url2 = "test://127.0.0.1:"++integer_to_list(LPort1)++
	        "/a/b;transport=ws;connect_timeout=2000;idle_timeout=500",
	{ok, Conn2} = nkpacket:send(Url2, msg2, M2#{class=>dom2, connect_timeout=>3000, base_nkport=>false}),
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {encode, msg2}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, msg2}}} -> ok after 1000 -> error(?LINE) end,

	{ok, #nkport{
		class    = dom2,
		transp   =ws,
		local_ip ={127,0,0,1}, local_port=Port2,
		remote_ip={127,0,0,1}, remote_port=LPort1,
		listen_ip=undefined, listen_port=undefined,
		opts     =#{
        	path := <<"/a/b">>,
        	host := <<"127.0.0.1">>
        }
	}} = nkpacket:get_nkport(Conn2),
	true = Port1 /= Port2,
	true = Conn1 /= Conn2,

	receive {Ref1, conn_stop} -> ok after 1500 -> error(?LINE) end,
	receive {Ref2, conn_stop} -> ok after 1500 -> error(?LINE) end,
	receive {Ref1, conn_stop} -> ok after 1500 -> error(?LINE) end,
	receive {Ref2, conn_stop} -> ok after 1500 -> error(?LINE) end,

	ok = nkpacket:stop_listeners(Ws1),
	receive {Ref1, listen_stop} -> ok after 1000 -> error(?LINE) end,
	test_util:ensure([Ref1, Ref2]),
	ok.


wss() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	Url0 = "<test://all;transport=wss>",
	{ok, _, Ws1} = nkpacket:start_listener(Url0, M1#{class=>dom1}),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	{ok, {_, wss, {0,0,0,0}, LPort1}} = nkpacket:get_local(Ws1),
	case LPort1 of
		1239 -> ok;
		_ -> lager:warning("Could not open port 1239")
	end,
	[
		#nkport{
	       	class = dom1,
			transp=wss, 
			local_ip={0,0,0,0}, local_port=LPort1
		} = _Listen1
	] = test_util:listeners(dom1),
	
	Url1 = "<test://localhost:"++integer_to_list(LPort1)++";transport=wss>",
	{ok, Conn1} = nkpacket:send(Url1, msg1, M2#{class=>dom2, base_nkport=>false}),
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {encode, msg1}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, msg1}}} -> ok after 1000 -> error(?LINE) end,

	{ok, #nkport{
       	class = dom2,
		transp=wss,
		local_ip={127,0,0,1}, local_port=_,
        remote_ip={127,0,0,1}, remote_port=LPort1,
        listen_ip=undefined, listen_port=undefined,
        protocol=test_protocol, socket={sslsocket, _, _},
        pid = Conn1
	}} = nkpacket:get_nkport(Conn1),

	% We send some more data. The same connection is used.
	{ok, Conn1} = nkpacket:send(Conn1, msg1b, #{class=>dom2}),
	receive {Ref2, {encode, msg1b}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, msg1b}}} -> ok after 1000 -> error(?LINE) end,

	% And in the opposite direction
	[#nkport{pid=Conn1R}] = test_util:conns(dom1),
	{ok, Conn1R} = nkpacket:send(Conn1R, msg1c, #{class=>dom1}),
	receive {Ref1, {encode, msg1c}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, {binary, msg1c}}} -> ok after 1000 -> error(?LINE) end,

	ok = nkpacket:stop_listeners(Ws1),
	receive {Ref1, conn_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, listen_stop} -> ok after 1000 -> error(?LINE) end,
	test_util:ensure([Ref1, Ref2]).


ping() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	Url = "<test://localhost;transport=ws>",
	{ok, _, Ws1} = nkpacket:start_listener(Url, M1#{class=>dom1}),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,

	{ok, _Conn1} = nkpacket:send(Url, {nkraw, {ping, <<"ping1">>}}, M2#{class=>dom2}),
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {encode, {ping, _}}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {pong, <<"ping1">>}} -> ok after 1000 -> error(?LINE) end,

	%% WE HAVE AND ADDITIONAL PONG... WHY???
	receive {Ref2, {pong, <<"ping1">>}} -> ok after 1000 -> error(?LINE) end,

	[Conn1R] = test_util:conns(dom1),
	nkpacket_connection:send(Conn1R, {nkraw, {ping, <<"ping2">>}}),
	receive {Ref1, {encode, {ping, <<"ping2">>}}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {pong, <<"ping2">>}} -> ok after 1000 -> error(?LINE) end,


	nkpacket_connection:send(Conn1R, {nkraw, {close, 1000, <<>>}}),
	receive {Ref1, {encode, {close, 1000, <<>>}}} -> ok after 1000 -> error(?LINE) end,
	timer:sleep(50),
	receive {Ref1, conn_stop}  -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_stop}  -> ok after 1000 -> error(?LINE) end,

	ok = nkpacket:stop_listeners(Ws1),
	receive {Ref1, listen_stop}  -> ok after 1000 -> error(?LINE) end,
	test_util:ensure([Ref1, Ref2]).


large() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	Url = "<test://localhost;transport=ws>",
	{ok, _, Ws1} = nkpacket:start_listener(Url, M1),	% No class
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,

	LargeMsg = binary:copy(<<"abcdefghij">>, 1000),
	{ok, Conn1} = nkpacket:send(Url, LargeMsg, M2),
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {encode, LargeMsg}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, LargeMsg}}} -> ok after 1000 -> error(?LINE) end,

	nkpacket_connection:send(Conn1, {nkraw, {close, 1000, <<>>}}),
	receive {Ref2, {encode, {close, 1000, <<>>}}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, conn_stop}  -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_stop}  -> ok after 1000 -> error(?LINE) end,

	ok = nkpacket:stop_listeners(Ws1),
	receive {Ref1, listen_stop}  -> ok after 1000 -> error(?LINE) end,
	test_util:ensure([Ref1, Ref2]).


multi() ->
	{Ref1, M1, Ref2, M2, Ref3, M3} = test_util:reset_3(),

	% Start Listeners
	% Listener 1 on {0,0,0,0}, all hosts, path /dom1/more
	% Listener 2 on {0,0,0,0}, all hosts, path /dom2
	% Listener 3 on {0,0,0,0}, localhost, path /dom3 and proto 'proto1'

	{ok, _, Ws1} = nkpacket:start_listener(#nkconn{protocol=test_protocol, transp=ws, ip={0,0,0,0}, port=0,
						   			    opts=M1#{class=>dom1, path=>"/dom1/more"}}),
	{ok, {_, ws, {0,0,0,0}, P1}} = nkpacket:get_local(Ws1),
	P1S = integer_to_list(P1),

	{ok, _, Ws2} = nkpacket:start_listener("<test://all:"++P1S++"/dom2;transport=ws>",
										M2#{class=>dom2, idle_timeout=>1000}),
	Url3 = "test://all:"++P1S++"/any;transport=ws;host=localhost; path= \"dom3\"; "
		 "ws_proto=proto1",
	{ok, _, Ws3} = nkpacket:start_listener(Url3, M3#{class=>dom3}),

	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref3, listen_init} -> ok after 1000 -> error(?LINE) end,
	timer:sleep(50),

	[
		#nkport{
			class    = dom1,
			transp   = ws,
			local_ip = {0,0,0,0}, local_port= P1,
			remote_ip= undefined, remote_port= undefined,
			listen_ip= {0,0,0,0}, listen_port= P1,
			protocol = test_protocol, pid= Ws1,
			socket   = Cow1,
			opts     = #{path := <<"/dom1/more">>}
		} = Listen1
	] = test_util:listeners(dom1),
 	[
 		#nkport{
			class    = dom2,
			transp   = ws,
			local_ip = {0,0,0,0}, local_port= P1,
			listen_ip= {0,0,0,0}, listen_port= P1,
			protocol = test_protocol, pid= Ws2,
			socket   = Cow1,
			opts     = #{path := <<"/dom2">>}
        } = Listen2
    ] = test_util:listeners(dom2),
 	[
 		#nkport{transp   = ws,
				class    = dom3,
				local_ip = {0,0,0,0}, local_port= P1,
				listen_ip= {0,0,0,0}, listen_port= P1,
				protocol = test_protocol, pid= Ws3,
				socket   = Cow1,
				opts     = #{
				host := <<"localhost">>,
				path := <<"/dom3">>
			}
		}
	] = test_util:listeners(dom3),
	[{{{0,0,0,0}, P1}, Cow1, [Filter1, Filter2, Filter3]}] = 
    	nkpacket_cowboy:get_all(),
	{Ws3, <<"localhost">>, [<<"dom3">>], <<"proto1">>} = 
    	nkpacket_cowboy:extract_filter(Filter1),
	{Ws2, any, [<<"dom2">>], any} = nkpacket_cowboy:extract_filter(Filter2),
	{Ws1, any, [<<"dom1">>, <<"more">>], any} = nkpacket_cowboy:extract_filter(Filter3),

	% Now we send a message from dom5 to dom1, we don't mind host and ws_proto
	{ok, Conn1} = nkpacket:send(#nkconn{protocol=test_protocol, transp=ws, ip={127,0,0,1}, port=P1,
								 	    opts=#{path=>"/dom1/more", idle_timeout=>500, class=>dom5}},
										msg1),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, {binary, msg1}}} -> ok after 1000 -> error(?LINE) end,

	% Conn1B = Conn1#nkport{meta=maps:remove(idle_timeout, Conn1#nkport.meta)},
    [#nkport{pid=Conn1}] = test_util:conns(dom5),
	{ok, #nkport{
		class    = dom5,
		transp   = ws,
		local_ip = {127,0,0,1}, local_port= Conn1Port,
		remote_ip= {127,0,0,1}, remote_port= P1,
		listen_ip= undefined, listen_port= undefined,
		opts     = #{path := <<"/dom1/more">>}
    }} = nkpacket:get_nkport(Conn1),
    [
    	#nkport{
       	class = dom1,
		transp = ws,
        local_ip = {0,0,0,0}, local_port = P1,
        remote_ip = {127,0,0,1}, remote_port = Conn1Port,
        listen_ip = {0,0,0,0}, listen_port = P1}
    ] = test_util:conns(dom1),
	receive {Ref1, conn_stop} -> ok after 1000 -> error(?LINE) end,
	timer:sleep(100),
	[Listen1] = test_util:listeners(dom1),
    [] = test_util:listeners(dom5),

    % No one is listening here
	{error, closed} =
    	nkpacket:send(#nkconn{protocol=test_protocol, transp=ws, ip={127,0,0,1}, port=P1, opts=#{class=>dom5}}, msg1),
	{error, closed} =
    	nkpacket:send(#nkconn{protocol=test_protocol, transp=ws, ip={127,0,0,1}, port=P1, opts=#{class=>dom5, path=>"/"}}, msg1),
	{error, closed} =
    	nkpacket:send(#nkconn{protocol=test_protocol, transp=ws, ip={127,0,0,1}, port=P1, opts=#{class=>dom5, path=>"/dom1"}}, msg1),

    % Now we connect to dom2
    % We use host because of the url
	{ok, Conn2} = nkpacket:send("<test://127.0.0.1:"++P1S++"/dom2;transport=ws>",
								msg2, M1#{class=>dom1, base_nkport=>true}),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {encode, msg2}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {parse, {binary, msg2}}} -> ok after 1000 -> error(?LINE) end,
	{ok, #nkport{
		class    = dom1,
		transp   = ws,
		local_ip = {127,0,0,1}, local_port= Conn2Port,
		remote_ip= {127,0,0,1}, remote_port= P1,
		listen_ip= {0,0,0,0}, listen_port= P1,
		protocol = test_protocol,
		opts     = #{
        	host := <<"127.0.0.1">>,		% We included it in call
        	path := <<"/dom2">>
        }
    }} = nkpacket:get_nkport(Conn2),								% Outgoing

    [#nkport{pid=Conn2}] = test_util:conns(dom1),
    [
    	#nkport{
	       	class = dom2,
    		transp = ws,
          	local_ip = {0,0,0,0}, local_port = P1,
          	remote_ip = {127,0,0,1}, remote_port = Conn2Port,
          	listen_ip = {0,0,0,0}, listen_port = P1
        }
    ] = test_util:conns(dom2),
	receive {Ref1, conn_stop} -> ok after 2000 -> error(?LINE) end,
	receive {Ref2, conn_stop} -> ok after 2000 -> error(?LINE) end,

	% We connect to dom3, but the host must be 'localhost'
	{error, closed} =
		nkpacket:send("<test://127.0.0.1:"++P1S++"/dom3;transport=ws>", msg3,
					  #{class=>dom5}),
	{error, closed} =
		nkpacket:send("<test://localhost:"++P1S++"/dom3;transport=ws>", msg3,
					  #{class=>dom5}),
	% It also needs a supported WS protocol
	{error, closed} =
		nkpacket:send("<test://localhost:"++P1S++"/dom3;transport=ws>", msg3,
					  #{ws_proto=>proto2, class=>dom5}),

	{ok, Conn3} =
		nkpacket:send("<test://localhost:"++P1S++"/dom3;transport=ws>", msg3,
					  #{ws_proto=>proto1, class=>dom5}),

	receive {Ref3, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref3, {parse, {binary, msg3}}} -> ok after 1000 -> error(?LINE) end,

	% Send a new message, must use the same transport (same path, host and proto)
	{error, closed} = nkpacket:send("<test://127.0.0.1:"++P1S++"/dom3;transport=ws>",
									msg4, #{class=>dom5}),
	{error, closed} = nkpacket:send("<test://127.0.0.1:"++P1S++"/dom3;transport=ws>;ws_proto=proto1", msg4, #{class=>dom5}),

	{ok, Conn3} = nkpacket:send("<test://127.0.0.1:"++P1S++"/dom3;transport=ws>;ws_proto=proto1;host=localhost", msg4, #{class=>dom5}),
	receive {Ref3, {parse, {binary, msg4}}} -> ok after 1000 -> error(?LINE) end,

	nkpacket_connection:stop(Conn3, normal),
	receive {Ref3, conn_stop}  -> ok after 1000 -> error(?LINE) end,
	% receive {Ref3, conn_stop}  -> ok after 1000 -> error(?LINE) end,

	ok = nkpacket:stop_listeners(Listen1),
	ok = nkpacket:stop_listeners(Listen2),
	ok = nkpacket:stop_listeners(Ws3),
	receive {Ref1, listen_stop}  -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_stop}  -> ok after 1000 -> error(?LINE) end,
	receive {Ref3, listen_stop}  -> ok after 1000 -> error(?LINE) end,
	ok = nkpacket:stop_listeners(Listen1),
	ok = nkpacket:stop_listeners(Ws3),
	test_util:ensure([Ref1, Ref2, Ref3]).


