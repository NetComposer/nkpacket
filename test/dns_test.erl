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

-module(dns_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").
-include("nkpacket.hrl").

dns_test_() ->
  	{setup, spawn, 
    	fun() -> 
    		ok = nkpacket_app:start(),
		    nkpacket_config:register_protocol(sip, ?MODULE),
		    nkpacket_config:register_protocol(sips, ?MODULE),
		    ?debugMsg("Starting DNS test")
		end,
		fun(_) -> 
			ok 
		end,
	    fun(_) ->
		    [
				fun() -> uris() end
				% {timeout, 60, fun() -> resolv1() end},
				% {timeout, 60, fun() -> resolv2() end}
			]
		end
  	}.


start() ->
    nkpacket_app:start(),
    nkpacket_config:register_protocol(sip, ?MODULE),
    nkpacket_config:register_protocol(sips, ?MODULE).


uris() ->
    Test = [
        {"<sip:1.2.3.4;transport=udp>",  {ok, [{udp, {1,2,3,4}, 0}], #{}}}
        % {"<sip:1.2.3.4;transport=tcp>",  {ok, [{tcp, {1,2,3,4}, 0}], #{}}},
        % {"<sip:1.2.3.4;transport=tls>",  {ok, [{tls, {1,2,3,4}, 0}], #{}}},
        % {"<sip:1.2.3.4;transport=sctp>", {ok, [{sctp, {1,2,3,4}, 0}], #{}}},
        % {"<sip:1.2.3.4;transport=ws>",   {ok, [{ws, {1,2,3,4}, 0}], #{}}},
        % {"<sip:1.2.3.4;transport=wss>",  {ok, [{wss, {1,2,3,4}, 0}], #{}}},
        % {"<sip:1.2.3.4;transport=other>",  {error, {invalid_transport, other}}},

        % {"<sips:1.2.3.4;transport=udp>",  {error, {invalid_transport, udp}}},
        % {"<sips:1.2.3.4;transport=tcp>",  {error, {invalid_transport, tcp}}},
        % {"<sips:1.2.3.4;transport=tls>",  {ok, [{tls, {1,2,3,4}, 0}], #{}}},
        % {"<sips:1.2.3.4;transport=sctp>", {error, {invalid_transport, sctp}}},
        % {"<sips:1.2.3.4;transport=ws>",   {error, {invalid_transport, ws}}},
        % {"<sips:1.2.3.4;transport=wss>",  {ok, [{wss, {1,2,3,4}, 0}], #{}}},
        % {"<sip:1.2.3.4;transport=other>",  {error, {invalid_transport, other}}},

        % {"<sip:1.2.3.4:4321;transport=tcp>",  {ok, [{tcp, {1,2,3,4}, 4321}], #{}}},
        % {"<sips:127.0.0.1:4321;transport=tls>",  {ok, [{tls, {127,0,0,1}, 4321}], #{}}},

        % {"<sip:1.2.3.4>",  {ok, [{udp, {1,2,3,4}, 0}], #{}}},
        % {"<sip:1.2.3.4:4321>",  {ok, [{udp, {1,2,3,4}, 4321}], #{}}},
        % {"<sips:1.2.3.4>",  {ok, [{tls, {1,2,3,4}, 0}], #{}}},
        % {"<sips:1.2.3.4:4321>",  {ok, [{tls, {1,2,3,4}, 4321}], #{}}},

        % {"<sip:127.0.0.1:1234>",  {ok, [{udp, {127,0,0,1}, 1234}], #{}}},
        % {"<sips:127.0.0.1:1234>",  {ok, [{tls, {127,0,0,1}, 1234}], #{}}},

        % {"<sip:anyhost>",  {naptr, sip, "anyhost"}},
        % {"<sips:anyhost>",  {naptr, sips, "anyhost"}}
    ],
    lists:foreach(
        fun({Uri, Result}) -> 
            [PUri] = nklib_parse:uris(Uri),
            Result = nkpacket:resolve(PUri, #{})
        end,
        Test).


resolv1() ->
    Naptr = [
        {sips, tls, "_sips._tcp.test1.local"},
        {sip, tcp, "_sip._tcp.test2.local"},
        {sip, tcp, "_sip._tcp.test3.local"},
        {sip, udp, "_sip._udp.test4.local"}
    ],
    save_cache({naptr, "test.local"}, Naptr),
    
    Srvs1 = [{1, 1, {"test100.local", 100}}],
    save_cache({srvs, "_sips._tcp.test1.local"}, Srvs1),
    
    Srvs2 = [{1, 1, {"test200.local", 200}}, 
             {2, 1, {"test201.local", 201}}, {2, 5, {"test202.local", 202}}, 
             {3, 1, {"test300.local", 300}}],
    save_cache({srvs, "_sip._tcp.test2.local"}, Srvs2),
    
    Srvs3 = [{1, 1, {"test400.local", 400}}],
    save_cache({srvs, "_sip._tcp.test3.local"}, Srvs3),
    Srvs4 = [{1, 1, {"test500.local", 500}}],
    save_cache({srvs, "_sip._udp.test4.local"}, Srvs4),

    save_cache({ips, "test100.local"}, [{1,1,100,1}, {1,1,100,2}]),
    save_cache({ips, "test200.local"}, [{1,1,200,1}]),
    save_cache({ips, "test201.local"}, [{1,1,201,1}]),
    save_cache({ips, "test202.local"}, [{1,1,202,1}]),
    save_cache({ips, "test300.local"}, [{1,1,300,1}]),
    save_cache({ips, "test400.local"}, []),
    save_cache({ips, "test500.local"}, [{1,1,500,1}]),

     %% Travis test machine returns two hosts...
    {ok, [{?MODULE, udp, {127,0,0,1}, 5060}|_]} = 
    	nkpacket:resolve(?MODULE, "sip:localhost"),
    {ok, [{?MODULE, tls, {127,0,0,1}, 5061}|_]} = 
    	nkpacket:resolve(?MODULE, "sips:localhost"),

    {ok, List1} = nkpacket:resolve(?MODULE, "sip:test.local"),
    [A, B, C, D, E, F, G] = [{E1, E2, E3} || {?MODULE, E1, E2, E3} <- List1],
    	
    true = (A=={tls, {1,1,100,1}, 100} orelse A=={tls, {1,1,100,2}, 100}),
    true = (B=={tls, {1,1,100,1}, 100} orelse B=={tls, {1,1,100,2}, 100}),
    true = A/=B,

    C = {tcp, {1,1,200,1}, 200},
    true = (D=={tcp, {1,1,201,1}, 201} orelse D=={tcp, {1,1,202,1}, 202}),
    true = (E=={tcp, {1,1,201,1}, 201} orelse E=={tcp, {1,1,202,1}, 202}),
    true = D/=E,

    F = {tcp, {1,1,300,1}, 300},
    G = {udp, {1,1,500,1}, 500},

    {ok, List2} = nkpacket:resolve(?MODULE, "sips:test.local"),
    [H, I] = [{E1, E2, E3} || {?MODULE, E1, E2, E3} <- List2],
    true = (H=={tls, {1,1,100,1}, 100} orelse H=={tls, {1,1,100,2}, 100}),
    true = (I=={tls, {1,1,100,1}, 100} orelse I=={tls, {1,1,100,2}, 100}),
    true = H/=I.


resolv2() ->
    ?debugMsg("Sending NAPTR query to sip2sip.info"),
    {ok, List1} = nkpacket:resolve(?MODULE, "sip:sip2sip.info"),
    case [{E1, E3} || {?MODULE, E1, _E2, E3} <- List1] of    
        [
            {tls, 443},
            {tls, 443},
            {tls, 443},
            {tcp, 5060},
            {tcp, 5060},
            {tcp, 5060},
            {udp, 5060},
            {udp, 5060},
            {udp, 5060}
        ] ->
            ok;
        _ ->
            ?debugMsg("NAPTR test failed!")
    end.




%% Protocol callbacks

transports(sip) -> [udp, tcp, tls, sctp, ws, wss];
transports(sips) -> [tls, wss].

default_port(udp) -> 5060;
default_port(tcp) -> 5060;
default_port(tls) -> 5061;
default_port(sctp) -> 5060;
default_port(ws) -> 80;
default_port(wss) -> 443;
default_port(_) -> invalid.


%% Util

save_cache(Key, Value) ->
    Now = nklib_util:timestamp(),
    true = ets:insert(nkpacket_dns, {Key, Value, Now+10}).



