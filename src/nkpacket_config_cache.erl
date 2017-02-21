%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @private NkSIP Config Cache
%%
%%
%% This module is hot compiled in run-time, after NkPACKET application has started.
%% It maintains a number of functions to cache some parts of the configuration.
%%
%% This implementation is used if the compiled module is not used
%% (for example because of the rebar reloader)

%% See nkpacket_config

-module(nkpacket_config_cache).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile([export_all]).


max_connections() -> default(max_connections).
dns_cache_ttl() -> default(dns_cache_ttl).
udp_timeout() -> default(udp_timeout).
tcp_timeout() -> default(tcp_timeout).
sctp_timeout() -> default(sctp_timeout).
ws_timeout() -> default(ws_timeout).
http_timeout() -> default(http_timeout).
connect_timeout() -> default(connect_timeout).
sctp_in_streams() -> default(sctp_in_streams).
sctp_out_streams() -> default(sctp_out_streams).
main_ip() -> default(main_ip).
main_ip6() -> default(main_ip6).
ext_ip() -> default(ext_ip).
ext_ip6() -> default(ext_ip6).
local_ips() -> default(local_ips).


default(Key) ->
    nklib_config:get_domain(nkpacket, none, Key).

%% Would be true when hot compiled
hot_compiled() -> false.