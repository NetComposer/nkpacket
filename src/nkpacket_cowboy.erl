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

%% @private Cowboy support
%% This module implements a "shared" tcp/tls listener.
%% When a new listener request arrives, it is associated to a existing listener,
%% if present. If not, a new one is started.
%% When a new connection arrives, a standard cowboy_protocol is started.
%% It then cycles over all registered listeners, until one of them accepts 
%% the request.

-module(nkpacket_cowboy).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(cowboy_middleware).

-export([start/2, get_all/0, get_filters/2]).
-export([reply/2, reply/3, reply/4, stream_reply/3, stream_body/3]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).
-export([execute/2]).
-export([extract_filter/1]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


-define(DEBUG(Txt, Args),
    case get(nkpacket_debug) of
        true -> ?LLOG(debug, Txt, Args);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args), lager:Type("NkPACKET Cowboy "++Txt, Args)).


-define(WS_PROTO_HD, <<"sec-websocket-protocol">>).





%% ===================================================================
%% Private
%% ===================================================================

%% @private Starts a new shared transport or reuses an existing one
%%
%% The 'meta' field in NkPort can include options, but it will only be read from 
%% the first started server: tcp_listeners, tcp_max_connections, tls_opts
%% It can also include 'cowboy_opts' with the same limitation. 
%% The following options are fixed: timeout, compress
%%
%% Each server can provide its own 'http_proto'
-spec start(nkpacket:nkport(), #cowboy_filter{}) ->
    {ok, pid()} | {error, term()}.

start(#nkport{pid=Pid}=NkPort, #cowboy_filter{}=Filter) when is_pid(Pid) ->
    Fun = fun() -> do_start(NkPort, Filter) end,
    #nkport{listen_ip=Ip, listen_port=Port} = NkPort,
    try 
        nklib_proc:try_call(Fun, {?MODULE, Ip, Port}, 100, 50)
    catch
        error:max_tries -> {error, {shared_failed, max_tries}}
    end.


%% @private
-spec do_start(nkpacket:nkport(), #cowboy_filter{}) ->
    {ok, pid()} | {error, term()}.

do_start(#nkport{pid=Pid}=NkPort, Filter) when is_pid(Pid) ->
    #nkport{transp=Transp, listen_ip=Ip, listen_port=Port} = NkPort,
    case nklib_proc:values({?MODULE, Ip, Port}) of
        [{_Filters, Listen}|_] ->
            case nklib_util:call(Listen, {start, Pid, Transp, Filter}, 15000) of
                ok -> 
                    {ok, Listen};
                {error, Error} -> 
                    {error, {shared_failed, Error}}
            end;
        [] ->
            gen_server:start(?MODULE, [NkPort, Filter], [])
    end.


%% @private
-spec get_all() ->
    [{{inet:ip_address(), inet:port_number()}, pid(), [#cowboy_filter{}]}].

get_all() ->
    [
        {{Ip, Port}, Pid, get_filters(Ip, Port)}
        || {{Ip, Port}, Pid} <- nklib_proc:values(?MODULE)
    ].


%% @private
-spec get_filters(inet:ip_address(), inet:port_number()) ->
    [#cowboy_filter{}].

get_filters(Ip, Port) -> 
    % Should be only one
    [{Filters, _}|_] = nklib_proc:values({?MODULE, Ip, Port}),
    Filters.


%% @doc Sends a cowboy reply 
-spec reply(cowboy:http_status(), cowboy_req:req()) -> 
    cowboy_req:req().

reply(Code, Req) ->
    reply(Code, #{}, <<>>, Req).


%% @doc Sends a cowboy reply 
-spec reply(cowboy:http_status(), cowboy:http_headers(), cowboy_req:req()) -> 
    cowboy_req:req().

reply(Code, Hds, Req) ->
    reply(Code, Hds, <<>>, Req).


%% @doc Sends a cowboy reply 
-spec reply(cowboy:http_status(), cowboy:http_headers(),
            iodata() | {send_file, integer(), integer(), term()}, cowboy_req:req()) ->
    cowboy_req:req().

reply(Code, Hds, Body, Req) when is_map(Hds) ->
    cowboy_req:reply(Code, Hds, Body, Req);

reply(Code, Hds, Body, Req) when is_list(Hds) ->
    cowboy_req:reply(Code, maps:from_list(Hds), Body, Req).


%% @doc Sends a cowboy stream reply
-spec stream_reply(cowboy:http_status(), cowboy:http_headers(),cowboy_req:req()) ->
    cowboy_req:req().

stream_reply(Code, Hds, Req) when is_map(Hds) ->
    cowboy_req:stream_reply(Code, Hds, Req);

stream_reply(Code, Hds, Req) when is_list(Hds) ->
    cowboy_req:stream_reply(Code, Hds, Req).


%% @doc Sends a cowboy stream reply
-spec stream_body(iodata(), fin|nofin, cowboy_req:req()) ->
    ok.

stream_body(Body, Fin, Req) when Fin==fin;Fin==nofin ->
    ok = cowboy_req:stream_body(Body, Fin, Req).

%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    nkport :: nkpacket:nkport(),
    ranch_id :: term(),
    ranch_pid :: pid(),
    filters :: [#cowboy_filter{}]
}).


%% @private 
-spec init(term()) ->
    {ok, #state{}} | {stop, term()}.

init([NkPort, #cowboy_filter{}=Filter]) ->
    #nkport{
        transp     = Transp,
        listen_ip  = ListenIp,
        listen_port= ListenPort,
        pid        = ListenPid,
        opts       = Meta
    } = NkPort,
    process_flag(trap_exit, true),   %% Allow calls to terminate
    Debug = maps:get(debug, Meta, false),
    put(nkpacket_debug, Debug),
    ListenOpts = listen_opts(NkPort),
    case nkpacket_transport:open_port(NkPort, ListenOpts) of
        {ok, Socket}  ->
            {InetMod, _, RanchMod, CowboyMod} = get_modules(Transp),
            {ok, {LocalIp, LocalPort}} = InetMod:sockname(Socket),
            Shared = NkPort#nkport{
                local_ip   = LocalIp,
                local_port = LocalPort,
                listen_port= LocalPort,
                pid        = self(),
                protocol   = undefined,
                socket     = Socket,
                opts       = #{}
            },
            RanchId = {ListenIp, LocalPort},
            Timeout = case Meta of
                #{idle_timeout:=Timeout0} -> 
                    Timeout0;
                _ when Transp==ws; Transp==wss -> 
                    nkpacket_config:ws_timeout();
                _ when Transp==http; Transp==https -> 
                    nkpacket_config:http_timeout()
            end,
            CowboyOpts1 = get_cowboy_opts(Meta),
            CowboyOpts2 = CowboyOpts1#{
                env => #{nkid => RanchId, nkdebug=>Debug},
                middlewares => [?MODULE],
                idle_timeout => Timeout
                %% stream_handlers => [cowboy_compress_h, cowboy_stream_h]
                % Warning no compress!
            },
            Max = maps:get(tcp_max_connections, Meta, 1024),
            ?DEBUG("starting Ranch ~p (max:~p) (opts:~p)", [RanchId, Max, CowboyOpts2]),
            {ok, RanchPid} = ranch_listener_sup:start_link(
                RanchId,
                RanchMod,
                #{
                    socket => Socket,
                    max_connections => Max
                },
                CowboyMod,
                CowboyOpts2),

            % - Will call to cowboy_clear or cowboy_tls:start/4
            % - They will call cowboy_http or cowboy_http2:init/5
            % - They will parse the request and call cowboy_stream:init/3
            % - By default, cowboy_stream_h is used, that gets env and middlewares and
            %   call cowboy_stream_h:request_process/3, that call our execute
            % - In a normal cowboy operation middlewares would be
            %   - cowboy_router:
            %       - requires dispatch value in Env
            %       - it would add routing information and handlers to
            %         Req and Env, see cowboy_router:execute/2
            %   - cowboy_handler:
            %       - requires handler and handler_opts values in Env
            %       - execute the handlers, adding to the Env
            %         #{result => ok or the Handle:terminate/3 return value)
            %         In doc it is said that if result is not ok, it will stop
            %         processing, I don't see that in code
            %  - For us, we implement out own middleware
            %       - For WS, callback module would be nkpacket_transport_ws, and we will
            %         call cowboy_init/4 there

            nklib_proc:put(?MODULE, {ListenIp, LocalPort}),
            Filter2 = Filter#cowboy_filter{mon=monitor(process, ListenPid)},
            State = #state{
                nkport = Shared,
                ranch_id = RanchId,
                ranch_pid = RanchPid,
                filters = [Filter2]
            },
            {ok, register(State)};
        {error, Error} ->
            ?LLOG(error, "could not start ~p transport on ~p:~p (~p)", 
                   [Transp, ListenIp, ListenPort, Error]),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}}.

handle_call({start, ListenPid, Transp, Filter}, _From, State) ->
    #state{filters=Filters, nkport=#nkport{transp=BaseTransp}} = State,
    case secure(Transp)==secure(BaseTransp) of
        true ->
            Filter2 = Filter#cowboy_filter{mon = monitor(process, ListenPid)},
            Filters2 = sort_filters([Filter2|Filters]),
            {reply, ok, register(State#state{filters=Filters2})};
        false ->
            {reply, {error, cannot_share_port}, State}
    end;

handle_call({nkpacket_apply_nkport, Fun}, _From, #state{nkport=NkPort}=State) ->
    {reply, Fun(NkPort), State};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(Msg, State) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({'DOWN', MRef, process, _Pid, _Reason}=Msg, State) ->
    #state{filters=Filters} = State,
    case lists:keytake(MRef, #cowboy_filter.mon, Filters) of
        {value, _, []} ->
            ?DEBUG("last server leave", []),
            {stop, normal, State};
        {value, _, Filters1} ->
            ?DEBUG("server leave", []),
            {noreply, register(State#state{filters=Filters1})};
        false ->
            lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
            {noreply, State}
    end;

handle_info({'EXIT', Pid, Reason}, #state{ranch_pid=Pid}=State) ->
    {stop, {ranch_stop, Reason}, State};

handle_info(Msg, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, #state{ranch_pid=RanchPid}=State) ->  
    ?DEBUG("listener stop: ~p", [Reason]),
    #state{
        ranch_id = RanchId,
        nkport = #nkport{transp=Transp, socket=Socket}
    } = State,
    exit(RanchPid, shutdown),
    timer:sleep(100),   %% Give time to ranch to close acceptors
    catch ranch_server:cleanup_listener_opts(RanchId),
    {_, TranspMod, _, _} = get_modules(Transp),
    TranspMod:close(Socket),
    ok.


%% ===================================================================
%% Ranch Callbacks
%% ===================================================================

%% @private Cowboy middleware callback
-spec execute(Req, Env)-> 
    {ok, Req, Env} | {stop, Req} | {suspend, module(), atom(), list()}
    when Req::cowboy_req:req(), Env::cowboy_middleware:env().

execute(Req, Env) ->
    Req2 = cowboy_req:set_resp_header(<<"server">>, <<"NkPACKET">>, Req),
    #{
        nkid := {Ip, Port},
        nkdebug := Debug
    } = Env,
    case Debug of
        true -> put(nkpacket_debug, true);
        _ -> ok
    end,
    Filters = get_filters(Ip, Port),
    execute(Filters, Req2, Env).


%% @private
-spec execute([#cowboy_filter{}], cowboy_req:req(), cowboy_middleware:env()) ->
    term().

execute([], Req, _Env) ->
    ?LLOG(info, "url ~s not matched", [cowboy_req:path(Req)]),
    {stop, reply(404, Req)};

execute([Filter|Rest], Req, Env) ->
    #cowboy_filter{
        pid = Pid,
        module = Module,
        transp = Transp,
        host = Host,
        paths = Paths,
        ws_proto = WsProto,
        meta = FilterMeta
    } = Filter,
    Type = case Transp of
        http -> http;
        https -> http;
        ws -> ws;
        wss -> ws
    end,
    ReqType = case cowboy_req:parse_header(<<"upgrade">>, Req, []) of
        [<<"websocket">>] -> ws;
        _ -> http
    end,
    ReqHost = cowboy_req:host(Req),
    ReqPaths = nkpacket_util:norm_path(cowboy_req:path(Req)),
    ReqWsProto = case cowboy_req:parse_header(?WS_PROTO_HD, Req, []) of
        [ReqWsProto0] -> ReqWsProto0;
        _ -> any
    end,
    case
        (Type == ReqType) andalso
        (Host==any orelse ReqHost==Host) andalso
        (WsProto==any orelse ReqWsProto==WsProto) andalso
        check_paths(ReqPaths, Paths)
    of
        {true, SubPath} ->
            ?DEBUG("selected: ~p (~p) ~p (~p), ~p (~p), ~p (~p)",
                [ReqType, Type, ReqHost, Host, ReqPaths, Paths, ReqWsProto, WsProto]),
            Req2 = case WsProto of
                any ->
                    Req;
                _ ->
                    cowboy_req:set_resp_header(?WS_PROTO_HD, WsProto, Req)
            end,
            case Module:cowboy_init(Pid, Req2, SubPath, FilterMeta, Env) of
                next ->
                    execute(Rest, Req, Env);
                Result ->
                    Result
            end;
        false ->
            ?DEBUG("skipping: ~p (~p) ~p (~p), ~p (~p), ~p (~p)",
                [ReqType, Type, ReqHost, Host, ReqPaths, Paths, ReqWsProto, WsProto]),
            execute(Rest, Req, Env)
    end.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
%% @see https://ninenines.eu/docs/en/cowboy/2.1/manual/cowboy_http/
get_cowboy_opts(Map) ->
    List = [
        {http_inactivity_timeout, inactivity_timeout},
        {http_max_empty_lines, max_empty_lines},
        {http_max_header_name_length, max_header_name_length},
        {http_max_header_value_length, max_header_value_length},
        {http_max_headers, max_headers},
        {http_max_keepalive, max_keepalive},
        {http_max_method_length, max_method_length},
        {http_max_request_line_length, max_request_line_length},
        {http_request_timeout, request_timeout}
    ],
    get_cowboy_opts(List, Map, #{}).


%% @private
get_cowboy_opts([], _Map, Acc) ->
    Acc;

get_cowboy_opts([{ExtKey, IntKey}|Rest], Map, Acc) ->
    Acc2 = case maps:find(ExtKey, Map) of
        {ok, Value} ->
            Acc#{IntKey => Value};
        error ->
            Acc
    end,
    get_cowboy_opts(Rest, Map, Acc2).



%% @private Gets socket options for listening connections
-spec listen_opts(#nkport{}) ->
    list().

listen_opts(#nkport{transp=Transp, listen_ip=Ip}) 
        when Transp==ws; Transp==http ->
    [
        {ip, Ip}, {active, false}, binary,
        {nodelay, true}, {keepalive, true},
        {reuseaddr, true}, {backlog, 1024}
    ];

listen_opts(#nkport{transp=Transp, listen_ip=Ip, opts=Opts})
        when Transp==wss; Transp==https ->
    [
        % From Cowboy 2.0:
        %{next_protocols_advertised, [<<"h2">>, <<"http/1.1">>]},
        %{alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]},
        {ip, Ip}, {active, false}, binary,
        {nodelay, true}, {keepalive, true},
        {reuseaddr, true}, {backlog, 1024}
    ]
    ++ nkpacket_tls:make_inbound_opts(Opts).


%% @private
register(#state{nkport=Shared, filters=Filters}=State) ->
    #nkport{listen_ip=Ip, listen_port=Port} = Shared,
    nklib_proc:put({?MODULE, Ip, Port}, Filters),
    State.


%% @private
%% Put long paths before short paths
sort_filters(Filters) ->
    lists:reverse(lists:keysort(#cowboy_filter.paths, Filters)).


%% @private
check_paths([Part|Rest1], [Part|Rest2]) ->
    check_paths(Rest1, Rest2);

check_paths(Rest, []) ->
    {true, Rest};

check_paths(_A, _B) ->
    false.


%%%% @private
%%-spec make_filter(user_filter(), pid(), atom()) ->
%%    #filter{}.
%%
%%make_filter(Filter, ListenPid, Transp) ->
%%    Meta = maps:with([get_headers], Filter),
%%    #filter{
%%        id = maps:get(id, Filter),
%%        module = maps:get(module, Filter),
%%        transp = Transp,
%%        host = maps:get(host, Filter, any),
%%        paths = nkpacket_util:norm_path(maps:get(path, Filter, any)),
%%        ws_proto = maps:get(ws_proto, Filter, any),
%%        meta = Meta,
%%        mon = monitor(process, ListenPid)
%%    }.


%%%% @private
%%-spec get_user_meta(filter_meta(), cowboy:req()) ->
%%    user_meta().
%%
%%get_user_meta(#{get_headers:=Names}, Req) ->
%%    Hds1 = cowboy_req:headers(Req),
%%    Hds2 = case Names of
%%        true -> Hds1;
%%        false -> #{};
%%        _ -> [{Name, Key} || {Name, Key} <- Hds1, lists:member(Name, Names)]
%%    end,
%%    #{headers=>Hds2};
%%
%%get_user_meta(_, _) ->
%%    #{}.


%% @private
secure(ws) -> false;
secure(wss) -> true;
secure(http) -> false;
secure(https) -> true.


%% @private
get_modules(ws) -> {inet, gen_tcp, ranch_tcp, cowboy_clear};
get_modules(wss) -> {ssl, ssl, ranch_ssl, cowboy_tls};
get_modules(http) -> {inet, gen_tcp, ranch_tcp, cowboy_clear};
get_modules(https) -> {ssl, ssl, ranch_ssl, cowboy_tls}.


%% @private used in tests
extract_filter(#cowboy_filter{pid=Pid, host=Host, paths=Paths, ws_proto=Proto}) ->
    {Pid, Host, Paths, Proto}.