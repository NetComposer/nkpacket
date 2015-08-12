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
        path => binary(),
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
    #nkport{local_ip=Ip, local_port=Port} = NkPort,
    try 
        nklib_proc:try_call(Fun, {?MODULE, Ip, Port}, 100, 50)
    catch
        error:max_tries -> {error, max_tries}
    end.


%% @private
-spec do_start(nkpacket:nkport(), filter()) ->
    {ok, pid()} | {error, term()}.

do_start(#nkport{pid=Pid}=NkPort, Filter) when is_pid(Pid) ->
    #nkport{transp=Transp, local_ip=Ip, local_port=Port} = NkPort,
    case nklib_proc:values({?MODULE, Transp, Ip, Port}) of
        [{_Servers, Listen}|_] ->
            case catch gen_server:call(Listen, {start, Pid, Filter}, infinity) of
                ok -> {ok, Listen};
                _ -> {error, shared_failed}
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
        [{L, _}|_] -> L;
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
        local_ip = Ip, 
        local_port = Port,
        pid = ListenPid,
        meta = Meta
    } = NkPort,
    process_flag(trap_exit, true),   %% Allow calls to terminate
    ListenOpts = listen_opts(NkPort),
    case nkpacket_transport:open_port(NkPort, ListenOpts) of
        {ok, Socket}  ->
            {InetMod, _, RanchMod} = get_modules(Transp),
            {ok, {_, Port1}} = InetMod:sockname(Socket),
            Shared = NkPort#nkport{
                local_port = Port1, 
                listen_ip = Ip,
                listen_port = Port1,
                pid = self(),
                protocol = undefined,
                socket = Socket,
                meta = #{}
            },
            RanchId = {Transp, Ip, Port1},
            Timeout = case Meta of
                #{idle_timeout:=Timeout0} -> 
                    Timeout0;
                _ when Transp==ws; Transp==wss -> 
                    nkpacket_config:ws_timeout();
                _ when Transp==http; Transp==https -> 
                    nkpacket_config:http_timeout()
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
            nklib_proc:put(?MODULE, {Transp, Ip, Port1}),
            ListenRef = monitor(process, ListenPid),
            State = #state{
                nkport = Shared,
                ranch_id = RanchId,
                ranch_pid = RanchPid,
                servers = [{Filter, ListenRef}]
            },
            {ok, register(State)};
        {error, Error} ->
            lager:error("could not start ~p transport on ~p:~p (~p)", 
                   [Transp, Ip, Port, Error]),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, term(), #state{}}.

handle_call({start, ListenPid, Filter}, _From, #state{servers=Servers}=State) ->
    ListenRef = erlang:monitor(process, ListenPid),
    Servers1 = [{Filter, ListenRef}|Servers],
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
    cowboy_protocol:start_link(Ref, Socket, TranspModule, Opts).


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
    Host = maps:get(host, Filter, all),
    Path = maps:get(path, Filter, all),
    WsProto = maps:get(ws_proto, Filter, all),
    ReqHost = cowboy_req:host(Req),
    ReqPath = cowboy_req:path(Req),
    ReqWsProto = case cowboy_req:parse_header(?WS_PROTO_HD, Req, []) of
        [ReqWsProto0] -> ReqWsProto0;
        _ -> none
    end,
    case
        (Host==all orelse ReqHost==Host) andalso
        (Path==all orelse nkpacket_util:check_paths(ReqPath, Path)) andalso
        (WsProto==all orelse ReqWsProto==WsProto)
    of
        true ->
            lager:debug("TRUE: ~p (~p), ~p (~p), ~p (~p)", 
                [ReqHost, Host, ReqPath, Path, ReqWsProto, WsProto]),
            Req1 = case WsProto of
                all -> 
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
            lager:debug("FALSE: ~p (~p), ~p (~p), ~p (~p)", 
                [ReqHost, Host, ReqPath, Path, ReqWsProto, WsProto]),
            execute(Rest, Req, Env)
    end.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private Gets socket options for listening connections
-spec listen_opts(#nkport{}) ->
    list().

listen_opts(#nkport{transp=Transp, local_ip=Ip}) 
        when Transp==ws; Transp==http ->
    [
        {ip, Ip}, {active, false}, binary,
        {nodelay, true}, {keepalive, true},
        {reuseaddr, true}, {backlog, 1024}
    ];

listen_opts(#nkport{transp=Transp, local_ip=Ip, meta=Opts}) 
        when Transp==wss; Transp==https ->
    Base = [
        {ip, Ip}, {active, false}, binary,
        {nodelay, true}, {keepalive, true},
        {reuseaddr, true}, {backlog, 1024}
    ],
    nkpacket_config:add_tls_opts(Base, Opts).


%% @private
register(#state{nkport=Shared, servers=Servers}=State) ->
    #nkport{transp=Transp, local_ip=Ip, local_port=Port} = Shared,
    Filters = [Filter || {Filter, _Ref} <- Servers],
    nklib_proc:put({?MODULE, Transp, Ip, Port}, Filters),
    State.


%% @private
get_modules(ws) -> {inet, gen_tcp, ranch_tcp};
get_modules(wss) -> {ssl, ssl, ranch_ssl};
get_modules(http) -> {inet, gen_tcp, ranch_tcp};
get_modules(https) -> {ssl, ssl, ranch_ssl}.





