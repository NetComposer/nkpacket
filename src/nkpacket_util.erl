%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc Common library utility funcions
-module(nkpacket_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([console_loglevel/1, make_web_proto/1]).
-export([make_cache/0, make_tls_opts/1, tls_keys/0]).
-export([debug/0, info/0, notice/0, warning/0, error/0]).
-export([get_local_ips/0, find_main_ip/0, find_main_ip/2]).
-export([get_local_uri/2, get_remote_uri/2, remove_user/1]).
-export([init_protocol/3, call_protocol/4]).
-export([norm_path/1]).
-export([parse_opts/1, parse_uri_opts/1]).

-include("nkpacket.hrl").
-include_lib("nklib/include/nklib.hrl").


%% ===================================================================
%% Public
%% =================================================================


%% @doc Changes log level for console
debug() -> console_loglevel(debug).
info() -> console_loglevel(info).
notice() -> console_loglevel(notice).
warning() -> console_loglevel(warning).
error() -> console_loglevel(error).


%% @doc Changes log level for console
-spec console_loglevel(debug|info|notice|warning|error) ->
    ok.

console_loglevel(Level) -> 
    lager:set_loglevel(lager_console_backend, Level).


%% @doc Adds SSL options
-spec make_tls_opts(list()|map()) ->
    list().

make_tls_opts(Opts) ->
    Opts1 = nklib_util:filtermap(
        fun(Term) ->
            case Term of
                {tls_certfile, Val} -> {true, {certfile, Val}};
                {tls_keyfile, Val} -> {true, {keyfile, Val}};
                {tls_cacertfile, Val} -> {true, {cacertfile, Val}};
                {tls_password, Val} -> {true, {password, Val}};
                {tls_verify, Val} -> {true, {verify, Val}};
                {tls_depth, Val} -> {true, {depth, Val}};
                {tls_versions, Val} -> {true, {versions, Val}};
                _ -> false
            end
        end,
        nklib_util:to_list(Opts)),
    Opts2 = maps:merge(nkpacket_app:get(tls_defaults), maps:from_list(Opts1)),
    Opts3 = case Opts2 of
        #{verify:=true} -> Opts2#{verify=>verify_peer, fail_if_no_peer_cert=>true};
        #{verify:=false} -> maps:remove(verify, Opts2);
        _ -> Opts2
    end,
    maps:to_list(Opts3).


tls_keys() ->
    maps:keys(#{?TLS_SYNTAX}).

%% @private
-spec make_web_proto(nkpacket:listener_opts()) ->
    nkpacket:http_proto().

make_web_proto(#{http_proto:={static, #{path:=DirPath}=Static}}=Opts) ->
    DirPath1 = nklib_parse:fullpath(filename:absname(DirPath)),
    Static1 = Static#{path:=DirPath1},
    UrlPath = maps:get(path, Opts, <<>>),
    Route = {<<UrlPath/binary, "/[...]">>, nkpacket_cowboy_static, Static1},
    {custom, 
        #{
            env => [{dispatch, cowboy_router:compile([{'_', [Route]}])}],
            middlewares => [cowboy_router, cowboy_handler]
        }};

make_web_proto(#{http_proto:={dispatch, #{routes:=Routes}}}) ->
    {custom, 
        #{
            env => [{dispatch, cowboy_router:compile(Routes)}],
            middlewares => [cowboy_router, cowboy_handler]
        }};

make_web_proto(#{http_proto:={custom, #{env:=Env, middlewares:=Mods}}=Proto})
    when is_list(Env), is_list(Mods) ->
    Proto;

make_web_proto(O) ->
    error(O).


%% @private
-spec parse_opts(map()|list()) ->
    {ok, map()} | {error, term()}.

parse_opts(Opts) ->
    Syntax = nkpacket_syntax:syntax(),
    case nklib_config:parse_config(Opts, Syntax, #{return=>map}) of
        {ok, Map, _} ->
            {ok, Map};
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec parse_uri_opts(map()|list()) ->
    {ok, map()} | {error, term()}.

parse_uri_opts(Opts) ->
    Syntax = nkpacket_syntax:uri_syntax(),
    case nklib_config:parse_config(Opts, Syntax, #{return=>map}) of
        {ok, Map, _} ->
            {ok, Map};
        {error, Error} ->
            {error, Error}
    end.


%% @private
make_cache() ->
    Defaults = nkpacket_syntax:app_defaults(),
    Keys = [local_ips, main_ip, main_ip6 | maps:keys(Defaults)],
    nklib_config:make_cache(Keys, nkpacket, none, nkpacket_config_cache, none).



%% @doc Get all local network ips.
-spec get_local_ips() -> 
    [inet:ip_address()].

get_local_ips() ->
    {ok, All} = inet:getifaddrs(),
    lists:flatten([proplists:get_all_values(addr, Data) || {_, Data} <- All]).


%% @doc Equivalent to `find_main_ip(auto, ipv4)'.
-spec find_main_ip() -> 
    inet:ip_address().

find_main_ip() ->
    find_main_ip(auto, ipv4).


%% @doc Finds the <i>best</i> local IP.
%% If a network interface is supplied (as "en0") it returns its ip.
%% If `auto' is used, probes `ethX' and `enX' interfaces. If none is available returns 
%% localhost
-spec find_main_ip(auto|string(), ipv4|ipv6) -> 
    inet:ip_address().

find_main_ip(NetInterface, Type) ->
    {ok, All} = inet:getifaddrs(),
    case NetInterface of
        auto ->
            IFaces = lists:filter(
                fun(Name) ->
                    case Name of
                        "eth" ++ _ -> true;
                        "en" ++ _ -> true;
                        _ -> false
                    end
                end,
                proplists:get_keys(All)),
            find_main_ip(lists:sort(IFaces), All, Type);
        _ ->
            find_main_ip([NetInterface], All, Type)   
    end.


%% @private
find_main_ip([], _, ipv4) ->
    {127,0,0,1};

find_main_ip([], _, ipv6) ->
    {0,0,0,0,0,0,0,1};

find_main_ip([IFace|R], All, Type) ->
    Data = nklib_util:get_value(IFace, All, []),
    Flags = nklib_util:get_value(flags, Data, []),
    case lists:member(up, Flags) andalso lists:member(running, Flags) of
        true ->
            Addrs = lists:zip(
                proplists:get_all_values(addr, Data),
                proplists:get_all_values(netmask, Data)),
            case find_real_ip(Addrs, Type) of
                error -> find_main_ip(R, All, Type);
                Ip -> Ip
            end;
        false ->
            find_main_ip(R, All, Type)
    end.

%% @private
find_real_ip([], _Type) ->
    error;

% Skip link-local addresses
find_real_ip([{{65152,_,_,_,_,_,_,_}, _Netmask}|R], Type) ->
    find_real_ip(R, Type);

find_real_ip([{{A,B,C,D}, Netmask}|_], ipv4) 
             when Netmask /= {255,255,255,255} ->
    {A,B,C,D};

find_real_ip([{{A,B,C,D,E,F,G,H}, Netmask}|_], ipv6) 
             when Netmask /= {65535,65535,65535,65535,65535,65535,65535,65535} ->
    {A,B,C,D,E,F,G,H};

find_real_ip([_|R], Type) ->
    find_real_ip(R, Type).


%% @private
-spec init_protocol(nkpacket:protocol(), atom(), term()) ->
    {ok, undefined} | term().

init_protocol(Protocol, Fun, Arg) ->
    case 
        Protocol/=undefined andalso 
        erlang:function_exported(Protocol, Fun, 1) 
    of
        false -> 
            {ok, undefined};
        true -> 
            try 
                Protocol:Fun(Arg)
            catch
                Class:Reason ->
                    Stacktrace = erlang:get_stacktrace(),
                    lager:error("Exception ~p (~p) calling ~p:~p(~p). Stack: ~p", 
                                [Class, Reason, Protocol, Fun, Arg, Stacktrace]),
                    erlang:Class([{reason, Reason}, {stacktrace, Stacktrace}])
            end
    end.


%% @private
-spec call_protocol(atom(), list(), tuple(), integer()) ->
    {atom(), tuple()} | {atom(), term(), tuple()} | undefined.

call_protocol(Fun, Args, State, Pos) ->
    Protocol = element(Pos, State),
    ProtoState = element(Pos+1, State),
    case         
        Protocol/=undefined andalso 
        erlang:function_exported(Protocol, Fun, length(Args)+1) 
    of

        false when Fun==conn_handle_call; Fun==conn_handle_cast; 
                   Fun==conn_handle_info; Fun==listen_handle_call; 
                   Fun==listen_handle_cast; Fun==listen_handle_info ->
            lager:error("Module ~p received unexpected ~p: ~p", [?MODULE, Fun, Args]),
            undefined;
        false ->
            undefined;
        true ->
            try apply(Protocol, Fun, Args++[ProtoState]) of
                ok ->
                    {ok, State};
                {Class, ProtoState1} when is_atom(Class) -> 
                    {Class, setelement(Pos+1, State, ProtoState1)};
                {Class, Value, ProtoState1} when is_atom(Class) -> 
                    {Class, Value, setelement(Pos+1, State, ProtoState1)}
            catch
                Class:Reason ->
                    Stacktrace = erlang:get_stacktrace(),
                    lager:error("Exception ~p (~p) calling ~p:~p(~p). Stack: ~p", 
                                [Class, Reason, Protocol, Fun, Args, Stacktrace]),
                    erlang:Class([{reason, Reason}, {stacktrace, Stacktrace}])
            end
    end.


%% @doc Gets a binary represtation of an uri based on local address
-spec get_local_uri(term(), nkpacket:nkport()) ->
    binary().

get_local_uri(Scheme, #nkport{transp=Transp, local_ip=Ip, local_port=Port}) ->
    get_uri(Scheme, Transp, Ip, Port).


%% @doc Gets a binary represtation of an uri based on remote address
-spec get_remote_uri(term(), nkpacket:nkport()) ->
    binary().

get_remote_uri(Scheme, #nkport{transp=Transp, remote_ip=Ip, remote_port=Port}) ->
    get_uri(Scheme, Transp, Ip, Port).

    
%% @private
get_uri(Scheme, Transp, Ip, Port) ->
    list_to_binary([
        "<", nklib_util:to_binary(Scheme), "://", nklib_util:to_host(Ip), ":", 
        nklib_util:to_binary(Port), ";transport=", nklib_util:to_binary(Transp), ">"
    ]).

%% @doc Removes the user part from a nkport()
-spec remove_user(nkpacket:nkport()) ->
    nkpacket:nkport().

remove_user(#nkport{meta=#{user:=_}=Meta}=NkPort) ->
    NkPort#nkport{meta=maps:remove(user, Meta)};

remove_user(NkPort) ->
    NkPort.


%% @private
norm_path(any) ->
    [];

norm_path(<<>>) ->
    [];

norm_path(<<"/">>) ->
    [];

norm_path(Path) when is_binary(Path) ->
    case binary:split(nklib_util:to_binary(Path), <<"/">>, [global]) of
        [<<>> | Rest] -> Rest;
        Other -> Other
    end;

norm_path(Other) ->
    norm_path(nklib_util:to_binary(Other)).




%% ===================================================================
%% Tests
%% =================================================================

  
% % -define(TEST, true).
% -ifdef(TEST).
% -include_lib("eunit/include/eunit.hrl").

% path_test() ->
%     ?debugMsg("HTTP path test"),
%     true = test_path("/a/b/c", "/"),
%     true = test_path("/", "/"),
%     false = test_path("/", "/a"),
%     true = test_path("/a/b/c", "a"),
%     false = test_path("/a/b/c", "b"),
%     true = test_path("/a/b/c", "a/b/c"),
%     true = test_path("/a/b/c", "a/b/c/"),
%     true = test_path("/a/b/c", "/a/b/"),
%     false = test_path("/a/b/c", "a/b/c/d"),
%     ok.


% test_path(Req, Path) ->
%     check_paths(nklib_parse:path(Req), nklib_parse:path(Path)).


% -endif.







