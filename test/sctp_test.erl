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

-module(sctp_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").
-include("nkpacket.hrl").

sctp_test_() ->
    case gen_sctp:open() of
        {ok, S} ->
            gen_sctp:close(S),
		  	{setup, spawn, 
		    	fun() -> 
		    		ok = nkpacket_app:start(),
		    		?debugMsg("Starting SCTP test")
				end,
				fun(_) -> 
					ok
				end,
			    fun(_) ->
				    [
						fun() -> basic() end
					]
				end
		  	};
        {error, eprotonosupport} ->
            ?debugMsg("Skipping SCTP test (no Erlang support)"),
            [];
        {error, esocktnosupport} ->
            ?debugMsg("Skipping SCTP test (no OS support)"),
            []
    end.


basic() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	{ok, Sctp1} = nkpacket:start_listener(dom1, 
										 {test_protocol, sctp, {0,0,0,0}, 0}, 
										 M1#{idle_timeout=>5000}),
	{ok, Sctp2} = nkpacket:start_listener(dom2, 
										 {test_protocol, sctp, {127,0,0,1}, 0}, M2),
	timer:sleep(100),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end, 
	receive {Ref2, listen_init} -> ok after 1000 -> error(?LINE) end,
	[Listen1] = nkpacket:get_all(dom1),
	#nkport{
		transp=sctp, 
		local_ip={0,0,0,0}, local_port=Port1, 
		listen_ip={0,0,0,0}, listen_port=Port1,
		remote_ip=undefined, remote_port=undefined,
		pid=Sctp1, socket={_Port1, 0},
        meta = #{group:=dom1}

	} = Listen1,
	[Listen2] = nkpacket:get_all(dom2),
	#nkport{
		transp=sctp, 
		local_ip={127,0,0,1}, local_port=Port2, 
		listen_ip={127,0,0,1}, listen_port=Port2,
		remote_ip=undefined, remote_port=undefined,
		pid=Sctp2, socket = {_Port2, 0},
        meta = #{group:=dom2}
	} = Listen2,
	{ok, {_, _, Port1}} = nkpacket:get_local(Sctp1),	
	{ok, {_, _, _}} = nkpacket:get_local(Sctp2),

	Uri = "<test://localhost:"++integer_to_list(Port1)++";transport=sctp>",
	{ok, Conn1} = nkpacket:send(dom2, Uri, msg1, 
								M2#{connect_timeout=>5000, idle_timeout=>1000}),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, msg1}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref2, {encode, msg1}} -> ok after 1000 -> error(?LINE) end,

	[
		Listen2,
		#nkport{
			transp=sctp,
			local_ip={127,0,0,1}, local_port=Port2,
			remote_ip={127,0,0,1}, remote_port=Port1,
			listen_ip={127,0,0,1}, listen_port=Port2,
        	meta = #{group:=dom2}
		} = Conn1
	] = 
		lists:sort(nkpacket:get_all(dom2)),

	% lager:warning("Conn1: ~p", [Conn1]),
	% lager:warning("Conn1B: ~p", [Conn1B]),

	[
		Listen1,
		#nkport{
			transp=sctp,
			local_ip={0,0,0,0}, local_port=Port1,
			remote_ip={127,0,0,1}, remote_port=Port2,
			listen_ip={0,0,0,0}, listen_port=Port1,
	        meta = #{group:=dom1}
		} = Conn1R
	] = 
		lists:sort(nkpacket:get_all(dom1)),

	% Reverse
	{ok, Conn1R} = nkpacket:send(dom1, {test_protocol, sctp, {127,0,0,1}, Port2}, 
							     msg2, M1),
	receive {Ref2, {parse, msg2}} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {encode, msg2}} -> ok after 1000 -> error(?LINE) end,

	% %% Connection 2 will stop after 1 msec, and will tear down conn1
	receive {Ref2, conn_stop} -> ok after 2000 -> error(?LINE) end,
	receive {Ref1, conn_stop} -> ok after 2000 -> error(?LINE) end,
	timer:sleep(50),
	[Listen2] = nkpacket:get_all(dom2),
	[Listen1] = nkpacket:get_all(dom1),
	test_util:ensure([Ref1, Ref2]).



