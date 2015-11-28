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

%% @private Cowboy support
%% This module implements a "shared" tcp/tls listener.
%% When a new listener request arrives, it is associated to a existing listener,
%% if present. If not, a new one is started.
%% When a new connection arrives, a standard cowboy_protocol is started.
%% It then cycles over all registered listeners, until one of them accepts 
%% the request.

-module(nkpacket_cowboy).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/2, get_all/0, get_filters/2]).
-export([reply/2, reply/3, reply/4]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).
-export([start_link/4, execute/2]).
-export([extract_filter/1]).
-export_type([user_filter/0]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


-type user_filter() :: 
    #{
        id => term(),           % Mandatory
        module => module(),     % Mandatory
        host => binary(),
        path => binary() | [binary()],
        ws_proto => binary()
    }.

-define(WS_PROTO_HD, <<"sec-websocket-protocol">>).


-record(filter, {
    id :: term(),         
    module :: module(),    
    type :: http | ws,
    host :: binary() | all,
    paths :: [binary()],
    ws_proto :: binary() | all,
    mon :: reference()
}).




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
-spec start(nkpacket:nkport(), user_filter()) ->
    {ok, pid()} | {error, term()}.

start(#nkport{pid=Pid}=NkPort, Filter) when is_pid(Pid) ->
    Fun = fun() -> do_start(NkPort, Filter) end,
    #nkport{listen_ip=Ip, listen_port=Port} = NkPort,
    try 
        nklib_proc:try_call(Fun, {?MODULE, Ip, Port}, 100, 50)
    catch
        error:max_tries -> {error, {shared_failed, max_tries}}
    end.


%% @private
-spec do_start(nkpacket:nkport(), user_filter()) ->
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
    [{{inet:ip_address(), inet:port_number()}, pid(), [#filter{}]}].

get_all() ->
    [
        {{Ip, Port}, Pid, get_filters(Ip, Port)}
        || {{Ip, Port}, Pid} <- nklib_proc:values(?MODULE)
    ].


%% @private
-spec get_filters(inet:ip_address(), inet:port_number()) ->
    [#filter{}].

get_filters(Ip, Port) -> 
    % Should be only one
    [{Filters, _}|_] = nklib_proc:values({?MODULE, Ip, Port}),
    Filters.


%% @doc Sends a cowboy reply 
-spec reply(cowboy:http_status(), cowboy_req:req()) -> 
    cowboy_req:req().

reply(Code, Req) ->
    reply(Code, [], Req).


%% @doc Sends a cowboy reply 
-spec reply(cowboy:http_status(), cowboy:http_headers(), cowboy_req:req()) -> 
    cowboy_req:req().

reply(Code, Hds, Req) ->
    cowboy_req:reply(Code, [{<<"server">>, <<"NkPACKET">>}|Hds], Req).


%% @doc Sends a cowboy reply 
-spec reply(cowboy:http_status(), cowboy:http_headers(),
            iodata(), cowboy_req:req()) -> 
    cowboy_req:req().

reply(Code, Hds, Body, Req) ->
    cowboy_req:reply(Code, [{<<"server">>, <<"NkPACKET">>}|Hds], Body, Req).



%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    nkport :: nkpacket:nkport(),
    ranch_id :: term(),
    ranch_pid :: pid(),
    filters :: [#filter{}]
}).


%% @private 
-spec init(term()) ->
    {ok, #state{}} | {stop, term()}.

init([NkPort, Filter]) ->
    #nkport{
        transp = Transp, 
        listen_ip = ListenIp, 
        listen_port = ListenPort,
        pid = ListenPid,
        meta = Meta
    } = NkPort,
    process_flag(trap_exit, true),   %% Allow calls to terminate
    ListenOpts = listen_opts(NkPort),
    case nkpacket_transport:open_port(NkPort, ListenOpts) of
        {ok, Socket}  ->
            {InetMod, _, RanchMod} = get_modules(Transp),
            {ok, {LocalIp, LocalPort}} = InetMod:sockname(Socket),
            Shared = NkPort#nkport{
                local_ip = LocalIp,
                local_port = LocalPort, 
                listen_port = LocalPort,
                pid = self(),
                protocol = undefined,
                socket = Socket,
                meta = #{}
            },
            RanchId = {ListenIp, LocalPort},
            Timeout = case Meta of
                #{idle_timeout:=Timeout0} -> 
                    Timeout0;
                _ when Transp==ws; Transp==wss -> 
                    nkpacket_config_cache:ws_timeout();
                _ when Transp==http; Transp==https -> 
                    nkpacket_config_cache:http_timeout()
            end,
            CowboyOpts1 = maps:get(cowboy_opts, Meta, []),
            CowboyOpts2 = nklib_util:store_values(
                [
                    {env, [{?MODULE, RanchId}]},
                    {middlewares, [?MODULE]},
                    {timeout, Timeout},     % Time to close the connection if no requests
                    {compress, true}        
                ],
                CowboyOpts1),
            {ok, RanchPid} = ranch_listener_sup:start_link(
                RanchId,
                maps:get(tcp_listeners, Meta, 100),
                RanchMod,
                [
                    {socket, Socket}, 
                    {max_connections,  maps:get(tcp_max_connections, Meta, 1024)}
                ],
                ?MODULE,
                CowboyOpts2),
            nklib_proc:put(?MODULE, {ListenIp, LocalPort}),
            State = #state{
                nkport = Shared,
                ranch_id = RanchId,
                ranch_pid = RanchPid,
                filters = [make_filter(Filter, ListenPid, Transp)]
            },
            {ok, register(State)};
        {error, Error} ->
            lager:error("could not start ~p transport on ~p:~p (~p)", 
                   [Transp, ListenIp, ListenPort, Error]),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, term(), #state{}}.

handle_call({start, ListenPid, Transp, Filter}, _From, State) ->
    #state{filters=Filters, nkport=#nkport{transp=BaseTransp}} = State,
    case secure(Transp)==secure(BaseTransp) of
        true ->
            Filter1 = make_filter(Filter, ListenPid, Transp),
            Filters1 = sort_filters([Filter1|Filters]),
            {reply, ok, register(State#state{filters=Filters1})};
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
    case lists:keytake(MRef, #filter.mon, Filters) of
        {value, _, []} ->
            % lager:debug("Last server leave"),
            {stop, normal, State};
        {value, _, Filters1} ->
            % lager:debug("Server leave"),
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
    lager:debug("Cowboy listener stop: ~p", [Reason]),
    #state{
        ranch_id = RanchId,
        nkport = #nkport{transp=Transp, socket=Socket}
    } = State,
    exit(RanchPid, shutdown),
    timer:sleep(100),   %% Give time to ranch to close acceptors
    catch ranch_server:cleanup_listener_opts(RanchId),
    {_, TranspMod, _} = get_modules(Transp),
    TranspMod:close(Socket),
    ok.


%% ===================================================================
%% Ranch Callbacks
%% ===================================================================


%% @private Ranch's callback, called for every new inbound connection
%% to create a new process to manage it
-spec start_link(term(), term(), atom(), term()) ->
    {ok, pid()}.

start_link(Ref, Socket, TranspModule, Opts) ->
    % Now Cowboy will call execute/2
    % {ok, spawn_link(fun() -> start_cowboy(Ref, Socket, TranspModule, Opts) end)}.
   cowboy_protocol:start_link(Ref, Socket, TranspModule, Opts).


% Cowboy fails when raw bytes are sent to the connection
%
% start_cowboy(Ref, Socket, TranspModule, Opts) ->
%     process_flag(trap_exit, true),
%     {ok, Pid} = cowboy_protocol:start_link(Ref, Socket, TranspModule, Opts),
%     start_cowboy_wait(Pid).

% start_cowboy_wait(Pid) ->
%     receive
%         {'EXIT', Pid, Reason} ->
%             lager:warning("COWBOY EXIT: ~p", [Reason]);
%         Other ->
%             lager:warning("OTHER: ~p", [Other]),
%             Pid ! Other,
%             start_cowboy_wait(Pid)
%     after 
%         30000 ->
%             lager:warning("COWBOY EXIT!!")
%     end.


%% @private Cowboy middleware callback
-spec execute(Req, Env)-> 
    {ok, Req, Env} | {stop, Req}
    when Req::cowboy_req:req(), Env::cowboy_middleware:env().

execute(Req, Env) ->
    {Ip, Port} = nklib_util:get_value(?MODULE, Env),
    Filters = get_filters(Ip, Port),
    execute(Filters, Req, Env).


%% @private 
-spec execute([#filter{}], cowboy_req:req(), cowboy_middleware:env()) ->
    term().

execute([], Req, _Env) ->
    lager:info("NkPACKET Cowboy: url ~s not matched", [cowboy_req:path(Req)]),
    {stop, reply(404, Req)};

execute([Filter|Rest], Req, Env) ->
    #filter{
        id = Id,
        module = Module,
        type = Type,
        host = Host,
        paths = Paths,
        ws_proto = WsProto
    } = Filter,
    ReqType = case cowboy_req:parse_header(<<"upgrade">>, Req, []) of
        [<<"websocket">>] -> ws;
        _ -> http
    end,
    ReqHost = cowboy_req:host(Req),
    ReqPaths = nkpacket_util:norm_path(cowboy_req:path(Req)),
    ReqWsProto = case cowboy_req:parse_header(?WS_PROTO_HD, Req, []) of
        [ReqWsProto0] -> ReqWsProto0;
        _ -> none
    end,
    case
        (Type == ReqType) andalso
        (Host==any orelse ReqHost==Host) andalso
        (WsProto==any orelse ReqWsProto==WsProto) andalso
        check_paths(ReqPaths, Paths)
    of
        true ->
            lager:debug("NkPACKET Web Selected: ~p (~p), ~p (~p), ~p (~p)", 
                [ReqHost, Host, ReqPaths, Paths, ReqWsProto, WsProto]),
            Req1 = case WsProto of
                any -> 
                    Req;
                _ -> 
                    cowboy_req:set_resp_header(?WS_PROTO_HD, WsProto, Req)
            end,
            case Module:cowboy_init(Id, Req1, Env) of
                next -> 
                    execute(Rest, Req, Env);
                Result ->
                    Result
            end;
        false ->
            lager:debug("NkPACKET Web Skipping: ~p (~p), ~p (~p), ~p (~p)", 
                [ReqHost, Host, ReqPaths, Paths, ReqWsProto, WsProto]),
            execute(Rest, Req, Env)
    end.



%% ===================================================================
%% Internal
%% ===================================================================


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

listen_opts(#nkport{transp=Transp, listen_ip=Ip, meta=Opts}) 
        when Transp==wss; Transp==https ->
    [
        {ip, Ip}, {active, false}, binary,
        {nodelay, true}, {keepalive, true},
        {reuseaddr, true}, {backlog, 1024}
    ]
    ++ nkpacket_util:make_tls_opts(Opts).


%% @private
register(#state{nkport=Shared, filters=Filters}=State) ->
    #nkport{listen_ip=Ip, listen_port=Port} = Shared,
    nklib_proc:put({?MODULE, Ip, Port}, Filters),
    State.


%% @private
%% Put long paths before short paths
sort_filters(Filters) ->
    lists:reverse(lists:keysort(#filter.paths, Filters)).


%% @private
check_paths([Part|Rest1], [Part|Rest2]) ->
    check_paths(Rest1, Rest2);

check_paths(_, []) ->
    true;

check_paths(_A, _B) ->
    false.


%% @private
make_filter(Filter, ListenPid, Transp) ->
    Type = case Transp of
        http -> http;
        https -> http;
        ws -> ws;
        wss -> ws
    end,
    #filter{
        id = maps:get(id, Filter),
        module = maps:get(module, Filter),
        type = Type,
        host = maps:get(host, Filter, any),
        paths = nkpacket_util:norm_path(maps:get(path, Filter, any)),
        ws_proto = maps:get(ws_proto, Filter, any),
        mon = monitor(process, ListenPid)
    }.


%% @private
secure(ws) -> false;
secure(wss) -> true;
secure(http) -> false;
secure(https) -> true.


%% @private
get_modules(ws) -> {inet, gen_tcp, ranch_tcp};
get_modules(wss) -> {ssl, ssl, ranch_ssl};
get_modules(http) -> {inet, gen_tcp, ranch_tcp};
get_modules(https) -> {ssl, ssl, ranch_ssl}.


%% @private used in tests
extract_filter(#filter{id=Id, host=Host, paths=Paths, ws_proto=Proto}) ->
    {Id, Host, Paths, Proto}.