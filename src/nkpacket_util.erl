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

-export([log_level/1, get_local_ips/0, find_main_ip/0, find_main_ip/2]).
-export([get_local_uri/2, get_remote_uri/2]).
-export([init_protocol/3, call_protocol/4]).
-export([parse_paths/1, check_paths/2]).
-export([parse_opts/1]).

-include("nkpacket.hrl").
-include_lib("nklib/include/nklib.hrl").


%% ===================================================================
%% Public
%% =================================================================


%% @doc Changes log level for console
-spec log_level(debug|info|notice|warning|error) ->
    ok.

log_level(Level) -> 
    lager:set_loglevel(lager_console_backend, Level).


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
            Protocol:Fun(Arg)
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
            case apply(Protocol, Fun, Args++[ProtoState]) of
                ok ->
                    {ok, State};
                {Class, ProtoState1} when is_atom(Class) -> 
                    {Class, setelement(Pos+1, State, ProtoState1)};
                {Class, Value, ProtoState1} when is_atom(Class) -> 
                    {Class, Value, setelement(Pos+1, State, ProtoState1)}
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


%% @private
-spec parse_paths([binary()]) ->
    [[binary()]].

parse_paths(List) ->
    parse_paths(List, []).


%% @private
parse_paths([], Acc) ->
    Acc;

parse_paths([Spec|Rest], Acc) ->
    [<<>>|Parts] = binary:split(Spec, <<"/">>, [global]),
    parse_paths(Rest, [Parts|Acc]).

%% @private
check_paths(_ReqPath, []) ->
    true;

check_paths(ReqPath, Paths) ->
    case binary:split(ReqPath, <<"/">>, [global]) of
        [<<>>, <<>>] -> check_paths1([<<>>], Paths);
        [<<>>|ReqParts] -> check_paths1(ReqParts, Paths);
        _ -> false
    end.


%% @private
check_paths1(_, []) ->
    false;

check_paths1(Parts, [FirstPath|Rest]) ->
    case check_paths2(Parts, FirstPath) of
        true -> true;
        false -> check_paths1(Parts, Rest)
    end.


%% @private
check_paths2([Common|Rest1], [Common|Rest2]) -> 
    check_paths2(Rest1, Rest2);

check_paths2(_Parts, Paths) -> 
    Paths==[].

  
%% ===================================================================
%% Options Parser
%% =================================================================

%% @private
-spec parse_opts(map()|list()) ->
    {ok, map()} | {error, term()}.

