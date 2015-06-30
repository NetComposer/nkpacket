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
-export([get_local_ips/0, max_connections/0, dns_cache_ttl/0]).
-export([udp_timeout/0, tcp_timeout/0, sctp_timeout/0, ws_timeout/0, http_timeout/0, 
         connect_timeout/0, certfile/0, keyfile/0]).
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


%% doc Registers a new protocol for an specific group
-spec register_protocol(nkpacket:group(), nklib:scheme(), nkpacket:protocol()) ->
    ok.

register_protocol(Group, Scheme, Protocol) when is_atom(Scheme), is_atom(Protocol) ->
    {module, _} = code:ensure_loaded(Protocol),
    nklib_config:put_domain(?MODULE, Group, {protocol, Scheme}, Protocol).


get_protocol(Scheme) -> get({protocol, Scheme}).
get_protocol(Group, Scheme) -> get_group(Group, {protocol, Scheme}).
get_local_ips() -> get(local_ips).
dns_cache_ttl() -> get(dns_cache_ttl).
max_connections() -> get(max_connections).
udp_timeout() -> get(udp_timeout).
tcp_timeout() -> get(tcp_timeout).
sctp_timeout() -> get(sctp_timeout).
ws_timeout() -> get(ws_timeout).
http_timeout() -> get(http_timeout).
connect_timeout() -> get(connect_timeout).
certfile() -> get(certfile).
keyfile() -> get(keyfile).


%% ===================================================================
%% Internal
%% ===================================================================

get(Key) ->
    nklib_config:get(?MODULE, Key).

get_group(Group, Key) ->
    nklib_config:get_domain(?MODULE, Group, Key).



spec() ->
    #{
        max_connections => {integer, 1, 1000000},
        dns_cache_ttl => {integer, 0, none},
        udp_timeout => nat_integer,
        tcp_timeout => nat_integer,
        sctp_timeout => nat_integer,
        ws_timeout => nat_integer,
        http_timeout => nat_integer,
        connect_timeout => nat_integer,
        certfile => string,
        keyfile => string
    }.



%% @private Default config values
-spec default_config() ->
    nklib:optslist().

default_config() ->
    [
        {max_connections, 1024},
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
    case code:priv_dir(nkpacket) of
        PrivDir when is_list(PrivDir) ->
            DefCert = filename:join(PrivDir, "cert.pem"),
            DefKey = filename:join(PrivDir, "key.pem");
        _ ->
            DefCert = "",
            DefKey = ""
    end,
    nklib_config:put(?MODULE, certfile, DefCert),
    nklib_config:put(?MODULE, keyfile, DefKey),
    case nklib_config:load_env(?MODULE, nkpacket, default_config(), spec()) of
        ok ->
            register_protocol(http, nkpacket_protocol_http),
            register_protocol(https, nkpacket_protocol_http),
            ok;
        {error, Error} ->
            lager:error("Config error: ~p", [Error]),
            error(config_error)
    end.

