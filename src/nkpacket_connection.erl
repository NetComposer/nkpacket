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

%% @doc Generic tranport connection process
-module(nkpacket_connection).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([send/2, async_send/2, stop/1, stop/2, encode/2, start/1]).
-export([reset_timeout/2, get_timeout/1]).
-export([incoming/2, get_all/0, get_all/1, stop_all/0]).
-export([connect/1, conn_init/1]).
-export([ranch_start_link/2, ranch_init/2]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3,   
            handle_cast/2, handle_info/2]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new transport process for an already started connection
-spec start(nkpacket:nkport()) ->
    {ok, nkpacket:nkport()} | {error, term()}.

start(#nkport{domain=Domain}=NkPort) ->
    case nkpacket_connection_lib:is_max(Domain) of
        false -> 
            % Connection will monitor pid() in NkPort and option 'monitor'
            case gen_server:start(?MODULE, [NkPort], []) of
                {ok, Pid} ->
                    {ok, NkPort#nkport{pid=Pid}};
                {error, Error} ->
                    {error, Error}
            end;
        true ->
            {error, max_connections}
    end.


%% @doc Starts a new outbound connection
-spec connect(nkpacket:nkport()) ->
    {ok, nkpacket:nkport()} | {error, term()}.
        
connect(#nkport{transp=udp, pid=Pid}=NkPort) ->
    case is_pid(Pid) of
        true -> nkpacket_transport_udp:connect(NkPort);
        false -> {error, no_listening_transport}
    end;
        
connect(#nkport{transp=sctp, pid=Pid}=NkPort) ->
    case is_pid(Pid) of
        true -> nkpacket_transport_sctp:connect(NkPort);
        false -> {error, no_listening_transport}
    end;

connect(#nkport{transp=Transp}) when Transp==http; Transp==https ->
    {error, not_supported};

connect(#nkport{domain=Domain}=NkPort) ->
    case nkpacket_connection_lib:is_max(Domain) of
        false -> 
            case proc_lib:start(?MODULE, conn_init, [NkPort]) of
                {ok, _Pid, NkPort1} -> {ok, NkPort1};
                {error, Error} -> {error, Error}
            end;
        true ->
            {error, max_connections}
    end.


%% @doc Sends a new message to a started connection
-spec send(nkpacket:nkport()|pid(), nkpacket:outcoming()) ->
    ok | {error, term()}.

send(#nkport{pid=ConnPid}=NkPort, OutMsg) ->
    case nkpacket_connection_lib:raw_send(NkPort, OutMsg) of
        ok -> 
            reset_timeout(ConnPid);
        {error, Error} ->
            {error, Error}
    end;

send(Pid, OutMsg) when is_pid(Pid) ->
    case catch gen_server:call(Pid, {send, OutMsg}, ?CALL_TIMEOUT) of
        {'EXIT', _} -> {error, no_process};
        Other -> Other
    end.


%% @doc Sends a message to a started connection
-spec async_send(pid(), nkpacket:outcoming()) ->
    ok.

async_send(Pid, OutMsg) when is_pid(Pid) ->
    gen_server:cast(Pid, {send, OutMsg}).


%% @doc Performs an encode using connection context
-spec encode(nkpacket:nkport()|pid(), term()) ->
    {ok, nkpacket:outcoming()} | {error, term()}. 

encode(Conn, Term) ->
    case catch gen_server:call(get_pid(Conn), {encode, Term}, ?CALL_TIMEOUT) of
        {ok, OutMsg} -> {ok, OutMsg};
        {error, Error} -> {error, Error};
        {'EXIT', Error} -> {error, Error}
    end.


%% @doc Stops a started connection with reason 'normal'
-spec stop(#nkport{}|pid()) ->
    ok.

stop(Conn) ->
    stop(Conn, normal).


%% @doc Stops a started connection
-spec stop(#nkport{}|pid(), term()) ->
    ok.

stop(Conn, Reason) ->
    gen_server:cast(get_pid(Conn), {stop, Reason}).


%% @doc Re-start the idle timeout
-spec reset_timeout(nkpacket:nkport()|pid()) ->
    ok.

reset_timeout(Conn) ->
    gen_server:cast(get_pid(Conn), reset_timeout).


%% @doc Re-starts the idle timeout with new time
-spec reset_timeout(nkpacket:nkport()|pid(), pos_integer()) ->
    ok | error.

reset_timeout(Conn, MSecs) ->
    case catch gen_server:call(get_pid(Conn), {reset_timeout, MSecs}, ?CALL_TIMEOUT) of
        ok -> ok;
        _ -> error
    end.


%% @doc Reads the remaining time to timeout
-spec get_timeout(nkpacket:nkport()|pid()) ->
    ok.

get_timeout(Conn) ->
    gen_server:call(get_pid(Conn), get_timeout, ?CALL_TIMEOUT).


%% @private 
-spec incoming(nkpacket:nkport()|pid(), term()) ->
    ok.

incoming(Conn, Msg) ->
    gen_server:cast(get_pid(Conn), {incoming, Msg}).


%% @private
-spec start_link(nkpacket:nkport()) ->
    {ok, pid()}.

start_link(NkPort) -> 
    gen_server:start_link(?MODULE, [NkPort], []).


%% @private Ranch's entry point (see nkpacket_transport_tcp:start_link/4)
ranch_start_link(NkPort, Ref) ->
    proc_lib:start_link(?MODULE, ranch_init, [NkPort, Ref]).


%% ===================================================================
%% Only testing
%% ===================================================================

%% @private
get_all() ->
    nklib_proc:fold_names(
        fun(Name, Values, Acc) ->
            case Name of
                {nkpacket_connection, _, _} -> 
                    [NkPort || {val, NkPort, _Pid} <- Values] ++ Acc;
                _ ->
                    Acc
            end
        end,
        []).


%% @private
get_all(Domain) ->
    [NkPort || #nkport{domain=D}=NkPort <- get_all(), D==Domain].


%% @private
stop_all() ->
    lists:foreach(
        fun(#nkport{pid=Pid}) -> nkpacket_connection:stop(Pid, normal) end,
        get_all()).




%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    nkport :: nkpacket:nkport(),
    transp :: nkpacket:transport(),
    socket :: nkpacket_transport:socket(),
    listen_monitor :: reference(),
    srv_monitor :: reference(),
    user_monitor :: reference(),
    bridge :: nkpacket:nkport(),
    bridge_type :: up | down,
    bridge_monitor :: reference(),
    ws_state :: term(),
    timeout :: non_neg_integer(),
    timeout_timer :: reference(),
    refresh_fun :: fun((nkpacket:nkport()) -> boolean()),
    protocol :: atom(),
    proto_state :: term()
}).


%% @private 
-spec init(term()) ->
    nklib_util:gen_server_init(#state{}).

init([NkPort]) ->
    #nkport{
        domain = Domain,
        transp = Transp, 
        remote_ip = Ip, 
        remote_port = Port, 
        protocol = Protocol,
        pid = ListenPid,
        socket = Socket,
        meta = Meta
    } = NkPort,
    process_flag(trap_exit, true),          % Allow call to terminate/2
    NkPort1 = NkPort#nkport{pid=self()},
    Conn = {Protocol, Transp, Ip, Port},
    StoredNkPort = NkPort1#nkport{meta=maps:with([path], Meta)},
    nklib_proc:put({nkpacket_connection, Domain, Conn}, StoredNkPort), 
    nklib_proc:put(nkpacket_transports, StoredNkPort),
    nklib_counters:async([nkpacket_connections, {nkpacket_connections, Domain}]),
    Timeout = case maps:get(idle_timeout, Meta, undefined) of
        Timeout0 when is_integer(Timeout0) -> 
            Timeout0;
        undefined ->
            case Transp of
                udp -> nkpacket_config_cache:udp_timeout(Domain);
                tcp -> nkpacket_config_cache:tcp_timeout(Domain);
                tls -> nkpacket_config_cache:tcp_timeout(Domain);
                sctp -> nkpacket_config_cache:sctp_timeout(Domain);
                ws -> nkpacket_config_cache:ws_timeout(Domain);
                wss -> nkpacket_config_cache:ws_timeout(Domain);
                http -> nkpacket_config_cache:http_timeout(Domain);
                https -> nkpacket_config_cache:http_timeout(Domain)
            end
    end,
    ?debug(Domain, "created ~p connection ~p (~p, ~p) ~p", 
           [Transp, {Ip, Port}, Protocol, self(), Meta]),
    ListenMonitor = case is_pid(ListenPid) of
        true -> erlang:monitor(process, ListenPid);
        _ -> undefined
    end,
    SrvMonitor = case is_pid(Socket) of
        true -> erlang:monitor(process, Socket);
        _ -> undefined
    end,
    UserMonitor = case Meta of
        #{monitor:=UserRef} -> erlang:monitor(process, UserRef);
        _ -> undefined
    end,
    WsState = case Transp==ws orelse Transp==wss of
        true -> nkpacket_connection_ws:init(#{});
        _ -> undefined
    end,
    State = #state{
        transp = Transp,
        nkport = StoredNkPort, 
        socket = Socket, 
        listen_monitor = ListenMonitor,
        srv_monitor = SrvMonitor,
        user_monitor = UserMonitor,
        bridge = undefined,
        bridge_monitor = undefined,
        ws_state = WsState,
        timeout = Timeout,
        refresh_fun = maps:get(refresh_fun, Meta, undefined),
        protocol = Protocol
    },
    case nkpacket_util:init_protocol(Protocol, conn_init, NkPort1) of
        {ok, ProtoState} ->
            State1 = State#state{proto_state=ProtoState},
            {ok, restart_timer(State1)};
        {bridge, Bridge, ProtoState} ->
            State1 = State#state{proto_state=ProtoState},
            State2 = start_bridge(Bridge, up, State1),
            {ok, restart_timer(State2)};
        {stop, Reason} ->
            gen_server:cast(self(), {stop, Reason}),
            {ok, State}
    end.


%% @private
ranch_init(NkPort, Ref) ->
    ok = proc_lib:init_ack({ok, self()}),
    ok = ranch:accept_ack(Ref),
    {ok, State} = init([NkPort]),
    gen_server:enter_loop(?MODULE, [], State).


%% @private
conn_init(#nkport{transp=Transp}=NkPort) when Transp==tcp; Transp==tls ->
    case nkpacket_transport_tcp:connect(NkPort) of
        {ok, NkPort1} ->
            {ok, #state{nkport=NkPort2}=State} = init([NkPort1]),
            ok = proc_lib:init_ack({ok, self(), NkPort2}),
            gen_server:enter_loop(?MODULE, [], State);
        {error, Error} ->
            proc_lib:init_ack({error, Error})
    end;

conn_init(#nkport{transp=Transp}=NkPort) when Transp==ws; Transp==wss ->
    case nkpacket_transport_ws:connect(NkPort) of
        {ok, NkPort1, Rest} ->
            {ok, #state{nkport=NkPort2}=State} = init([NkPort1]),
            case Rest of
                <<>> -> ok;
                _ -> incoming(self(), Rest)
            end,
            ok = proc_lib:init_ack({ok, self(), NkPort2}),
            gen_server:enter_loop(?MODULE, [], State);
        {error, Error} ->
            proc_lib:init_ack({error, Error})
    end.


%% @private
-spec handle_call(term(), nklib_util:gen_server_from(), #state{}) ->
    nklib_util:gen_server_call(#state{}).

handle_call(get_nkport, _From, #state{nkport=NkPort}=State) ->
    {reply, {ok, NkPort}, State};

handle_call(get_local, _From, #state{nkport=NkPort}=State) ->
    {reply, nkpacket:get_local(NkPort), State};

handle_call(get_remote, _From, #state{nkport=NkPort}=State) ->
    {reply, nkpacket:get_remote(NkPort), State};

handle_call(get_user, _From, #state{nkport=NkPort}=State) ->
    {reply, nkpacket:get_user(NkPort), State};

handle_call({encode, Msg}, _From, State) ->
    case call_protocol(conn_encode, [Msg], State) of
        undefined ->
            {reply, {error, undefined_protocol}, State};
        {ok, OutMsg, State1} -> 
            {reply, {ok, OutMsg}, State1};
        {error, Error, State1} ->
            {reply, {error, Error}, State1};
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end;

handle_call({reset_timeout, MSecs}, _From, State) ->
    {reply, ok, restart_timer(State#state{timeout=MSecs})};

handle_call(get_timeout, _From, #state{timeout_timer=Ref}=State) ->
    Reply = case is_reference(Ref) of 
        true ->
            case erlang:read_timer(Ref) of
                false -> undefined;
                Time -> Time
            end;
        false ->
            undefined
    end,
    {reply, Reply, State};

handle_call({send, OutMsg}, _From, #state{nkport=NkPort}=State) ->
    Reply = nkpacket_connection_lib:raw_send(NkPort, OutMsg),
    {reply, Reply, restart_timer(State)};

handle_call(Msg, From, State) ->
    case call_protocol(conn_handle_call, [Msg, From], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    nklib_util:gen_server_cast(#state{}).

handle_cast({send, OutMsg}, #state{nkport=NkPort}=State) ->
    nkpacket_connection_lib:raw_send(NkPort, OutMsg),
    {noreply, restart_timer(State)};

handle_cast(reset_timeout, State) ->
    {noreply, restart_timer(State)};

handle_cast({incoming, Data}, State) ->
    parse(Data, restart_timer(State));

handle_cast({stop, Reason}, State) ->
    {stop, Reason, State};

handle_cast({bridged, Bridge}, State) ->
    lager:debug("Bridged: ~p, ~p", [?PR(Bridge), ?PR(State#state.nkport)]),
    {noreply, start_bridge(Bridge, down, State)};

handle_cast({stop_bridge, Pid}, #state{bridge=#nkport{pid=Pid}}=State) ->
    lager:debug("UnBridged: ~p, ~p", [Pid, ?PR(State#state.nkport)]),
    #state{bridge_monitor=Mon} = State, 
    case is_reference(Mon) of
        true -> erlang:demonitor(Mon);
        false -> ok
    end,
    {noreply, State#state{bridge_monitor=undefined, bridge=undefined}};

handle_cast({stop_bridge, Pid}, State) ->
    lager:warning("Received unbridge for unknown bridge ~p", [Pid]),
    {noreply, State};

handle_cast(Msg, State) ->
    case call_protocol(conn_handle_cast, [Msg], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    nklib_util:gen_server_info(#state{}).

handle_info({tcp, Socket, Data}, #state{socket=Socket}=State) ->
    inet:setopts(Socket, [{active, once}]),
    parse(Data, restart_timer(State));

handle_info({ssl, Socket, Data}, #state{socket=Socket}=State) ->
    ssl:setopts(Socket, [{active, once}]),
    parse(Data, restart_timer(State));

handle_info({tcp_closed, _Socket}, State) ->
    case call_protocol(conn_parse, [close], State) of
        undefined -> 
            {stop, normal, State};
        {ok, State1} ->
            {stop, normal, State1};
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end;
    
handle_info({tcp_error, _Socket}, State) ->
    {stop, normal, State};

handle_info({ssl_closed, _Socket}, State) ->
    handle_info({tcp_closed, none}, State);

handle_info({ssl_error, _Socket}, State) ->
    {stop, normal, State};

handle_info({timeout, _, idle_timer}, State) ->
    #state{nkport=#nkport{domain=Domain}=NkPort, refresh_fun=Fun} = State,
    case is_function(Fun, 1) of
        true ->
            case Fun(NkPort) of
                true -> {noreply, restart_timer(State)};
                false -> {stop, normal, State}
            end;
        false ->
            ?debug(Domain, "Connection timeout", []),
            {stop, normal, State}
    end;

handle_info({'DOWN', MRef, process, _Pid, Reason}, #state{bridge_monitor=MRef}=State) ->
    case Reason of
        normal -> {stop, normal, State};
        _ -> {stop, {bridge_down, Reason}, State}
    end;

handle_info({'DOWN', MRef, process, _Pid, _Reason}, #state{listen_monitor=MRef}=State) ->
    #state{nkport=#nkport{domain=Domain}} = State,
    ?debug(Domain, "Connection stop (listener stop)", []),
    {stop, normal, State};

handle_info({'DOWN', MRef, process, _Pid, _Reason}, #state{srv_monitor=MRef}=State) ->
    #state{nkport=#nkport{domain=Domain}} = State,
    ?debug(Domain, "Connection stop (server stop)", []),
    {stop, normal, State};

handle_info({'DOWN', MRef, process, _Pid, _Reason}, #state{user_monitor=MRef}=State) ->
    #state{nkport=#nkport{domain=Domain}} = State,
    ?debug(Domain, "Connection stop (user stop)", []),
    {stop, normal, State};

handle_info(Msg, State) ->
    case call_protocol(conn_handle_info, [Msg], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec code_change(term(), #state{}, term()) ->
    nklib_util:gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    nklib_util:gen_server_terminate().

terminate(Reason, State) ->
    #state{
        transp = Transp, 
        nkport = #nkport{domain=Domain} = NkPort
    } = State,
    catch call_protocol(conn_stop, [Reason], State),
    ?debug(Domain, "Connection ~p process stopped (~p, ~p)", 
           [Transp, Reason, self()]),
    % Sometimes ssl sockets are slow to close here
    spawn(fun() -> nkpacket_connection_lib:raw_stop(NkPort) end),
    ok.




%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec parse(term(), #state{}) ->
    nklib_util:gen_server_info(#state{}).

parse(Data, #state{transp=Transp, socket=Socket}=State) 
        when not is_pid(Socket) andalso (Transp==ws orelse Transp==wss) ->
    #state{ws_state=WsState, nkport=NkPort} = State,
    case nkpacket_connection_ws:handle(Data, WsState) of
        {ok, WsState1} -> 
            State1 = State#state{ws_state=WsState1},
            {noreply, State1};
        {data, Frame, Rest, WsState1} ->
            State1 = State#state{ws_state=WsState1},
            case do_parse(Frame, State1) of
                {ok, State2} ->
                    parse(Rest, State2);
                {stop, Reason, State2} ->
                    {stop, Reason, State2}
            end;
        {reply, Frame, Rest, WsState1} ->
            case nkpacket_connection_lib:raw_send(NkPort, Frame) of
                ok when element(1, Frame)==close ->
                    {stop, normal, State};
                ok ->
                    parse(Rest, State#state{ws_state=WsState1});
                {error, Error} ->
                    {stop, Error, State}
            end;
        close ->
            {stop, normal, State}
    end;

parse(Data, State) ->
    case do_parse(Data, State) of
        {ok, State1} ->
            {noreply, State1};
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end.


-spec do_parse(term(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

do_parse(Data, #state{bridge=#nkport{}=To}=State) ->
    #state{
        bridge_type = Type, 
        nkport = #nkport{domain=Domain} = From
    } = State,
    case Type of
        up ->
            #nkport{local_ip=FromIp, local_port=FromPort} = From,
            #nkport{remote_ip=ToIp, remote_port=ToPort} = To;
        down ->
            #nkport{remote_ip=FromIp, remote_port=FromPort} = From,
            #nkport{local_ip=ToIp, local_port=ToPort} = To
    end,
    case call_protocol(conn_bridge, [Data, Type], State) of
        undefined ->
            case nkpacket_connection:send(To, Data) of
                ok ->
                    ?debug(Domain, "Packet ~p bridged from ~p:~p to ~p:~p", 
                          [Data, FromIp, FromPort, ToIp, ToPort]),
                    {ok, State};
                {error, Error} ->
                    ?notice(Domain, "Packet ~p could not be bridged from ~p:~p to ~p:~p", 
                           [Data, FromIp, FromPort, ToIp, ToPort]),
                    {stop, Error, State}
            end;
        {ok, Data1, State1} ->
            case nkpacket_connection:send(To, Data1) of
                ok ->
                    ?debug(Domain, "Packet ~p bridged from ~p:~p to ~p:~p", 
                          [Data1, FromIp, FromPort, ToIp, ToPort]),
                    {ok, State1};
                {error, Error} ->
                    ?notice(Domain, "Packet ~p could not be bridged from ~p:~p to ~p:~p", 
                          [Data1, FromIp, FromPort, ToIp, ToPort]),
                    {stop, Error, State1}
            end;
        {skip, State1} ->
            {ok, State1};
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end;

do_parse(Data, #state{nkport=#nkport{domain=Domain, protocol=Protocol}}=State) ->
    case call_protocol(conn_parse, [Data], State) of
        undefined ->
            ?warning(Domain, "Received data for undefined protocol ~p", [Protocol]),
            {ok, State};
        {ok, State1} ->
            {ok, State1};
        {bridge, Bridge, State1} ->
            State2 = start_bridge(Bridge, up, State1),
            do_parse(Data, State2);
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end.


%% @private
-spec start_bridge(nkpacket:nkport(), up|down, #state{}) ->
    #state{}.

start_bridge(Bridge, Type, State) ->
    #nkport{pid=BridgePid} = Bridge,
    #state{bridge_monitor=OldMon, bridge=OldBridge, nkport=NkPort} = State,
    #nkport{domain=Domain} = NkPort,
    case Type of 
        up ->
            #nkport{local_ip=FromIp, local_port=FromPort} = NkPort,
            #nkport{remote_ip=ToIp, remote_port=ToPort} = Bridge;
        down ->
            #nkport{remote_ip=FromIp, remote_port=FromPort} = NkPort,
            #nkport{local_ip=ToIp, local_port=ToPort} = Bridge
    end,
    case OldBridge of
        undefined ->
            ?info(Domain, "Connection ~p started bridge ~p from ~p:~p to ~p:~p",
                  [self(), Type, FromIp, FromPort, ToIp, ToPort]),
            Mon = erlang:monitor(process, BridgePid),
            case Type of
                up -> gen_server:cast(BridgePid, {bridged, NkPort});
                down -> ok
            end,
            State#state{bridge=Bridge, bridge_monitor=Mon, bridge_type=Type};
        #nkport{pid=BridgePid} ->
            State;
        #nkport{pid=OldPid} ->
            erlang:demonitor(OldMon),
            gen_server:cast(OldPid, stop_bridge),
            start_bridge(Bridge, Type, State#state{bridge=undefined})
    end.


%% @private
get_pid(#nkport{pid=Pid}) -> Pid;
get_pid(Pid) when is_pid(Pid) -> Pid.


%% @private
restart_timer(#state{timeout=Timeout, timeout_timer=Ref}=State) ->
    nklib_util:cancel_timer(Ref),
    Timer = erlang:start_timer(Timeout, self(), idle_timer),
    State#state{timeout_timer=Timer}.


%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).
