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
-export([tls_opts/0, add_tls_opts/2]).
-export([init/0, make_cache/0]).

-compile({no_auto_import, [get/1, put/2]}).

-include("nkpacket.hrl").


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


%% @doc
get_protocol(Scheme) -> 
    get({protocol, Scheme}).


%% @doc
get_protocol(Group, Scheme) -> 
    get_group(Group, {protocol, Scheme}).


%% @doc (hot compile does not support maps in R17)
tls_opts() -> 
    get(tls_opts).


%% @doc Adds SSL options
-spec add_tls_opts(list(), map()) ->
    list().

add_tls_opts(Base, Opts) ->
    SSL1 = maps:get(tls_opts, Opts, #{}),
    SSL2 = maps:merge(get(tls_opts), SSL1),
    SSL3 = case SSL2 of
        #{verify:=true} -> SSL2#{verify=>verify_peer, fail_if_no_peer_cert=>true};
        #{verify:=fasle} -> maps:remove(verify, SSL2);
        _ -> SSL2
    end,
    Base ++ maps:to_list(SSL3).


%% ===================================================================
%% Internal
%% ===================================================================

get(Key) ->
    nklib_config:get(?MODULE, Key).

get(Key, Default) ->
    nklib_config:get(?MODULE, Key, Default).

get_group(Group, Key) ->
    nklib_config:get_domain(?MODULE, Group, Key).

put(Key, Val) ->
    nklib_config:put(?MODULE, Key, Val).


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
        packet_local_host => [{enum, [auto]}, host],
        packet_local_host6 => [{enum, [auto]}, host6],
        tls_opts => 
            #{
                certfile => string,
                keyfile => string,
                cacertfile => string,
                password => string,
                verify => boolean,
                depth => {integer, 0, 16}
            }
    }.



%% @private Default config values
-spec default_config() ->
    map().

default_config() ->
    #{
        max_connections =>  1024,
        dns_cache_ttl => 30000,                 % msecs
        udp_timeout => 30000,                   % 
        tcp_timeout => 180000,                  % 
        sctp_timeout => 180000,                 % 
        ws_timeout => 180000,                   % 
        http_timeout => 180000,                 % 
        connect_timeout => 30000,               %
        local_host => auto,
        local_host6 => auto
    }.


%% @private
-spec init() ->
    ok.

init() ->
    nklib_config:put(?MODULE, local_ips, nkpacket_util:get_local_ips()),
    nklib_config:put(?MODULE, main_ip, nkpacket_util:find_main_ip()),
    nklib_config:put(?MODULE, main_ip6, nkpacket_util:find_main_ip(auto, ipv6)),

    BaseSSL1 = case code:priv_dir(nkpacket) of
        PrivDir when is_list(PrivDir) ->
            #{
                certfile => filename:join(PrivDir, "cert.pem"),
                keyfile => filename:join(PrivDir, "key.pem")
            };
        _ ->
            #{}
    end,
    %% Avoid SSLv3
    BaseSSL2 = BaseSSL1#{versions => ['tlsv1.2', 'tlsv1.1', 'tlsv1']},
    case nklib_config:load_env(?MODULE, nkpacket, spec(), default_config()) of
        {ok, _} ->
            SSL1 = nklib_util:to_map(get(tls_opts, [])),
            SSL2 = maps:merge(BaseSSL2, SSL1),
            put(tls_opts, SSL2),
            register_protocol(http, nkpacket_protocol_http),
            register_protocol(https, nkpacket_protocol_http),
            make_cache(),
            ok;
        {error, Error} ->
            lager:error("Config error: ~p", [Error]),
            error(config_error)
    end.


make_cache() ->
    Keys = [local_ips, main_ip, main_ip6 | maps:keys(default_config())],
    nklib_config:make_cache(Keys, ?MODULE, none, nkpacket_config_cache, none).
