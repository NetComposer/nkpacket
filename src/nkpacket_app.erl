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
    put(default_certs, nkpacket_tls:defaults_certs()),
    Syntax = nkpacket_syntax:app_syntax(),
    case nklib_config:load_env(nkpacket, Syntax) of
        {ok, _} ->
            get_auto_ips(),
            nkpacket_config:set_config(),
            {ok, Pid} = nkpacket_sup:start_link(),
            {ok, Vsn} = application:get_key(nkpacket, vsn),
            lager:info("NkPACKET v~s has started.", [Vsn]),
            MainIp = nklib_util:to_host(nkpacket_app:get(main_ip)),
            MainIp6 = nklib_util:to_host(nkpacket_app:get(main_ip6)),
            ExtIp = nklib_util:to_host(nkpacket_app:get(ext_ip)),
            lager:info("Main IP is ~s (~s). External IP is ~s", 
                       [MainIp, MainIp6, ExtIp]),
            code:ensure_loaded(nkpacket_httpc_protocol),
            {ok, Pid};
        {error, Error} ->
            lager:error("Config error: ~p", [Error]),
            error(config_error)
    end.


%% @private OTP standard stop callback
stop(_) ->
    ok.



%% Config Management
get(Key) ->
    nklib_config:get(?APP, Key).

get(Key, Default) ->
    nklib_config:get(?APP, Key, Default).

get_srv(Class, Key) ->
    nklib_config:get_domain(?APP, Class, Key).

put(Key, Val) ->
    nklib_config:put(?APP, Key, Val).


%% @private
get_auto_ips() ->
    case nkpacket_app:get(main_ip) of
        auto -> 
            nkpacket_app:put(main_ip, nkpacket_util:find_main_ip());
        _ -> 
            ok
    end,
    case nkpacket_app:get(main_ip6) of
        auto -> 
            nkpacket_app:put(main_ip6, nkpacket_util:find_main_ip(auto, ipv6));
        _ -> 
            ok
    end,
    case nkpacket_app:get(ext_ip) of
        auto -> 
            ExtIp = nkpacket_stun:ext_ip(),
            nkpacket_app:put(ext_ip, ExtIp);
        _ ->
            ok
    end,
    case nkpacket_app:get(ext_ip6) of
        auto -> 
            nkpacket_app:put(ext_ip6, {0,0,0,0,0,0,0,1});
        _ ->
            ok
    end,
    put(local_ips, nkpacket_util:get_local_ips()).
