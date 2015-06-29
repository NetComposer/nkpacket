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

%% @doc NkPACKET Config Server.
-module(nkpacket_config).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([register_protocol/2, register_protocol/3]).
-export([get_protocol/1, get_protocol/2]).
-export([get_local_ips/0, global_max_connections/0, max_connections/1]).
-export([dns_cache_ttl/1, udp_timeout/1, tcp_timeout/1, sctp_timeout/1, 
         ws_timeout/1, http_timeout/1, connect_timeout/1]).
-export([init/0]).

-compile({no_auto_import, [get/1, put/2]}).

-include("nkpacket.hrl").

-define(GLOBAL_GET(Term), nklib_config:get(?MODULE, Term)).
-define(DOMAIN_GET(Domain, Term), nklib_config:get_domain(?MODULE, Domain, Term)).



%% ===================================================================
%% Public
%% ===================================================================


%% doc Registers a new 'default' protocol
-spec register_protocol(nklib:scheme(), nkpacket:protocol()) ->
    ok.

register_protocol(Scheme, Protocol) when is_atom(Scheme), is_atom(Protocol) ->
    {module, _} = code:ensure_loaded(Protocol),
    nklib_config:put(?MODULE, {protocol, Scheme}, Protocol).


%% doc Registers a new protocol for an specific domain
-spec register_protocol(nkpacket:domain(), nklib:scheme(), nkpacket:protocol()) ->
    ok.

register_protocol(Domain, Scheme, Protocol) when is_atom(Scheme), is_atom(Protocol) ->
    {module, _} = code:ensure_loaded(Protocol),
    nklib_config:put_domain(?MODULE, Domain, {protocol, Scheme}, Protocol).


% Global config
get_protocol(Scheme) -> ?GLOBAL_GET({protocol, Scheme}).
get_protocol(Domain, Scheme) -> ?DOMAIN_GET(Domain, {protocol, Scheme}).
get_local_ips() -> ?GLOBAL_GET(local_ips).
global_max_connections() -> ?GLOBAL_GET(global_max_connections).


% Domain config
max_connections(Domain) -> ?DOMAIN_GET(Domain, max_connections).
dns_cache_ttl(Domain) -> ?DOMAIN_GET(Domain, dns_cache_ttl).
udp_timeout(Domain) -> ?DOMAIN_GET(Domain, udp_timeout).
tcp_timeout(Domain) -> ?DOMAIN_GET(Domain, tcp_timeout).
sctp_timeout(Domain) -> ?DOMAIN_GET(Domain, sctp_timeout).
ws_timeout(Domain) -> ?DOMAIN_GET(Domain, ws_timeout).
http_timeout(Domain) -> ?DOMAIN_GET(Domain, http_timeout).
connect_timeout(Domain) -> ?DOMAIN_GET(Domain, connect_timeout).



%% ===================================================================
%% Internal
%% ===================================================================

spec() ->
    #{
        global_max_connections => {integer, 1, 1000000},
        max_connections => {integer, 1, 1000000},
        dns_cache_ttl => {integer, 0, none},
        udp_timeout => {integer, 1, none},
        tcp_timeout => {integer, 1, none},
        sctp_timeout => {integer, 1, none},
        ws_timeout => {integer, 1, none},
        http_timeout => {integer, 1, none},
        connect_timeout => {integer, 1, none},
        certfile => string,
        keyfile => string,
        local_host => [{enum, [auto]}, host],
        local_host6 => [{enum, [auto]}, host6]
    }.



%% @private Default config values
-spec default_config() ->
    nklib:optslist().

default_config() ->
    [
        {global_max_connections, 1024},
        {max_connections, 1024},                % Per transport and Domain
        {dns_cache_ttl, 30000},                 % msecs
        {udp_timeout, 30000},                   % 
        {tcp_timeout, 180000},                  % 
        {sctp_timeout, 180000},                 % 
        {ws_timeout, 180000},                   % 
        {http_timeout, 180000},                 % 
        {connect_timeout, 30000}                %
    ].


%% @private
-spec init() ->
    ok.

init() ->
    nklib_config:put(?MODULE, local_ips, nkpacket_util:get_local_ips()),
    case nklib_config:load_env(?MODULE, nkpacket, default_config(), spec()) of
        ok ->
            register_protocol(http, nkpacket_protocol_http),
            register_protocol(https, nkpacket_protocol_http),
            ok;
        {error, Error} ->
            lager:error("Config error: ~p", [Error]),
            error(config_error)
    end.

