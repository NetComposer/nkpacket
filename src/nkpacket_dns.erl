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

-export([resolve/1, resolve/2]).
-export([ips/1, ips/2, srvs/1, srvs/2, naptr/3]).
-export([clear/1, clear/0]).
-export([start_link/0, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).

-define(CHECK_INTERVAL, 60).     % secs

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").

-compile([export_all]).

-type opts() :: 
    #{
        no_dns_cache => boolean(),
        protocol => nkpacket:protocol()
    }.

-type uri_transp() :: nkpacket:transport()|undefined|binary().


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Equivalent to resolve(Uri, #{})
-spec resolve(nklib:user_uri()|[nklib:user_uri()])-> 
    [{uri_transp(), inet:ip_address(), inet:port_number()}].

resolve(Uri) ->
    resolve(Uri, #{}).


%% @doc Finds transports, ips and ports to try for `Uri', following RFC3263
%% If the option 'protocol' is used, it must be a NkPACKET protocol, and will
%% be used for:
%% - get default transports
%% - get default ports
%% - perform NAPTR queries
%%
-spec resolve(nklib:user_uri(), opts()) -> 
    [{uri_transp(), inet:ip_address(), inet:port_number()}].

resolve([], _Opts) ->
    [];

resolve(List, Opts) when is_list(List), not is_integer(hd(List)) ->
    resolve(List, Opts, []);

resolve(Other, Opts) ->
    resolve([Other], Opts).



%% @private
resolve([], _Opts, Acc) ->
    Acc;

resolve([#uri{}=Uri|Rest], Opts, Acc) ->
    #uri{
        scheme = Scheme, 
        domain = Host, 
        opts = UriOpts, 
        ext_opts = ExtOpts, 
        port = Port
    } = Uri,
    Host1 = case Host of
        <<"all">> -> "0.0.0.0";
        <<"all6">> -> "0:0:0:0:0:0:0:0";
        _ -> Host
    end,
    Target = nklib_util:get_list(<<"maddr">>, UriOpts, Host1),
    Target2 = case nklib_util:to_ip(Target) of 
        {ok, IP} -> IP;
        _ -> Target
    end,
    RawTransp =  case nklib_util:get_value(<<"transport">>, UriOpts) of
        undefined -> 
            nklib_util:get_value(<<"transport">>, ExtOpts);
        RawTransp0 ->
            RawTransp0
    end,
    Transp = transp(RawTransp),
    Res = resolve(Scheme, Target2, Port, Transp, Opts),
    resolve(Rest, Opts, Acc++Res);

resolve([Uri|Rest], Opts, Acc) ->
    case nklib_parse:uris(Uri) of
        error ->
            lager:warning("Invalud URI: ~p", [Uri]),
            resolve(Rest, Opts, Acc);
        Uris ->
            resolve(Uris++Rest, Opts, Acc)
    end.


%% @private
resolve(Scheme, Ip, Port, Transp, Opts) when is_tuple(Ip) ->
    case get_transp(Scheme, Transp, Opts) of
        invalid ->
            [];
        Transp1 ->
            case get_port(Port, Transp1, Opts) of
                invalid -> [];
                Port1 -> [{Transp1, Ip, Port1}]
            end
    end;

resolve(Scheme, Host, 0, undefined, Opts) ->
    case naptr(Scheme, Host, Opts) of
        [] ->
            case get_transp(Scheme, undefined, Opts) of
                invalid ->
                    [];
                undefined ->
                    Addrs = ips(Host, Opts),
                    [{undefined, Addr, 0} || Addr <- Addrs];
                Transp ->
                    resolve(Scheme, Host, 0, Transp, Opts)
            end;
        Res ->
            Res
    end;

resolve(Scheme, Host, 0, Transp, Opts) ->
    case get_transp(Scheme, Transp, Opts) of
        invalid ->
            [];
        Transp1 ->
            SrvDomain = make_srv_domain(Scheme, Transp1, Host),
            case srvs(SrvDomain, Opts) of
                [] ->
                    case get_port(0, Transp1, Opts) of
                        invalid ->
                            [];
                        Port1 ->
                            Addrs = ips(Host, Opts),
                            [{Transp1, Addr, Port1} || Addr <- Addrs]
                    end;
                Srvs ->
                    [{Transp1, Addr, Port1} || {Addr, Port1} <- Srvs]
            end
    end;

resolve(Scheme, Host, Port, Transp, Opts) ->
    case get_transp(Scheme, Transp, Opts) of
        invalid ->
            [];
        Transp1 ->
            Addrs = ips(Host, Opts),
            Port1 = get_port(Port, Transp1, Opts),
            [{Transp1, Addr, Port1} || Addr <- Addrs]
    end.



%% @doc Finds published services using DNS NAPTR search.
-spec naptr(nklib:scheme(), string()|binary(), opts()) -> 
    [{nkpacket:transport(), inet:ip_address(), inet:port_number()}].

naptr(Scheme, Domain, #{protocol:=Protocol}=Opts) when Protocol/=undefined ->
    case erlang:function_exported(Protocol, naptr, 2) of
        true ->
            Domain1 = nklib_util:to_list(Domain),
            case get_cache({naptr, Domain1}, Opts) of
                undefined ->
                    Naptr = lists:sort(inet_res:lookup(Domain1, in, naptr)),
                    save_cache({naptr, Domain1}, Naptr),
                    lager:debug("Naptr: ~p", [Naptr]),
                    naptr(Scheme, Naptr, Protocol, Opts, []);
                Naptr ->
                    naptr(Scheme, Naptr, Protocol, Opts, [])
            end;
        false ->
            []
    end;

naptr(_Scheme, _Domain, _Opts) ->
    [].


%% @private
naptr(_Scheme, [], _Proto, _Opts, Acc) ->
    Acc;

%% Type "s", no regular expression
naptr(Scheme, [{_Pref, _Order, "s", Service, "", Target}|Rest], Proto, Opts, Acc) ->
    case Proto:naptr(Scheme, Service) of
        {ok, Transp} ->
            Addrs = srvs(Target, Opts),
            Acc2 = [{Transp, Addr, Port} || {Addr, Port} <- Addrs],
            naptr(Scheme, Rest, Proto, Opts, Acc++Acc2);
        _ ->
            naptr(Scheme, Rest, Proto, Opts, Acc)
    end;

%% We don't yet support other NAPTR expressions
naptr(Scheme, [_|Rest], Proto, Opts, Acc) ->
    naptr(Scheme, Rest, Proto, Opts, Acc).


%% @doc Equivalent to srvs(Domain, #{})
-spec srvs(string()|binary()) ->
    [{inet:ip_address(), inet:port_number()}].

srvs(Domain) ->
    srvs(Domain, #{}).


%% @doc Gets all hosts for a SRV domain, sorting the result
%% according to RFC2782
%% Domain mast be of the type "_sip._tcp.sip2sip.info"
-spec srvs(string()|binary(), opts()) ->
    [{inet:ip_address(), inet:port_number()}].

srvs(Domain, Opts) ->
    Domain1 = nklib_util:to_list(Domain),
    List = case get_cache({srvs, Domain1}, Opts) of
        undefined ->
            Srvs = case inet_res:lookup(Domain1, in, srv) of
                [] -> [];
                Res -> [{O, W, {D, P}} || {O, W, P, D} <- Res]
            end,
            save_cache({srvs, Domain1}, Srvs),
            rfc2782_sort(Srvs);
        Srvs ->
            rfc2782_sort(Srvs)
    end,
    case List of 
        [] -> 
            [];
        _ -> 
            lager:debug("Srvs: ~p", [List]),
            lists:flatten([
                [{Addr, Port} || Addr <- ips(Host, Opts)] || {Host, Port} <- List
            ])
    end.


%% @doc Equivalent to ips(Host, #{})
-spec ips(string()|binary())  ->
    [inet:ip_address()].

ips(Host) ->
    ips(Host, #{}).


%% @doc Gets all IPs for this host, or `[]' if not found.
%% It will first try to get it form the cache.
%% Each new invocation rotates the list of IPs.
-spec ips(string(), opts()) ->
    [inet:ip_address()].

ips(Host, Opts) ->
    Host1 = nklib_util:to_list(Host),
    case get_cache({ips, Host1}, Opts) of
        undefined ->
            case inet:getaddrs(Host1, inet) of
                {ok, Ips} -> 
                    ok;
                {error, _} -> 
                    case inet:getaddrs(Host1, inet6) of
                        {ok, Ips} -> 
                            ok;
                        {error, _} -> 
                            Ips = []
                    end
            end,
            save_cache({ips, Host1}, Ips),
            nklib_util:randomize(Ips);
        Ips ->
            nklib_util:randomize(Ips)
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
transp(udp) -> udp;
transp(tcp) -> tcp;
transp(tls) -> tls;
transp(sctp) -> sctp;
transp(ws) -> ws;
transp(wss) -> wss;
transp(http) -> http;
transp(https) -> https;
transp(undefined) -> undefined;
transp(Other) when is_atom(Other) -> atom_to_binary(Other, latin1);
transp(Other) ->
    Transp = string:to_lower(nklib_util:to_list(Other)),
    case catch list_to_existing_atom(Transp) of
        {'EXIT', _} -> nklib_util:to_binary(Other);
        Atom -> transp(Atom)
    end.


%% @private
get_port(0, Transp, #{protocol:=Protocol}) when Protocol/=undefined ->
    case erlang:function_exported(Protocol, default_port, 1) of
        true ->
            % lager:warning("P: ~p, ~p", [Protocol, Transp]),
            case Protocol:default_port(Transp) of
                Port when is_integer(Port) -> Port;
                _ -> invalid
            end;
        false ->
            0
    end;

get_port(Port, _Transp, _Opts)->
    Port.


%% @private
get_transp(Scheme, Transp, #{protocol:=Protocol}) when Protocol/=undefined ->
    case erlang:function_exported(Protocol, transports, 1) of
        true ->
            Valid = Protocol:transports(Scheme),
            case Transp of
                undefined ->
                    case Valid of
                        [Transp1|_] -> Transp1;
                        [] -> undefined
                    end;
                _ ->
                    case lists:member(Transp, Valid) of
                        true -> 
                            Transp;
                        _ -> 
                            lager:info("Invalid transport ~p for protocol ~p",
                                       [Transp, Protocol]),
                            invalid
                    end
            end;
        false ->
            Transp
    end;

get_transp(_Scheme, Transp, _Opts) ->
    Transp.


%% @private
make_srv_domain(Scheme, Transp, Domain) ->
    binary_to_list(
        list_to_binary([
            $_, nklib_util:to_binary(Scheme), $.,
            $_, nklib_util:to_binary(Transp), $.,
            nklib_util:to_binary(Domain)
        ])
    ).


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


-define(TEST, true).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").


basic_test() ->
    [
        {undefined, {1,2,3,4}, 0},
        {tcp, {4,3,2,1}, 25},
        {undefined, {0,0,0,0}, 1200},
        {tls, {1,0,0,0,0,0,0,5}, 0}
    ] = 
        resolve("http://1.2.3.4, http://4.3.2.1:25;transport=tcp,"
                "http://all:1200, <http://[1::5]>;transport=tls"),

    [
        {http, {1,2,3,4}, 80},
        {https, {1,2,3,4}, 443},
        % {tcp, {4,3,2,1}, 25},
        {http, {0,0,0,0}, 1200},
        {https, {1,0,0,0,0,0,0,5}, 443}
    ] = 
        resolve(
            [
                "http://1.2.3.4",
                "https://1.2.3.4",
                "http://4.3.2.1:25;transport=tcp",
                "http://all:1200", 
                "<https://[1::5]>;transport=https"
            ], #{protocol=>nkpacket_protocol_http}),

    [
        {undefined, {127,0,0,1}, 0},
        {undefined, {127,0,0,1}, 0},
        {undefined, {127,0,0,1}, 25},
        {tls, {127,0,0,1}, 0},
        {udp, {127,0,0,1}, 1234}
    ] = 
        resolve("http://localhost, https://localhost, http://localhost:25, "
                "http://localhost;transport=tls, https://localhost:1234;transport=udp"),

    [
        {http, {127,0,0,1}, 80},
        {https, {127,0,0,1}, 443},
        {http, {127,0,0,1}, 25}
        % {tls, {127,0,0,1}, 0}
        % {udp, {127,0,0,1}, 1234}
    ] =
        resolve("http://localhost, https://localhost, http://localhost:25, "
                 "http://localhost;transport=tls, https://localhost:1234;transport=udp",
                 #{protocol=>nkpacket_protocol_http}).





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



