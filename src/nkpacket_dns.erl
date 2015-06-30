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

%% @doc NkPACKET DNS cache and utilities with RFC3263 support, including NAPTR and SRV
-module(nkpacket_dns).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([resolve/1, resolve/2, resolve_uri/2]).
-export([get_ips/2, get_srvs/2, get_naptr/2, clear/1, clear/0]).
-export([start_link/0, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).

-define(CHECK_INTERVAL, 60).     % secs

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").

-type opts() :: 
    #{
        no_dns_cache => boolean()
    }.

-type uri_transp() :: nkpacket:transport()|undefined|binary().


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Finds the ips, transports and ports to try for `Uri', following RFC3263
-spec resolve(nklib:user_uri()) -> 
    [{uri_transp(), inet:ip_address(), inet:port_number()}].

resolve(Uri) ->
    resolve(Uri, #{}).


%% @doc Finds the ips, transports and ports to try for `Uri', following RFC3263
-spec resolve(nklib:user_uri(), opts()) -> 
    [{uri_transp(), inet:ip_address(), inet:port_number()}].

resolve(#uri{scheme=Scheme}=Uri, Opts) ->
    case resolve_uri(Uri, Opts) of
        {ok, Conns} ->
            Conns;
        {naptr, Scheme, Domain} ->
            Naptr = case get_naptr(Domain, Opts) of
                [] when Scheme==sip; Scheme==sips ->
                    [
                        {sip, tls, "_sips._tcp." ++ Domain},
                        {sip, tcp, "_sip._tcp." ++ Domain},
                        {sip, udp, "_sip._udp." ++ Domain}
                    ];
                [] ->
                    [];
                Other ->
                    Other
            end,
            case resolve_srvs(Scheme, Naptr, Opts) of
                [] when Scheme==sips -> 
                    [{tls, Addr, 5061} || Addr <- get_ips(Domain, Opts)];
                [] when Scheme==sip ->
                    [{udp, Addr, 5060} || Addr <- get_ips(Domain, Opts)];
                [] ->
                    [];
                Srvs ->
                    Srvs
            end
    end;

resolve(Uri, Opts) ->
    case nklib_parse:uris(Uri) of
        [PUri] -> resolve(PUri, Opts);
        _ -> {error, invalid_uri}
    end.


%% @private
-spec resolve_uri(nklib:uri(), opts()) -> 
    {ok, [{uri_transp(), inet:ip_address(), inet:port_number()}]} |
    {naptr, nklib:scheme(), string()}.

resolve_uri(#uri{}=Uri, Opts) ->
    #uri{scheme=Scheme, domain=Host, opts=UriOpts, ext_opts=ExtOpts, port=Port} = Uri,
    Host1 = case Host of
        <<"all">> -> "0.0.0.0";
        <<"all6">> -> "0:0:0:0:0:0:0:0";
        _ -> Host
    end,
    Target = nklib_util:get_list(<<"maddr">>, UriOpts, Host1),
    case nklib_util:to_ip(Target) of 
        {ok, TargetIp} -> 
            IsNumeric = true;
        _ -> 
            TargetIp = IsNumeric = false
    end,
    RawTransp =  case nklib_util:get_value(<<"transport">>, UriOpts) of
        undefined -> 
            nklib_util:get_value(<<"transport">>, ExtOpts);
        RawTransp0 ->
            RawTransp0
    end,
    Transp = get_transp(RawTransp),
    case 
        Port==0 andalso (Scheme==sip orelse Scheme==sips) andalso 
        not IsNumeric andalso Transp==undefined 
    of
        true ->
            {naptr, Scheme, Target};
        false ->
            Addrs = case IsNumeric of
                true -> [TargetIp];
                false -> get_ips(Target, Opts)
            end,
            {ok, [{Transp, Addr, Port} || Addr <- Addrs]}
    end.


%% @doc Finds published services using DNS NAPTR search.
-spec get_naptr(string(), map()) -> 
    [{sip|sips, nkpacket:transport(), string()}].

%% TODO: Check site certificates in case of tls
get_naptr(Domain, Opts) ->
    case get_cache({naptr, Domain}, Opts) of
        undefined ->
            Naptr = case inet_res:lookup(Domain, in, naptr) of
                [] ->
                    [];
                Res ->
                    [Value || Term <- lists:sort(Res), 
                              (Value = naptr_filter(Term)) /= false]
            end,
            save_cache({naptr, Domain}, Naptr),
            Naptr;
        Naptr ->
            Naptr
    end.


%% @private TODO: add support for other protocols?
naptr_filter({_, _, "s", "sips+d2t", "", Domain}) -> {sips, tls, Domain};
naptr_filter({_, _, "s", "sip+d2u", "", Domain}) -> {sip, udp, Domain};
naptr_filter({_, _, "s", "sip+d2t", "", Domain}) -> {sip, tcp, Domain};
naptr_filter({_, _, "s", "sip+d2s", "", Domain}) -> {sip, sctp, Domain};
naptr_filter({_, _, "s", "sips+d2w", "", Domain}) -> {sips, wss, Domain};
naptr_filter({_, _, "s", "sip+d2w", "", Domain}) -> {sips, ws, Domain};
naptr_filter(_) -> false.


%% @private
resolve_srvs(Scheme, Domain, Opts) ->
    resolve_srvs(Scheme, Domain, Opts, []).


%% @private
resolve_srvs(sips, [{Scheme, _, _}|Rest], Opts, Acc) when Scheme/=sips -> 
    resolve_srvs(sips, Rest, Opts, Acc);

resolve_srvs(Scheme, [{_, Transp, Domain}|Rest], Opts, Acc) -> 
    case get_srvs(Domain, Opts) of
        [] -> 
            resolve_srvs(Scheme, Rest, Opts, Acc);
        Srvs -> 
            Addrs = [
                [{Transp, Addr, SPort} || Addr <- get_ips(SHost, Opts)]
                || {SHost, SPort} <- Srvs
            ],
            resolve_srvs(Scheme, Rest, Opts, [Addrs|Acc])
    end;

resolve_srvs(_, [], _Opts, Acc) ->
    lists:flatten(lists:reverse(Acc)).


%% @doc Gets all hosts for a SRV domain, sorting the result
%% according to RFC2782
-spec get_srvs(string(), opts()) ->
    [{string(), inet:port_number()}].

get_srvs(Domain, Opts) ->
    case get_cache({srvs, Domain}, Opts) of
        undefined ->
            Srvs = case inet_res:lookup(Domain, in, srv) of
                [] -> [];
                Res -> [{O, W, {D, P}} || {O, W, P, D} <- Res]
            end,
            save_cache({srvs, Domain}, Srvs),
            rfc2782_sort(Srvs);
        Srvs ->
            rfc2782_sort(Srvs)
    end.


%% @doc Gets all IPs for this host, or `[]' if not found.
%% It will first try to get it form the cache.
%% Each new invocation rotates the list of IPs.
-spec get_ips(string(), opts()) ->
    [inet:ip_address()].

get_ips(Host, Opts) ->
    case get_cache({ips, Host}, Opts) of
        undefined ->
            case inet:getaddrs(Host, inet) of
                {ok, Ips} -> 
                    ok;
                {error, _} -> 
                    case inet:getaddrs(Host, inet6) of
                        {ok, Ips} -> 
                            ok;
                        {error, _} -> 
                            Ips = []
                    end
            end,
            save_cache({ips, Host}, Ips),
            random(Ips);
        Ips ->
            random(Ips)
    end.



%% @doc Clear all info about `Domain' in the cache.
-spec clear(string()) ->
    ok.

clear(Domain) ->
    del_cache({ips, Domain}),
    del_cache({srvs, Domain}),
    del_cache({naptr, Domain}),
    ok.


%% @doc Clear all stored information in the cache.
-spec clear() ->
    ok.

clear() ->
    ets:delete_all_objects(?MODULE),
    ok.


%% ===================================================================
%% gen_server
%% ===================================================================

-record(state, {}).


%% @private
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
        

%% @private 
-spec init(term()) ->
    nklib_util:gen_server_init(#state{}).

init([]) ->
    ?MODULE = ets:new(?MODULE, [named_table, public]),   
    erlang:start_timer(1000*?CHECK_INTERVAL, self(), check_ttl), 
    {ok, #state{}}.


%% @private
-spec handle_call(term(), nklib_util:gen_server_from(), #state{}) ->
    nklib_util:gen_server_call(#state{}).

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    nklib_util:gen_server_cast(#state{}).

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    nklib_util:gen_server_info(#state{}).

handle_info({timeout, _, check_ttl}, State) ->
    % Remove old, non read entries 
    Now = nklib_util:timestamp(),
    Spec = [{{'_', '_', '$1'}, [{'<', '$1', Now}], [true]}],
    _Deleted = ets:select_delete(?MODULE, Spec),
    erlang:start_timer(1000*?CHECK_INTERVAL, self(), check_ttl), 
    {noreply, State};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    nklib_util:gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    nklib_util:gen_server_terminate().

terminate(_Reason, _State) ->  
    ok.



%% ===================================================================
%% Utils
%% ===================================================================

%% @private
get_transp(udp) -> udp;
get_transp(tcp) -> tcp;
get_transp(tls) -> tls;
get_transp(sctp) -> sctp;
get_transp(ws) -> ws;
get_transp(wss) -> wss;
get_transp(http) -> http;
get_transp(https) -> https;
get_transp(undefined) -> undefined;
get_transp(Other) when is_atom(Other) -> atom_to_binary(Other, latin1);
get_transp(Other) ->
    Transp = string:to_lower(nklib_util:to_list(Other)),
    case catch list_to_existing_atom(Transp) of
        {'EXIT', _} -> nklib_util:to_binary(Other);
        Atom -> get_transp(Atom)
    end.


%% @private
-spec get_cache(term(), map()) ->
    undefined | term().

get_cache(_Key, #{no_dns_cache:=true}) ->
    undefined;

get_cache(Key, _Opts) ->
    case ets:lookup(?MODULE, Key) of
        [] ->
            undefined;
        [{_, Value, Expire}] ->
            case nklib_util:timestamp() > Expire of
                true ->
                    del_cache(Key),
                    undefined;
                false ->
                    Value
            end
    end.


%% @private
-spec save_cache(term(), term()) ->
    ok.

save_cache(Key, Value) ->
    case nkpacket_config:dns_cache_ttl() of
        TTL when is_integer(TTL), TTL > 0 ->
            Now = nklib_util:timestamp(),
            Secs = TTL div 1000,
            true = ets:insert(?MODULE, {Key, Value, Now+Secs}),
            ok;
        _ ->
            ok
    end.


%% @private
-spec del_cache(term()) ->
    ok.

del_cache(Key) ->
    true = ets:delete(?MODULE, Key),
    ok.


%% @private Extracts and groups records with the same priority
-spec groups([{Prio::integer(), Weight::integer(), Target::term()}]) ->
    [Group]
    when Group :: [{Weight::integer(), Target::term()}].

groups(Srvs) ->
    groups(lists:sort(Srvs), [], []).


%% @private
groups([{Prio, _, _}=N|Rest], [{Prio, _, _}|_]=Acc1, Acc2) ->
    groups(Rest, [N|Acc1], Acc2);

groups([N|Rest], [], Acc2) ->
    groups(Rest, [N], Acc2);

groups([N|Rest], Acc1, Acc2) ->
    LAcc1 = [{W, T} || {_, W, T} <- Acc1],
    groups(Rest, [N], [LAcc1|Acc2]);

groups([], [], Acc2) ->
    lists:reverse(Acc2);

groups([], Acc1, Acc2) ->
    LAcc1 = [{W, T} || {_, W, T} <- Acc1],
    lists:reverse([LAcc1|Acc2]).


%% @private
-spec random(list()) ->
    list().

random([]) ->
    [];
random([A]) ->
    [A];
random([A, B]) ->
    case crypto:rand_uniform(0, 2) of
        0 -> [A, B];
        1 -> [B, A]
    end;
random([A, B, C]) ->
    case crypto:rand_uniform(0, 3) of
        0 -> [A, B, C];
        1 -> [B, C, A];
        2 -> [C, A, B]
    end;
random(List) ->
    Size = length(List),
    List1 = [{crypto:rand_uniform(0, Size), Term} || Term <- List],
    [Term || {_, Term} <- lists:sort(List1)].




%% ===================================================================
%% Weight algorithm
%% ===================================================================


%% @private Applies RFC2782 weight sorting algorithm
-spec rfc2782_sort([{Prio, Weight, Target}]) ->
    [Target]
    when Prio::integer(), Weight::integer(), Target::term().

rfc2782_sort([]) ->
    [];

rfc2782_sort(List) ->
    Groups = groups(List),
    lists:flatten([do_sort(Group, []) || Group <- Groups]).

%% @private
do_sort([], Acc) ->
    lists:reverse(Acc);

do_sort(List, Acc) ->
    {Pos, Sum} = sort_sum(List),
    % ?P("Pos: ~p, Sum: ~p", [Pos, Sum]),
    {Current, Rest} = sort_select(Pos, Sum, []),
    % ?P("Current: ~p", [Current]),
    do_sort(Rest, [Current|Acc]).


%% @private 
-spec sort_sum([{Weight, Target}]) ->
    {Pos, [{AccWeight, Target}]}
    when Weight::integer(), Target::term(), Pos::integer(), AccWeight::integer().

sort_sum(List) ->
    Total = lists:foldl(
        fun({W, _}, Acc) -> W+Acc end, 
        0, 
        List),
    Sum = lists:foldl(
        fun({W, T}, Acc) -> 
            case Acc of
                [{OldW, _}|_] -> [{OldW+W, T}|Acc];
                [] -> [{W, T}]
            end
        end,
        [],
        lists:sort(List)),
    Pos = case Total >= 1 of 
        true -> crypto:rand_uniform(0, Total);
        false -> 0
    end,
    {Pos, lists:reverse(Sum)}.


%% @private
-spec sort_select(Pos, [{AccWeight, Target}], [{AccWeight, Target}]) ->
    Target
    when Pos::integer(), AccWeight::integer(), Target::term().

sort_select(Pos, [{W, T}|Rest], Acc) when Pos =< W ->
    {T, Rest++Acc};

sort_select(Pos, [C|Rest], Acc) -> 
    sort_select(Pos, Rest, [C|Acc]).


%% ===================================================================
%% EUnit tests
%% ===================================================================


% -define(TEST, true).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

weigth_test() ->
    ?debugMsg("DNS Weight Test"),
    []= groups([]),
    [[{1,a}]] = groups([{1,1,a}]),
    [[{1,a}],[{2,b}]] = groups([{2,2,b}, {1,1,a}]),
    [[{2,b},{1,a}],[{3,c}]] = groups([{1,1,a}, {1,2,b}, {2,3,c}]),
    [[{1,a}],[{3,c},{2,b}]] = groups([{1,1,a}, {2,2,b}, {2,3,c}]),
    [[{2,b},{1,a}],[{4,d},{3,c}],[{5,e}]] = 
        groups([{1,1,a}, {1,2,b}, {2,3,c}, {2,4,d}, {3,5,e}]),

    {_, [{0,c},{0,f},{5,a},{15,b},{25,e},{50,d}]} = 
        sort_sum([{5,a}, {10,b}, {0,c}, {25,d}, {10,e}, {0,f}]),

    {b,[{4,c},{1,a}]} = 
        sort_select(3, [{1,a}, {3,b}, {4,c}], []),

    Total = [
        begin
            [A, B, C] = do_sort([{1,a}, {9,b}, {90,c}], []),
            false = A==B,
            false = A==C,
            false = B==C,
            A
        end
        || _ <- lists:seq(0,1000)
    ],
    As = length([true || a <-Total]),
    Bs = length([true || b <-Total]),
    Cs = length([true || c <-Total]),
    % ?P("As: ~p vs 1%, Bs: ~p vs 9%, Cs: ~p vs 90%", [As/10, Bs/10, Cs/10]),
    true = Cs > Bs andalso Bs > As,

    [] = rfc2782_sort([]),
    [a] = rfc2782_sort([{1,1,a}]),
    [b, a, c] = rfc2782_sort([{2,2,a}, {1,1,b}, {3,3,c}]),

    [b, A1, A2, c] = 
        rfc2782_sort([{2,10,a}, {1,1,b}, {3,3,c}, {2,10,d}]),
    true = A1==a orelse A1==d,
    true = A1/=A2,
    ok.



-endif.



