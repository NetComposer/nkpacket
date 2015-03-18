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

%% @private NkPACKET Config Cache
%% (this module will be hot-reloaded with static values when integrated with NkCORE)

-module(nkpacket_config_cache).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).


% Global config

global_max_connections() -> nkpacket_config:get(global_max_connections).

local_data_path() -> nkpacket_config:get(local_data_path).

sync_call_time() -> nkpacket_config:get(sync_call_time). 

local_ips() -> nkpacket_config:get(local_ips).

main_ip() -> nkpacket_config:get(main_ip).

main_ip6() -> nkpacket_config:get(main_ip6).

get_prococol(Scheme) -> nkpacket_config:get_protocol(Scheme).


% Domain config

dns_cache_ttl(Domain) -> nkpacket_config:get_domain(Domain, dns_cache_ttl).

log_level(Domain) -> nkpacket_config:get_domain(Domain, log_level).

udp_timeout(Domain) -> nkpacket_config:get_domain(Domain, udp_timeout).

tcp_timeout(Domain) -> nkpacket_config:get_domain(Domain, tcp_timeout).

sctp_timeout(Domain) -> nkpacket_config:get_domain(Domain, sctp_timeout).

ws_timeout(Domain) -> nkpacket_config:get_domain(Domain, ws_timeout).

http_timeout(Domain) -> nkpacket_config:get_domain(Domain, http_timeout).

connect_timeout(Domain) -> nkpacket_config:get_domain(Domain, connect_timeout).

max_connections(Domain) -> nkpacket_config:get_domain(Domain, max_connections).

local_host(Domain) -> nkpacket_config:get_domain(Domain, local_host).

local_host6(Domain) -> nkpacket_config:get_domain(Domain, local_host6).

get_protocol(Domain, Scheme) -> nkpacket_config:get_protocol(Domain, Scheme).





