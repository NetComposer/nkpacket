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

-export([start/2, get_all/0, get_servers/3]).
-export([reply/2, reply/3, reply/4]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).
-export([start_link/4, execute/2]).
-export_type([filter/0]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


-type filter() :: 
    #{
        id => term(),           % Mandatory
        module => module(),     % Mandatory
        host => binary(),
        path => binary() | [binary()],
        ws_proto => binary()
    }.

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
-spec start(nkpacket:nkport(), filter()) ->
    {ok, pid()} | {error, term()}.

start(#nkport{pid=Pid}=NkPort, Filter) when is_pid(Pid) ->
    Fun = fun() -> do_start(NkPort, Filter) end,
    #nkport{listen_ip=Ip, listen_port=Port} = NkPort,
    try 
        nklib_proc:try_call(Fun, {?MODULE, Ip, Port}, 100, 50)
    catch
        error:max_tries -> {error, max_tries}
    end.


%% @private
-spec do_start(nkpacket:nkport(), filter()) ->
    {ok, pid()} | {error, term()}.

do_start(#nkport{pid=Pid}=NkPort, Filter) when is_pid(Pid) ->
    #nkport{transp=Transp, listen_ip=Ip, listen_port=Port} = NkPort,
    case nklib_proc:values({?MODULE, Transp, Ip, Port}) of
        [{_Servers, Listen}|_] ->
            case nklib_util:call(Listen, {start, Pid, Filter}, 15000) of
                ok -> {ok, Listen};
                Error -> {error, {shared_failed, Error}}
            end;
        [] ->
            gen_server:start(?MODULE, [NkPort, Filter], [])
    end.


%% @private
-spec get_all() ->
    [{nkpacket:transport(), inet:ip_address(), inet:port_number(), pid(), [filter()]}].

get_all() ->
    [
        {Transp, Ip, Port, Pid, get_servers(Transp, Ip, Port)}
        || {{Transp, Ip, Port}, Pid} <- nklib_proc:values(?MODULE)
    ].


%% @private
-spec get_servers(nkpacket:transport(), inet:ip_address(), inet:port_number()) ->
    [filter()].

get_servers(Transp, Ip, Port) -> 
    case nklib_proc:values({?MODULE, Transp, Ip, Port}) of
        [{Filter, _}|_] -> Filter;
        [] -> []
    end.


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
    servers :: [{filter(), reference()}]
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
            RanchId = {Transp, ListenIp, LocalPort},
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
            nklib_proc:put(?MODULE, {Transp, ListenIp, LocalPort}),
            ListenRef = monitor(process, ListenPid),
            State = #state{
                nkport = Shared,
                ranch_id = RanchId,
                ranch_pid = RanchPid,
                servers = sort_filters([{Filter, ListenRef}])
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

handle_call({start, ListenPid, Filter}, _From, #state{servers=Servers}=State) ->
    ListenRef = erlang:monitor(process, ListenPid),
    Servers1 = sort_filters([{Filter, ListenRef}|Servers]),
    {reply, ok, register(State#state{servers=Servers1})};

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
    #state{servers=Servers} = State,
    case lists:keytake(MRef, 2, Servers) of
        {value, _, []} ->
            % lager:warning("Last server leave"),
            {stop, normal, State};
        {value, {_Filter, Ref}, Servers1} ->
            demonitor(Ref),
            % lager:warning("Server leave"),
            {noreply, register(State#state{servers=Servers1})};
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
    {Transp, Ip, Port} = nklib_util:get_value(?MODULE, Env),
    Servers = get_servers(Transp, Ip, Port),
    execute(Servers, Req, Env).


%% @private 
-spec execute([filter()], cowboy_req:req(), cowboy_middleware:env()) ->
    term().

execute([], Req, _Env) ->
    {stop, reply(404, Req)};

execute([Filter|Rest], Req, Env) ->
    Host = maps:get(host, Filter, any),
    Paths = maps:get(path_list, Filter),
    WsProto = maps:get(ws_proto, Filter, any),
    ReqHost = cowboy_req:host(Req),
    ReqPaths = nkpacket_util:norm_path(cowboy_req:path(Req)),
    ReqWsProto = case cowboy_req:parse_header(?WS_PROTO_HD, Req, []) of
        [ReqWsProto0] -> ReqWsProto0;
        _ -> none
    end,
    case
        (Host==any orelse ReqHost==Host) andalso
        check_paths(ReqPaths, Paths) andalso
        (WsProto==any orelse ReqWsProto==WsProto)
    of
        true ->
            lager:debug("NkPACKET selected: ~p (~p), ~p (~p), ~p (~p)", 
                [ReqHost, Host, ReqPaths, Paths, ReqWsProto, WsProto]),
            Req1 = case WsProto of
                any -> 
                    Req;
                _ -> 
                    cowboy_req:set_resp_header(?WS_PROTO_HD, WsProto, Req)
            end,
            #{id:=Id, module:=Module} = Filter,
            case Module:cowboy_init(Id, Req1, Env) of
                next -> 
                    execute(Rest, Req, Env);
                Result ->
                    Result
            end;
        false ->
            lager:debug("NkPACKET skipping: ~p (~p), ~p (~p), ~p (~p)", 
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
register(#state{nkport=Shared, servers=Servers}=State) ->
    #nkport{transp=Transp, listen_ip=Ip, listen_port=Port} = Shared,
    Filters = [Filter || {Filter, _Ref} <- Servers],
    nklib_proc:put({?MODULE, Transp, Ip, Port}, Filters),
    State.


%% @private
%% Put long paths before short paths
sort_filters(Filters) ->
    Filters1 = [
        {nkpacket_util:norm_path(maps:get(path, Filter, any)), Filter, Ref}
        || {Filter, Ref} <- Filters
    ],
    Filters2 = [
        {Filter#{path_list=>Paths}, Ref} || {Paths, Filter, Ref} <- lists:sort(Filters1)
    ],
    lists:reverse(Filters2).


%% @private
check_paths([Part|Rest1], [Part|Rest2]) ->
    check_paths(Rest1, Rest2);

check_paths(_, []) ->
    true;

check_paths(_A, _B) ->
    false.





%% @private
get_modules(ws) -> {inet, gen_tcp, ranch_tcp};
get_modules(wss) -> {ssl, ssl, ranch_ssl};
get_modules(http) -> {inet, gen_tcp, ranch_tcp};
get_modules(https) -> {ssl, ssl, ranch_ssl}.