parse_opts(Map) when is_map(Map) ->
    parse_opts(maps:to_list(Map), #{});

parse_opts(List) when is_list(List) ->
    parse_opts(List, #{}).


%% @private
parse_opts([], Acc) -> 
    {ok, Acc};

parse_opts([{Key, Val}|Rest], Acc) -> 
    Key1 = if
        is_atom(Key) -> 
            Key;
        is_list(Key) ->
            case catch list_to_existing_atom(Key) of
                Atom when is_atom(Atom) -> Atom;
                _ -> Key
            end;
        is_binary(Key) ->
            case catch binary_to_existing_atom(Key, latin1) of
                Atom when is_atom(Atom) -> Atom;
                _ -> Key
            end;
        true ->
            error
    end,
    Res = case Key1 of
        transport ->
            ignore;
        error ->
            error;

        user ->
            {ok, Val};
        supervisor ->
            parse_pid(Val);
        monitor ->
            parse_pid(Val);
        idle_timeout ->
            parse_integer(Val);
        refresh_fun ->
            case is_function(Val, 1) of
                true -> {ok, Val};
                false -> error
            end;
        udp_starts_tcp ->
            parse_boolean(Val);
        udp_no_connections ->
            parse_boolean(Val);
        udp_stun_reply ->
            parse_boolean(Val);
        udp_stun_t1 ->
            parse_integer(Val);
        sctp_out_streams ->
            parse_integer(Val);
        sctp_in_streams ->
            parse_integer(Val);
        certfile ->
            {ok, nklib_util:to_list(Val)};
        keyfile ->
            {ok, nklib_util:to_list(Val)};
        tcp_packet ->
            case nklib_util:to_integer(Val) of
                Int when Int==1; Int==2; Int==4 -> 
                    {ok, Int};
                _ -> 
                    case nklib_util:to_lower(Val) of 
                        <<"raw">> -> {ok, raw}; 
                        _-> error 
                    end
            end;        
        tcp_max_connections ->
            parse_integer(Val);
        tcp_listeners ->
            parse_integer(Val);
        host ->
            case parse_tokens(Val) of
                {ok, HostList} -> {ok, host_list, HostList};
                error -> error
            end;
        path ->
            case parse_path(Val) of
                {ok, PathList} -> {ok, path_list, PathList};
                error -> error
            end;
        cowboy_opts ->
            parse_list(Val);
        ws_proto ->
            {ok, nklib_util:to_lower(Val)};
        web_proto ->
            case Val of
                {static, #{path:=_}} -> {ok, Val};
                {dispatch, #{routes:=_}} -> {ok, Val};
                {custom, #{env:=_, middlewares:=_}} -> {ok, Val};
                _ -> error
            end;
        connect_timeout ->
            parse_integer(Val);
        listen_ip ->
            case nklib_util:to_ip(Val) of
                {ok, Ip} -> {ok, Ip};
                _ -> error
            end;
        listen_port ->
            parse_integer(Val);
        force_new ->
            parse_boolean(Val);
        udp_to_tcp ->
            parse_boolean(Val);
        _ ->
            error
    end,
    case Res of
        {ok, Val1} -> 
            parse_opts(Rest, maps:put(Key1, Val1, Acc));
        {ok, NewKey, Val1} -> 
            parse_opts(Rest, maps:put(NewKey, Val1, Acc));
        ignore ->
            parse_opts(Rest, Acc);
        error ->
            {error, {invalid_option, Key}}
    end;

parse_opts([Term|Rest], Acc) -> 
    parse_opts([{Term, true}|Rest], Acc).


%% @private
parse_pid(Value) when is_atom(Value); is_pid(Value) -> 
    {ok, Value};
parse_pid(_) ->
    error.


%% @private
parse_integer(Value) ->
    case nklib_util:to_integer(Value) of
        Int when is_integer(Int), Int >= 0 -> {ok, Int};
        _ -> error
    end.


%% @private
parse_boolean(Value) ->
    case nklib_util:to_boolean(Value) of
        Bool when is_boolean(Bool) -> {ok, Bool};
        _ -> error
    end.


%% @private
parse_list(Value) when is_list(Value) -> 
    {ok, Value};
parse_list(_) ->
    error.

%% @private
parse_tokens(Value) ->
    case nklib_parse:unquote(Value) of
        error -> 
            error;
        Bin -> 
            case nklib_parse:tokens(Bin) of
                error ->
                    error;
                Tokens ->
                    {ok, [Term || {Term, _} <- Tokens]}
            end
    end.

  
%% @private
parse_path(Value) ->
    case parse_tokens(Value) of
        {ok, Terms} -> 
            {ok, [nklib_parse:path(Path) || Path <- Terms]};
        error -> 
            error
    end.



%% ===================================================================
%% Tests
%% =================================================================

  

% -define(TEST, true).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

path_test() ->
    ?debugMsg("HTTP path test"),
    true = test_path("/a/b/c", ""),
    true = test_path("/", "/"),
    false = test_path("/", "/a"),
    true = test_path("/", "/a, bc, /"),
    true = test_path("/a/b/c", "a"),
    false = test_path("/a/b/c", "b"),
    true = test_path("/a/b/c", "b, a/b/c"),
    true = test_path("/a/b/c", "b, /a/b"),
    false = test_path("/a/b/c", "b,a/b/c/d"),
    true = test_path("/a/b/c", "b, a/b/c/d, /a/b/c"),
    ok.


test_path(Req, Path) ->
    {ok, PathList} = parse_path(Path),
    PathList1 = parse_paths(PathList),
    check_paths(list_to_binary(Req), PathList1).

-endif.







