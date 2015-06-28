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

-define(GLOBAL_GET(Term), nkpacket_config:get(Term)).
-define(DOMAIN_GET(Domain, Term), nkpacket_config:get_domain(Domain, Term)).


% Global config

global_max_connections() -> ?GLOBAL_GET(global_max_connections).

get_prococol(Scheme) -> nkpacket_config:get_protocol(Scheme).


% Domain config

dns_cache_ttl(Domain) -> ?DOMAIN_GET(Domain, dns_cache_ttl).

udp_timeout(Domain) -> ?DOMAIN_GET(Domain, udp_timeout).

tcp_timeout(Domain) -> ?DOMAIN_GET(Domain, tcp_timeout).

sctp_timeout(Domain) -> ?DOMAIN_GET(Domain, sctp_timeout).

ws_timeout(Domain) -> ?DOMAIN_GET(Domain, ws_timeout).

http_timeout(Domain) -> ?DOMAIN_GET(Domain, http_timeout).

connect_timeout(Domain) -> ?DOMAIN_GET(Domain, connect_timeout).

max_connections(Domain) -> ?DOMAIN_GET(Domain, max_connections).

get_protocol(Domain, Scheme) -> nkpacket_config:get_protocol(Domain, Scheme).





