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

-module(http_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").
-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").

http_test_() ->
  	{setup, spawn, 
    	fun() -> 
    		nkpacket_app:start(),
    		?debugMsg("Starting HTTP test")
		end,
		fun(_) -> 
			ok
		end,
	    fun(_) ->
		    [
				fun() -> basic() end,
				fun() -> https() end
			]
		end
  	}.


basic() ->
	{Ref1, M1, Ref2, M2, Ref3, M3} = test_util:reset_3(),
 	Url1 = "<http://all:56789/test1>",
	Dispatch1 = cowboy_router:compile([
		{'_', [
			{"/test1", test_cowboy_handler, [M1]}
		]}
	]),
	{ok, Http1} = nkpacket:start_listener(dom1, Url1, M1#{cowboy_dispatch=>Dispatch1}),
 	Url2 = "<http://all:56789/test2>",
	Dispatch2 = cowboy_router:compile([
		{'_', [
			{"/test2", test_cowboy_handler, [M2]}
		]}
	]),
	{ok, Http2} = nkpacket:start_listener(dom2, Url2, M2#{cowboy_dispatch=>Dispatch2}),
	Dispatch3 = cowboy_router:compile([
		{'_', [
			{"/test3", test_cowboy_handler, [M3]}
		]}
	]),
 	Url3 = "<http://all:56789>",
	{ok, Http3} = nkpacket:start_listener(dom3, Url3, M3#{
		host => "localhost",
		path => "/test3, /test3b/test3bb",
		cowboy_opts => [{env, [{dispatch, Dispatch3}]}]
	}),
	timer:sleep(100),

	[
		#nkport{
			domain = dom1,transp = http,
			local_ip = {0,0,0,0}, local_port = 56789,
			listen_ip = {0,0,0,0}, listen_port = 56789,
			protocol = nkpacket_protocol_http, pid=Http1, socket = CowPid,
			meta = #{
				cowboy_dispatch := _,
				path := <<"/test1">>
			}
		}
	] = nkpacket:get_all(dom1),
	[
	 	#nkport{
 			domain = dom2,transp = http,
			local_ip = {0,0,0,0}, local_port = 56789,
			listen_ip = {0,0,0,0}, listen_port = 56789,
			pid = Http2, socket = CowPid,
			meta = #{
				cowboy_dispatch := _,
				path := <<"/test2">>
			}
		}
	] = nkpacket:get_all(dom2),
	[
		#nkport{
			domain = dom3,transp = http,
			local_ip = {0,0,0,0}, local_port = 56789,
			listen_ip = {0,0,0,0}, listen_port = 56789,
			pid = Http3, socket = CowPid,
			meta = #{
				cowboy_opts :=[{env,[{dispatch, _}]}],
				host := <<"localhost">>,
				path := <<"/test3, /test3b/test3bb">>
			}
		}
	] = nkpacket:get_all(dom3),

	{ok, Gun} = gun:open("127.0.0.1", 56789, [{type, tcp}, {retry, 0}]),
	{ok, 404, H1} = get(Gun, "/", []),
	<<"NkPACKET">> = nklib_util:get_value(<<"server">>, H1),

	%% All connections share the same server process
	{ok, 200, _, <<"Hello World!">>} = get(Gun, "/test1", []),
	P = receive {Ref1, http_init, P1} -> P1 after 1000 -> error(?LINE) end,
	P = receive {Ref1, http_terminate, P2} -> P2 after 1000 -> error(?LINE) end,

	{ok, 200, _, <<"Hello World!">>} = get(Gun, "/test2", []),
	P = receive {Ref2, http_init, P3} -> P3 after 1000 -> error(?LINE) end,
	P = receive {Ref2, http_terminate, P4} -> P4 after 1000 -> error(?LINE) end,

	{ok, 404, H2} = get(Gun, "/test3", []),
	<<"NkPACKET">> = nklib_util:get_value(<<"server">>, H2),
	{ok, 200, _, _} = get(Gun, "/test3", [{<<"host">>, <<"localhost">>}]),
	P = receive {Ref3, http_init, P5} -> P5 after 1000 -> error(?LINE) end,
	P = receive {Ref3, http_terminate, P6} -> P6 after 1000 -> error(?LINE) end,

	%% This path is ok for NkPacket, but not for our current dispath
	{ok, 404, H3} = get(Gun, "/test3b/test3bb", [{<<"host">>, <<"localhost">>}]),
	<<"Cowboy">> = nklib_util:get_value(<<"server">>, H3),

	% If we close the transport, NkPacket blocks access, but only for the next
	% connection
	ok = nkpacket:stop_listener(Http3),
	timer:sleep(100),
	{ok, Gun2} = gun:open("127.0.0.1", 56789, [{type, tcp}, {retry, 0}]),
	{ok, 404, H4} = get(Gun2, "/test3b/test3bb", [{<<"host">>, <<"localhost">>}]),
	<<"NkPACKET">> = nklib_util:get_value(<<"server">>, H4),

	ok = nkpacket:stop_listener(Http1),
	ok = nkpacket:stop_listener(Http2),
	ok.


https() ->
	{Ref1, M1} = test_util:reset_1(),
 	Url1 = "<https://all:56789>",
	Dispatch1 = cowboy_router:compile([
		{'_', [
			{"/test1", test_cowboy_handler, [M1]}
		]}
	]),
	{ok, Http1} = nkpacket:start_listener(dom1, Url1, M1#{cowboy_dispatch=>Dispatch1}),
	{ok, Gun} = gun:open("127.0.0.1", 56789, [{type, ssl}, {retry, 0}]),
	{ok, 200, _, <<"Hello World!">>} = get(Gun, "/test1", []),
	P = receive {Ref1, http_init, P1} -> P1 after 1000 -> error(?LINE) end,
	P = receive {Ref1, http_terminate, P2} -> P2 after 1000 -> error(?LINE) end,
	{ok, 404, H1} = get(Gun, "/kk", []),
	<<"Cowboy">> = nklib_util:get_value(<<"server">>, H1),
	ok = nkpacket:stop_listener(Http1).




%%%%%%%% Util

get(Pid, Path, Hds) ->
	Ref = gun:get(Pid, Path, Hds),
	receive
		{gun_response, _, Ref, fin, Code, RHds} -> 
			{ok, Code, RHds};
		{gun_response, _, Ref, nofin, Code, RHds} -> 
			receive 
				{gun_data, _, Ref, fin, Data} -> 
					{ok, Code, RHds, Data}
			after 1000 ->
				timeout
			end;
		{gun_error, _, Ref, Error} ->
			{error, Error}
	after 1000 ->
		{error, timeout}
	end.



