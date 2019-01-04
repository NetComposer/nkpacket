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

%% @doc Common library utility functions
-module(nkpacket_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').


-export([get_plugin_net_syntax/1, get_plugin_net_opts/1]).
-export([register_listener/1]).
-export([listen_print_all/0, conn_print_all/0]).
-export([get_local_ips/0, find_main_ip/0, find_main_ip/2]).
-export([get_local_uri/2, get_remote_uri/2, get_uri/4]).
-export([init_protocol/3, call_protocol/4]).
-export([norm_path/1, join_path/2, conn_string/3]).
-export([parse_opts/1, parse_uri_opts/2]).

-include("nkpacket.hrl").
-include_lib("nklib/include/nklib.hrl").


%% ===================================================================
%% Public
%% =================================================================

%% @doc
get_plugin_net_syntax(Syntax) ->
    S0 = maps:merge(
        nkpacket_syntax:tls_syntax(),
        nkpacket_syntax:packet_syntax()
    ),
    maps:merge(Syntax, S0).


get_plugin_net_opts(Config) ->
    Data = lists:filtermap(
        fun({Key, Val}) ->
            case nklib_util:to_binary(Key) of
                <<"packet_", Rest/binary>> ->
                    {true, {nklib_util:to_existing_atom(Rest), Val}};
                <<"tls_", _/binary>> ->
                    {true, {Key, Val}};
                _ ->
                    false
            end
        end,
        maps:to_list(Config)),
    maps:from_list(Data).


%% @private
register_listener(#nkport{id=Id, class=Class}) ->
    nklib_proc:put(nkpacket_listeners, {Id, Class}),
    nklib_proc:put({nkpacket_id, Id}, Class),
    ok.


listen_print_all() ->
    print_all(nkpacket:get_all()).


conn_print_all() ->
    print_all(nkpacket_connection:get_all()).


print_all([]) ->
    ok;
print_all([{_Id, _Class, Pid}|Rest]) ->
    {ok, #nkport{socket=Socket}=NkPort} = nkpacket:get_nkport(Pid),
    NkPort1 = case is_tuple(Socket) of true -> 
        NkPort#nkport{socket=element(1,Socket)}; 
        false -> NkPort
    end,
    {_, _, List} = lager:pr(NkPort1, ?MODULE),
    io:format("~p\n", [List]),
    print_all(Rest).




%%tls_keys() ->
%%    maps:keys(nkpacket_syntax:tls_syntax()).



%% @private It adds an 'id' field if not present
-spec parse_opts(map()|list()) ->
    {ok, map()} | {error, term()}.

parse_opts(Opts) ->
    Syntax = case Opts of
        #{parse_syntax:=UserSyntax} -> 
            maps:merge(UserSyntax, nkpacket_syntax:syntax());
        _ ->
            nkpacket_syntax:syntax()
    end,
    case nklib_syntax:parse(Opts, Syntax) of
        {ok, Map, _} ->
            case maps:is_key(id, Map) of
                true ->
                    {ok, Map};
                false ->
                    {ok, Map#{id=>nklib_util:uid()}}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec parse_uri_opts(map()|list(), #{parse_syntax=>map()}) ->
    {ok, map()} | {error, term()}.

parse_uri_opts(UriOpts, Opts) ->
    Base = maps:get(parse_syntax, Opts, #{}),
    Syntax = maps:merge(Base, nkpacket_syntax:safe_syntax()),
    case nklib_syntax:parse(UriOpts, Syntax) of
        {ok, Map, _} ->
            {ok, Map};
        {error, Error} ->
            {error, Error}
    end.


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
            TryFun = fun() -> Protocol:Fun(Arg) end,
            case nklib_util:do_try(TryFun) of
                {exception, {Class, {Reason, Stacktrace}}} ->
                    lager:error("Exception ~p (~p) calling ~p:~p(~p). Stack: ~p", 
                                [Class, Reason, Protocol, Fun, Arg, Stacktrace]),
                    erlang:Class([{reason, Reason}, {stacktrace, Stacktrace}]);
                Other ->
                    Other
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
            TryFun = fun() ->
                case apply(Protocol, Fun, Args++[ProtoState]) of
                    ok ->
                        {ok, State};
                    {Class, ProtoState1} when is_atom(Class) -> 
                        {Class, setelement(Pos+1, State, ProtoState1)};
                    {Class, Value, ProtoState1} when is_atom(Class) -> 
                        {Class, Value, setelement(Pos+1, State, ProtoState1)}
                end
            end,
            case nklib_util:do_try(TryFun) of
                {exception, {EClass, {Reason, Stacktrace}}} ->
                    lager:error("Exception ~p (~p) calling ~p:~p(~p). Stack: ~p", 
                                [EClass, Reason, Protocol, Fun, Args, Stacktrace]),
                    erlang:EClass([{reason, Reason}, {stacktrace, Stacktrace}]);
                Other ->
                    Other
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


%%%% @doc Removes the user part from a nkport()
%%-spec remove_user(nkpacket:nkport()) ->
%%    nkpacket:nkport().
%%
%%remove_user(#nkport{meta=#{user:=_}=Meta}=NkPort) ->
%%    NkPort#nkport{meta=maps:remove(user, Meta)};
%%
%%remove_user(NkPort) ->
%%    NkPort.


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


%% @doc
join_path(Base, Path) ->
    Base2 = nklib_util:to_binary(Base),
    Base3 = case byte_size(Base2) of
        BaseSize when BaseSize > 0 ->
            case binary:at(Base2, BaseSize-1) of
                $/ when BaseSize > 1 ->
                    binary:part(Base2, 0, BaseSize-1);
                _ when Base2 == <<"/">> ->
                    <<>>;
                _ ->
                    Base2
            end;
        0 ->
            <<>>
    end,
    Path2 = case nklib_util:to_binary(Path) of
        <<$/, Rest/binary>> ->
            Rest;
        BinPath ->
            BinPath
    end,
    <<Base3/binary, $/, Path2/binary>>.


%% @doc
conn_string(Transp, Ip, Port) ->
    <<
        (nklib_util:to_binary(Transp))/binary, ":",
        (nklib_util:to_host(Ip))/binary, ":",
        (nklib_util:to_binary(Port))/binary
    >>.








%% ===================================================================
%% Tests
%% =================================================================

  
%-define(TEST, true).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

path_test() ->
    <<"/">> = join_path("", ""),
    <<"/">> = join_path("/", ""),
    <<"/">> = join_path("", "/"),
    <<"/">> = join_path("/", "/"),
    <<"a/">> = join_path("a", ""),
    <<"a/">> = join_path("a/", ""),
    <<"a/">> = join_path("a", "/"),
    <<"a/">> = join_path("a/", "/"),
    <<"a/b">> = join_path("a", "b"),
    <<"a/b">> = join_path("a", "/b"),
    <<"/b">> = join_path("", "b"),
    <<"/b">> = join_path("", "/b"),
    ok.


 -endif.







