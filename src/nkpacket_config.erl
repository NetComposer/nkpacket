%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @private NkPACKET global config

-module(nkpacket_config).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([set_config/0]).
-export([max_connections/0, dns_cache_ttl/0, udp_timeout/0, tcp_timeout/0, sctp_timeout/0,
         ws_timeout/0, http_timeout/0, connect_timeout/0, sctp_in_streams/0, tos/0,
         sctp_out_streams/0, main_ip/0, main_ip6/0, ext_ip/0, ext_ip6/0, local_ips/0]).


-record(nkpacket_config, {
    max_connections :: integer(),
    dns_cache_ttl :: integer(),
    udp_timeout :: integer(),
    tcp_timeout :: integer(),
    sctp_timeout :: integer(),
    ws_timeout :: integer(),
    http_timeout :: integer(),
    connect_timeout :: integer(),
    sctp_in_streams :: integer(),
    sctp_out_streams :: integer(),
    tos :: integer(),
    main_ip :: inet:ip4_address(),
    main_ip6 :: inet:ip6_address(),
    ext_ip :: inet:ip4_address(),
    ext_ip6 :: inet:ip6_address(),
    local_ips :: [inet:ip4_address()|inet:ip6_address()]
}).


set_config() ->
   Config = #nkpacket_config{
        max_connections = nkpacket_app:get(max_connections),
        dns_cache_ttl = nkpacket_app:get(dns_cache_ttl),
        udp_timeout = nkpacket_app:get(udp_timeout),
        tcp_timeout = nkpacket_app:get(tcp_timeout),
        sctp_timeout = nkpacket_app:get(sctp_timeout),
        ws_timeout = nkpacket_app:get(ws_timeout),
        http_timeout = nkpacket_app:get(http_timeout),
        connect_timeout = nkpacket_app:get(connect_timeout),
        sctp_in_streams = nkpacket_app:get(sctp_in_streams),
        sctp_out_streams = nkpacket_app:get(sctp_out_streams),
        tos = nkpacket_app:get(tos),
        main_ip = nkpacket_app:get(main_ip),
        main_ip6 = nkpacket_app:get(main_ip6),
        ext_ip = nkpacket_app:get(ext_ip),
        ext_ip6 = nkpacket_app:get(ext_ip6),
        local_ips = nkpacket_app:get(local_ips)
    },
    nklib_util:do_config_put(?MODULE, Config).



max_connections() -> do_get_config(#nkpacket_config.max_connections).
dns_cache_ttl() -> do_get_config(#nkpacket_config.dns_cache_ttl).
udp_timeout() -> do_get_config(#nkpacket_config.udp_timeout).
tcp_timeout() -> do_get_config(#nkpacket_config.tcp_timeout).
sctp_timeout() -> do_get_config(#nkpacket_config.sctp_timeout).
ws_timeout() -> do_get_config(#nkpacket_config.ws_timeout).
http_timeout() -> do_get_config(#nkpacket_config.http_timeout).
connect_timeout() -> do_get_config(#nkpacket_config.connect_timeout).
sctp_in_streams() -> do_get_config(#nkpacket_config.sctp_in_streams).
sctp_out_streams() -> do_get_config(#nkpacket_config.sctp_out_streams).
tos() -> do_get_config(#nkpacket_config.tos).
main_ip() -> do_get_config(#nkpacket_config.main_ip).
main_ip6() -> do_get_config(#nkpacket_config.main_ip6).
ext_ip() -> do_get_config(#nkpacket_config.ext_ip).
ext_ip6() -> do_get_config(#nkpacket_config.ext_ip6).
local_ips() -> do_get_config(#nkpacket_config.local_ips).


do_get_config(Key) ->
    element(Key, nklib_util:do_config_get(?MODULE)).


