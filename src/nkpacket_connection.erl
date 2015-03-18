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

-export([send/2, stop/2, unparse/2, start/1]).
-export([set_timeout/2, get_nkport/1, reset_timeout/1]).
-export([incoming/2, get_all/0, get_all/1, stop_all/0]).
-export([ranch_start_link/2, ranch_init/2]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3,   
            handle_cast/2, handle_info/2]).


-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Sends a new message to a started connection
-spec send(nkpacket:nkport(), nkpacket:raw_msg()) ->
    ok | {error, term()}.

send(#nkport{pid=ConnPid}=NkPort, RawMsg) ->
    case nkpacket_connection_lib:raw_send(NkPort, RawMsg) of
        ok -> 
            reset_timeout(ConnPid);
        {error, Error} ->
            {error, Error}
    end.


%% @doc Performs an unparse using connection context
-spec unparse(nkpacket:nkport(), term()) ->
    {ok, nkpacket:raw_msg()} | {error, term()}. 

unparse(#nkport{pid=ConnPid}, Term) ->
    case catch gen_server:call(ConnPid, {unparse, Term}, infinity) of
        {ok, RawMsg} -> {ok, RawMsg};
        {error, Error} -> {error, Error};
        {'EXIT', Error} -> {error, Error}
    end.


%% @doc Notifies to the connection that some data has been sent or received
-spec reset_timeout(pid()) ->
    ok.

reset_timeout(ConnPid) ->
    gen_server:cast(ConnPid, reset_timeout).


%% @doc Stops a started connection
-spec stop(#nkport{}|pid(), term()) ->
    ok.

stop(#nkport{pid=Pid}, Reason) ->
    stop(Pid, Reason);

stop(Pid, Reason) when is_pid(Pid) ->
    gen_server:cast(Pid, {stop, Reason}).



%% @doc Updates timeout on no incoming packet
-spec set_timeout(pid(), pos_integer()) ->
    ok | error.

set_timeout(Pid, Secs) ->
    case catch gen_server:call(Pid, {set_timeout, Secs}) of
        ok -> ok;
        _ -> error
    end.


%% @private Gets the transport record (and extends the timeout)
-spec get_nkport(pid()) ->
    {ok, nkpacket:nkport()} | error.

get_nkport(Pid) ->
    case is_process_alive(Pid) of
        true ->
            case catch gen_server:call(Pid, get_nkport) of
                {ok, NkPort} -> {ok, NkPort};
                _ -> error
            end;
        false ->
            error 
    end.


%% @private 
-spec incoming(pid(), term()) ->
    ok.

incoming(Pid, Msg) ->
    gen_server:cast(Pid, {incoming, Msg}).


%% @doc Starts a new transport process
-spec start(nkpacket:nkport()) ->
    {ok, pid()} | {error, term()}.

start(NkPort) ->
    #nkport{
        domain = Domain, 
        transp = Transp, 
        remote_ip = Ip, 
        remote_port= Port, 
        meta=Meta
    } = NkPort,
    Spec = {
        {Domain, Transp, Ip, Port, make_ref()},
        {nkpacket_connection, start_link, [NkPort]},
        temporary,
        5000,
        worker,
        [?MODULE]
    },
    nkpacket_sup:add_transport(Spec, Meta).


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
    transp :: nkpacket:transport(),
    nkport :: nkpacket:nkport(),
    socket :: nkpacket_transport:socket(),
    listen_monitor :: reference(),
    srv_monitor :: reference(),
    bridge :: nkpacket:nkport(),
    bridge_type :: up | down,
    bridge_monitor :: reference(),
    ws_state :: term(),
    timeout :: non_neg_integer(),
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
    process_flag(trap_exit, true),          % Allow call to terminate
    NkPort1 = NkPort#nkport{pid=self()},
    Conn = {Protocol, Transp, Ip, Port},
    nklib_proc:put({nkpacket_connection, Domain, Conn}, NkPort1), 
    nklib_proc:put(nkpacket_transports, NkPort1),
    nklib_counters:async([nkpacket_connections, {nkpacket_connections, Domain}]),
    Timeout = maps:get(idle_timeout, Meta, 180000),
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
    WsState = case Meta of
        #{ws_exts:=WsExtensions} ->
            nkpacket_connection_ws:init(WsExtensions);
        _ ->
            undefined
    end,
    {Protocol1, ProtoState1} = case Protocol of
        undefined ->
            {undefined, undefined};
        _ ->
            case catch Protocol:conn_init(NkPort1) of
                {'EXIT', _} -> {undefined, undefined};
                ProtoState -> {Protocol, ProtoState}
            end
    end,
    State = #state{
        transp = Transp,
        nkport = NkPort1, 
        socket = Socket, 
        listen_monitor = ListenMonitor,
        srv_monitor = SrvMonitor,
        bridge = undefined,
        bridge_monitor = undefined,
        ws_state = WsState,
        timeout = Timeout,
        protocol = Protocol1,
        proto_state = ProtoState1
    },
    {ok, State, Timeout}.


%% @private
ranch_init(NkPort, Ref) ->
    ok = proc_lib:init_ack({ok, self()}),
    ok = ranch:accept_ack(Ref),
    {ok, State, Timeout} = init([NkPort]),
    gen_server:enter_loop(?MODULE, [], State, Timeout).


%% @private
-spec handle_call(term(), nklib_util:gen_server_from(), #state{}) ->
    nklib_util:gen_server_call(#state{}).

handle_call({unparse, Msg}, From, State) ->
    case call_protocol(conn_unparse, [Msg], State) of
        {ok, IoList, State1} -> 
            gen_server:reply(From, {ok, IoList}),
            do_noreply(State1);
        {error, Error, State1} ->
            gen_server:reply(From, {error, Error}),
            do_noreply(State1);
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end;

handle_call({set_timeout, MSecs}, From, State) ->
    gen_server:reply(From, ok),
    do_noreply(State#state{timeout=MSecs});

handle_call(get_nkport, From, #state{nkport=NkPort}=State) ->
    gen_server:reply(From, {ok, NkPort}),
    do_noreply(State);

handle_call(Msg, From, State) ->
    case call_protocol(conn_handle_call, [Msg, From], State) of
        {ok, State1} -> do_noreply(State1);
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    nklib_util:gen_server_cast(#state{}).

handle_cast(reset_timeout, State) ->
    do_noreply(State);

handle_cast({incoming, Data}, State) ->
    parse(Data, State);

handle_cast({stop, Reason}, State) ->
    {stop, Reason, State};

handle_cast({bridged, NkPort}, State) ->
    % ?W("Bridged: ~p, ~p", [?PR(NkPort), ?PR(State#state.nkport)]),
    do_noreply(start_bridge(NkPort, down, State));

handle_cast(stop_bridge, #state{bridge_monitor=Mon}=State) ->
    case is_reference(Mon) of
        true -> erlang:demonitor(Mon);
        false -> ok
    end,
    do_noreply(State#state{bridge_monitor=undefined, bridge=undefined});

handle_cast(Msg, State) ->
    case call_protocol(conn_handle_cast, [Msg], State) of
        {ok, State1} -> do_noreply(State1);
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    nklib_util:gen_server_info(#state{}).

handle_info({tcp, Socket, Data}, #state{socket=Socket}=State) ->
    inet:setopts(Socket, [{active, once}]),
    parse(Data, State);

handle_info({ssl, Socket, Data}, #state{socket=Socket}=State) ->
    ssl:setopts(Socket, [{active, once}]),
    parse(Data, State);

handle_info({tcp_closed, _Socket}, State) ->
    case call_protocol(conn_parse, [close], State) of
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

handle_info(timeout, State) ->
    #state{nkport=#nkport{domain=Domain}} = State,
    ?debug(Domain, "Connection timeout", []),
    {stop, normal, State};

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

handle_info(Msg, State) ->
    case call_protocol(conn_handle_info, [Msg], State) of
        {ok, State1} -> do_noreply(State1);
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
    nkpacket_connection_lib:raw_stop(NkPort).



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
            do_noreply(State1);
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
            do_noreply(State1);
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
    case call_protocol(conn_bridge, [Data, Type, To, From], State) of
        {ok, State1} ->
            {ok, State1};
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
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end;

do_parse(Data, State) ->
    case call_protocol(conn_parse, [Data], State) of
        {ok, State1} ->
            {ok, State1};
        {bridge, Bridge, State1} ->
            State2 = start_bridge(Bridge, up, State1),
            {ok, State2};
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
do_noreply(#state{timeout=Timeout}=State) -> 
    {noreply, State, Timeout}.


%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).
