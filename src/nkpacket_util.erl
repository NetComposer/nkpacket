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

-export([get_local_ips/0, find_main_ip/0, find_main_ip/2]).
-export([call_protocol/4]).


%% ===================================================================
%% Public
%% =================================================================


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
-spec call_protocol(atom(), list(), tuple(), integer()) ->
    {ok, tuple()} | {atom(), term(), tuple()}.

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
            {ok, State};
        false ->
            {ok, State};
        true ->
            case apply(Protocol, Fun, Args++[ProtoState]) of
                ok ->
                    {ok, State};
                {ok, ProtoState1} -> 
                    {ok, setelement(Pos+1, State, ProtoState1)};
                {Class, Value, ProtoState1} when is_atom(Class) -> 
                    {Class, Value, setelement(Pos+1, State, ProtoState1)}
            end
    end.




% %% @doc Splits a `string()' or `binary()' into a list of tokens
% -spec tokens(string() | binary()) ->
%     [string()] | error.

% tokens(Bin) when is_binary(Bin) ->
%     tokens(binary_to_list(Bin));

% tokens(List) when is_list(List) ->
%     tokens(List, [], []);

% tokens(_) ->
%     error.


% tokens([], [], Tokens) ->
%     lists:reverse(Tokens);

% tokens([], Chs, Tokens) ->
%     lists:reverse([lists:reverse(Chs)|Tokens]);

% tokens([Ch|Rest], Chs, Tokens) when Ch==32; Ch==9; Ch==13; Ch==10 ->
%     case Chs of
%         [] -> tokens(Rest, [], Tokens);
%         _ -> tokens(Rest, [], [lists:reverse(Chs)|Tokens])
%     end;

% tokens([Ch|Rest], Chs, Tokens) ->
%     tokens(Rest, [Ch|Chs], Tokens).


