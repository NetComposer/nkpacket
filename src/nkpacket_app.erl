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

%% @doc NkPACKET OTP Application Module
-module(nkpacket_app).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(application).

-export([start/0, start/2, stop/1]).
-export([get/1, get/2, get_srv/2, put/2]).

-include("nkpacket.hrl").

-define(APP, nkpacket).
-compile({no_auto_import, [get/1, put/2]}).

%% ===================================================================
%% Private
%% ===================================================================

%% @doc Starts NkPACKET stand alone.
-spec start() -> 
    ok | {error, Reason::term()}.

start() ->
    case nklib_util:ensure_all_started(?APP, permanent) of
        {ok, _Started} ->
            ok;
        Error ->
            Error
    end.

%% @private OTP standard start callback
start(_Type, _Args) ->
    put(local_ips, nkpacket_util:get_local_ips()),
    put(main_ip, nkpacket_util:find_main_ip()),
    put(main_ip6, nkpacket_util:find_main_ip(auto, ipv6)),
    put(tls_defaults, nkpacket_syntax:tls_defaults()),
    Syntax = nkpacket_syntax:app_syntax(),
    Defaults = nkpacket_syntax:app_defaults(),
    case nklib_config:load_env(nkpacket, Syntax, Defaults) of
        {ok, _} ->
            nkpacket:register_protocol(http, nkpacket_protocol_http),
            nkpacket:register_protocol(https, nkpacket_protocol_http),
            nkpacket_util:make_cache(),
            {ok, Pid} = nkpacket_sup:start_link(),
            {ok, Vsn} = application:get_key(nkpacket, vsn),
            lager:notice("NkPACKET v~s has started.", [Vsn]),
            {ok, Pid};
        {error, Error} ->
            lager:error("Config error: ~p", [Error]),
            error(config_error)
    end.




%% @private OTP standard stop callback
stop(_) ->
    ok.



get(Key) ->
    nklib_config:get(nkpacket, Key).

get(Key, Default) ->
    nklib_config:get(nkpacket, Key, Default).

get_srv(SrvId, Key) ->
    nklib_config:get_domain(nkpacket, SrvId, Key).

put(Key, Val) ->
    nklib_config:put(nkpacket, Key, Val).


