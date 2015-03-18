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
    		nkpacket_app:start(),
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
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	All6 = {0,0,0,0,0,0,0,0},
	Local6 = {0,0,0,0,0,0,0,1},
	Url = "<test:[::1]:56789;transport=tcp>",
	{ok, Tcp1} = nkpacket:start_listener(dom1, Url, M1),
	{ok, Tcp2} = nkpacket:start_listener(dom2, {test_protocol, tcp, All6, 0}, M2),

	timer:sleep(100),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, listen_init} -> ok after 1000 -> error(?LINE) end,
	[Listen1] = nkpacket:get_all(dom1),
 	#nkport{
 		domain = dom1, transp = tcp,
         local_ip = Local6, local_port = 56789,
         listen_ip = Local6, listen_port = 56789,
         protocol = test_protocol
	} = Listen1,
	[Listen2] = nkpacket:get_all(dom2),
	#nkport{
		domain = dom2, transp = tcp,
        local_ip = All6, local_port = LPort1, 
        remote_ip = undefined, remote_port = undefined,
        listen_ip = All6, listen_port = LPort1,
        protocol = test_protocol
    } = Listen2,
	{ok, 56789} = nkpacket:get_port(Tcp1),	
	{ok, LPort1} = nkpacket:get_port(Tcp2),

	Uri = "<test://[::1]:56789;transport=tcp>",
	{ok, _} = nkpacket:send(dom2, Uri, msg1),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, msg1}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {unparse, msg1}} -> ok after 1000 -> error(?LINE) end,

	[
		Listen2,
		#nkport{
			domain=dom2, transp=tcp,
			local_ip=Local6, local_port=LPort2,
			remote_ip=Local6, remote_port=56789,
			listen_ip=All6, listen_port=LPort1,
			meta = #{test:=_}
		}
	] = 
		lists:sort(nkpacket:get_all(dom2)),

	[
		Listen1,
		#nkport{
			domain=dom1, transp=tcp,
			local_ip=Local6, local_port=_LPort1,
			remote_ip=Local6, remote_port=LPort2,
			listen_ip=Local6, listen_port=56789,
			meta = #{test:=_}
		}
	] = 
		lists:sort(nkpacket:get_all(dom1)),

	ok = nkpacket:stop_listener(Tcp1),
	ok = nkpacket:stop_listener(Tcp2),

	receive {Ref2, conn_stop} -> ok after 2000 -> error(?LINE) end,
	receive {Ref1, conn_stop} -> ok after 2000 -> error(?LINE) end,
	receive {Ref2, listen_stop} -> ok after 2000 -> error(?LINE) end,
	receive {Ref1, listen_stop} -> ok after 2000 -> error(?LINE) end,
	test_util:ensure([Ref1, Ref2]).


is_local() ->
	_ = test_util:reset_2(),
	{ok, Tcp1} = nkpacket:start_listener(dom1, "<test:[::1]:56789;transport=tcp>", #{}),
	{ok, Tcp2} = nkpacket:start_listener(dom2, "<test://all6:56790;transport=udp>", #{}),

	%% Default port for tcp is 56789
	[Uri1] = nklib_parse:uris("<test:[::1]:56789;transport=tcp>"),
	true = nkpacket:is_local(dom1, Uri1),
	false = nkpacket:is_local(dom2, Uri1),

	[Uri2] = nklib_parse:uris("<test:[::1]:56790;transport=udp>"),
	false = nkpacket:is_local(dom1, Uri2),
	true = nkpacket:is_local(dom2, Uri2),

	[Uri3] = nklib_parse:uris("<test:[::2]:56789;transport=tcp>"),
	false = nkpacket:is_local(dom1, Uri3),
	false = nkpacket:is_local(dom2, Uri3),

	case 
		[Ip || Ip <- nkpacket_config_cache:local_ips(), size(Ip)==8]
		-- [{0,0,0,0,0,0,0,1}]
	of
		[] -> 
			ok;
		[Local6|_] ->
			Url4 = list_to_binary([
						"<test:[", nklib_util:to_host(Local6), "]:56790;transport=udp>"]),
			[Uri4] = nklib_parse:uris(Url4),
			false = nkpacket:is_local(dom1, Uri4),
			true = nkpacket:is_local(dom2, Uri4)
	end,

	ok = nkpacket:stop_listener(Tcp1),
	ok = nkpacket:stop_listener(Tcp2).







