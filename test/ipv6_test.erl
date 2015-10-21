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

-module(ipv6_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").
-include("nkpacket.hrl").

ipv6_test_() ->
  	{setup, spawn, 
    	fun() -> 
    		ok = nkpacket_app:start(),
    		?debugMsg("Starting IPv6 test")
		end,
		fun(_) -> 
			ok
		end,
	    fun(_) ->
		    [
				fun() -> basic() end,
				fun() -> is_local() end
			]
		end
  	}.


basic() ->
	LPort1 = test_util:get_port(tcp),
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	All6 = {0,0,0,0,0,0,0,0},
	Local6 = {0,0,0,0,0,0,0,1},
	Url = "<test:[::1]:"++integer_to_list(LPort1)++";transport=tcp>",
	{ok, Tcp1} = nkpacket:start_listener(Url, M1#{group=>dom1}),
	{ok, Tcp2} = nkpacket:start_listener({test_protocol, tcp, All6, 0}, M2#{group=>dom2}),
	{ok, {_, tcp, _, LPort1}} = nkpacket:get_local(Tcp1),	
	{ok, {_, tcp, _, LPort2}} = nkpacket:get_local(Tcp2),
	case LPort2 of
		1235 -> ok;
		_ -> lager:warning("Could not open 1235")
	end,

	timer:sleep(100),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_init} -> ok after 1000 -> error(?LINE) end,

	[Listen1] = nkpacket:get_all(dom1),
 	{ok, #nkport{
 		transp = tcp,
        local_ip = Local6, local_port = LPort1,
        listen_ip = Local6, listen_port = LPort1,
        protocol = test_protocol,
        meta = #{group:=dom1}
	}} = nkpacket:get_nkport(Listen1),

	[Listen2] = nkpacket:get_all(dom2),
	{ok, #nkport{
		transp = tcp,
        local_ip = All6, local_port = LPort2, 
        remote_ip = undefined, remote_port = undefined,
        listen_ip = All6, listen_port = LPort2,
        protocol = test_protocol,
        meta = #{group:=dom2}
	}} = nkpacket:get_nkport(Listen2),

	{ok, _} = nkpacket:send(Url, msg1, M2#{group=>dom2}),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, msg1}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {encode, msg1}} -> ok after 1000 -> error(?LINE) end,

	[Conn1] = nkpacket_connection:get_all(dom1),
	{ok, #nkport{
			transp=tcp,
			local_ip=Local6, local_port=_ConnPort1,
			remote_ip=Local6, remote_port=ConnPort2,
			listen_ip=Local6, listen_port=LPort1,
	        meta = #{group:=dom1}
	}} = nkpacket:get_nkport(Conn1),

	[Conn2] = nkpacket_connection:get_all(dom2),
	{ok, #nkport{
			transp=tcp,
			local_ip=Local6, local_port=ConnPort2,
			remote_ip=Local6, remote_port=LPort1,
			listen_ip=All6, listen_port=LPort2,
	        meta = #{group:=dom2}
	}} = nkpacket:get_nkport(Conn2),

	ok = nkpacket:stop_listener(Tcp1),
	ok = nkpacket:stop_listener(Tcp2),

	receive {Ref2, conn_stop} -> ok after 2000 -> error(?LINE) end,
	receive {Ref1, conn_stop} -> ok after 2000 -> error(?LINE) end,
	receive {Ref2, listen_stop} -> ok after 2000 -> error(?LINE) end,
	receive {Ref1, listen_stop} -> ok after 2000 -> error(?LINE) end,
	test_util:ensure([Ref1, Ref2]).


is_local() ->
	LPort0 = test_util:get_port(tcp),
	LPort1 = test_util:get_port(tcp),
	LPort2 = test_util:get_port(tcp),
	_ = test_util:reset_2(),

	{ok, Tcp0} = nkpacket:start_listener(
		"<test:[::1]:"++integer_to_list(LPort0)++";transport=tcp>", #{}),
	{ok, Tcp1} = nkpacket:start_listener( 
		"<test:[::1]:"++integer_to_list(LPort1)++";transport=tcp>", #{group=>dom1}),
	{ok, Tcp2} = nkpacket:start_listener(
		"<test://all6:"++integer_to_list(LPort2)++";transport=udp>", #{group=>dom2}),

	[Uri0] = nklib_parse:uris(
		"<test:[::1]:"++integer_to_list(LPort0)++";transport=tcp>"),
	true = nkpacket:is_local(Uri0),
	false = nkpacket:is_local(Uri0, #{group=>dom1}),
	false = nkpacket:is_local(Uri0, #{group=>dom2}),

	[Uri1] = nklib_parse:uris(
		"<test:[::1]:"++integer_to_list(LPort1)++";transport=tcp>"),
	false = nkpacket:is_local(Uri1),
	true = nkpacket:is_local(Uri1, #{group=>dom1}),
	false = nkpacket:is_local(Uri1, #{group=>dom2}),

	[Uri2] = nklib_parse:uris(
		"<test:[::1]:"++integer_to_list(LPort2)++";transport=udp>"),
	false = nkpacket:is_local(Uri2),
	false = nkpacket:is_local(Uri2, #{group=>dom1}),
	true = nkpacket:is_local(Uri2, #{group=>dom2}),

	[Uri3] = nklib_parse:uris(
		"<test:[::2]:"++integer_to_list(LPort1)++";transport=tcp>"),
	false = nkpacket:is_local(Uri3),
	false = nkpacket:is_local(Uri3, #{group=>dom1}),
	false = nkpacket:is_local(Uri3, #{group=>dom2}),

	case 
		[Ip || Ip <- nkpacket_config_cache:local_ips(), size(Ip)==8]
		-- [{0,0,0,0,0,0,0,1}]
	of
		[] -> 
			ok;
		[Local6|_] ->
			Url4 = list_to_binary([
						"<test:[", nklib_util:to_host(Local6), "]:" ++ 
						integer_to_list(LPort2)++";transport=udp>"]),
			[Uri4] = nklib_parse:uris(Url4),
			false = nkpacket:is_local(Uri4, #{group=>dom1}),
			true = nkpacket:is_local(Uri4, #{group=>dom2})
	end,

	ok = nkpacket:stop_listener(Tcp0),
	ok = nkpacket:stop_listener(Tcp1),
	ok = nkpacket:stop_listener(Tcp2).







