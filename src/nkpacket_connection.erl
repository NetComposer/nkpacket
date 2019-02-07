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

%% @doc Generic transport connection process
-module(nkpacket_connection).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([send/2, send_async/2, stop/1, stop/2, start/1]).
-export([reset_timeout/2, get_timeout/1, update_monitor/2]).
-export([get_all/0, get_all_class/1, get_all_classes/0, stop_all/0, stop_all/1]).
-export([incoming/2, connect/1, conn_init/1]).
-export([ranch_start_link/2, ranch_init/2]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3,   
            handle_cast/2, handle_info/2]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").

-define(CALL_TIMEOUT, 180000).

%% To get debug info, the current process must have 'nkpacket_debug=true'


-define(DEBUG(Txt, Args, NkPort),
    case erlang:get(nkpacket_debug) of
        true -> ?LLOG(debug, Txt, Args, NkPort);
        _ -> ok
    end).


-define(LLOG(Type, Txt, Args, NkPort), 
        lager:Type("NkPACKET Conn ~p (~p) "++Txt, 
                   [NkPort#nkport.protocol, NkPort#nkport.transp|Args])).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new transport process for an already started connection
-spec start(nkpacket:nkport()) ->
    {ok, pid()} | {error, term()}.

start(#nkport{}=NkPort) ->
    case nkpacket_connection_lib:is_max() of
        false -> 
            % Connection will monitor pid() in NkPort and option 'monitor'
            gen_server:start(?MODULE, [NkPort], []);
        true ->
            {error, max_connections}
    end.


%% @doc Starts a new outbound connection
%%


-spec connect(nkpacket:nkport()) ->
    {ok, #nkport{}} | {error, term()}.
        
connect(#nkport{transp=udp, pid=Pid}=NkPort) ->
    case is_pid(Pid) of
        true ->
            nkpacket_transport_udp:connect(NkPort);
        false ->
            {error, no_listening_transport}
    end;
        
connect(#nkport{transp=sctp, pid=Pid}=NkPort) ->
    case is_pid(Pid) of
        true ->
            nkpacket_transport_sctp:connect(NkPort);
        false ->
            {error, no_listening_transport}
    end;

connect(#nkport{transp=Transp}=NkPort)
        when Transp==tcp; Transp==tls; Transp==ws; Transp==wss ->
    case nkpacket_connection_lib:is_max() of
        false ->
            proc_lib:start(?MODULE, conn_init, [NkPort]);
        true ->
            {error, max_connections}
    end;

% HTTP client is an included 'user' protocol, managed here as a 'pseudo transport'
connect(#nkport{transp=Transp}=NkPort) when Transp==http; Transp==https ->
    case nkpacket_connection_lib:is_max() of
        false ->
            proc_lib:start(?MODULE, conn_init, [NkPort]);
        true ->
            {error, max_connections}
    end.


%% @doc Sends a new message to a started connection
%% If we provide a #nkport{}, we will send the message directly to the socket
%% If it is pid(), a message is sent to the connection
%% If Msg is a function/1, it will be called as Msg(NkPort) and the resulting message
%% will be returned
-spec send(nkpacket:nkport()|pid(), term()) ->
    ok | {ok, term()} | {error, term()}.

send(#nkport{protocol=Protocol, pid=Pid}=NkPort, Msg) when node(Pid)==node() ->
    case erlang:function_exported(Protocol, conn_encode, 2) of
        true ->
            % Perform an out-of-band send
            {Updated, Msg2} = update_msg(Msg, NkPort),
            case Protocol:conn_encode(Msg2, NkPort) of
                {ok, OutMsg} ->
                    % If we calling inside the connection process, the 
                    % nkpacket_debug tag will be present
                    % Otherwise, we need to set it or add check to #nkport.meta
                    % (debug should be present there)
                    ?DEBUG("raw DIRECT socket send: ~p", [OutMsg], NkPort),
                    case nkpacket_connection_lib:raw_send(NkPort, OutMsg) of
                        ok when Updated ->
                            reset_timeout(Pid),
                            {ok, Msg2};
                        ok ->
                            reset_timeout(Pid),
                            ok;
                        {error, Error} ->
                            {error, Error}
                    end;
                continue when is_pid(Pid) ->
                    send(Pid, Msg);
                {error, Error} ->
                    lager:notice("NkPACKET Conn error unparsing msg: ~p", [Error]),
                    {error, encode_error}
            end;
        false when is_pid(Pid) ->
            % Perform an in-band send
            send(Pid, Msg)
    end;

send(Pid, _Msg) when Pid==self() ->
    {error, same_process};

send(Pid, Msg) when is_pid(Pid) ->
    case catch gen_server:call(Pid, {nkpacket_send, Msg}, 180000) of
        {'EXIT', _} ->
            {error, no_process};
        Other ->
            Other
    end.


%% @private
-spec update_msg(term(), #nkport{}) ->
    term().

update_msg(Msg, NkPort) when is_function(Msg, 1) ->
    {true, Msg(NkPort)};

update_msg(Msg, _NkPort) ->
    {false, Msg}.



%% @doc Sends a new message to a started connection
-spec send_async(pid(), term()) ->
    ok.

%% @private
send_async(Pid, Msg) when is_pid(Pid) ->
    gen_server:cast(Pid, {nkpacket_send, Msg}).


%% @doc Stops a started connection with reason 'normal'
-spec stop(#nkport{}|pid()) ->
    ok.

stop(Conn) ->
    stop(Conn, normal).


%% @doc Stops a started connection
-spec stop(#nkport{}|pid(), term()) ->
    ok.

stop(Conn, Reason) ->
    gen_server:cast(get_pid(Conn), {nkpacket_stop, Reason}).


%% @doc Gets all started connections
-spec get_all() ->
    [{nkpacket:id(), nkpacket:class(), pid()}].

get_all() ->
    [{Id, Class, Pid} || {{Id, Class}, Pid} <- nklib_proc:values(nkpacket_connections)].


%% @doc Gets all started connections for a class.
-spec get_all_class(nkpacket:class()) ->
    [{nkpacket:id(), pid()}].

get_all_class(Class) ->
    [{Id, Pid} || {Id, S, Pid} <- get_all(), S==Class].


%% @doc Gets all classes having started connections
-spec get_all_classes() ->
    map().

get_all_classes() ->
    lists:foldl(
        fun({_Id, Class, Pid}, Acc) ->
            maps:put(Class, [Pid|maps:get(Class, Acc, [])], Acc) 
        end,
        #{},
        get_all()).


%% @doc Stops all started connections
-spec stop_all() ->
    ok.

stop_all() ->
    lists:foreach(fun({_, _, Pid}) -> stop(Pid, normal) end, get_all()).


%% @doc Stops all started connections for a class
-spec stop_all(nkpacket:class()) ->
    ok.

stop_all(Class) ->
    lists:foreach(fun({_Id, Pid}) -> stop(Pid, normal) end, get_all_class(Class)).


%% @doc Re-start the idle timeout
-spec reset_timeout(nkpacket:nkport()|pid()) ->
    ok.

reset_timeout(Conn) ->
    gen_server:cast(get_pid(Conn), nkpacket_reset_timeout).


%% @doc Re-starts the idle timeout with new time
-spec reset_timeout(nkpacket:nkport()|pid(), pos_integer()) ->
    ok | error.

reset_timeout(Conn, MSecs) ->
    case catch gen_server:call(get_pid(Conn), {nkpacket_reset_timeout, MSecs}, ?CALL_TIMEOUT) of
        ok -> ok;
        _ -> error
    end.


%% @doc Reads the remaining time to timeout
-spec get_timeout(nkpacket:nkport()|pid()) ->
    ok.

get_timeout(Conn) ->
    gen_server:call(get_pid(Conn), nkpacket_get_timeout, ?CALL_TIMEOUT).


%% @private 
-spec incoming(nkpacket:nkport()|pid(), term()) ->
    ok.

incoming(Conn, Msg) ->
    gen_server:cast(get_pid(Conn), {nkpacket_incoming, Msg}).


%% @private
-spec update_monitor(nkpacket:nkport()|pid(), pid()) ->
    ok.

update_monitor(Conn, Pid) ->
    gen_server:cast(get_pid(Conn), {update_monitor, Pid}).


%% @private
-spec start_link(nkpacket:nkport()) ->
    {ok, pid()}.

start_link(NkPort) -> 
    gen_server:start_link(?MODULE, [NkPort], []).


%% @private Ranch's entry point (see nkpacket_transport_tcp:start_link/4)
ranch_start_link(NkPort, Ref) ->
    proc_lib:start_link(?MODULE, ranch_init, [NkPort, Ref]).


%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    nkport :: nkpacket:nkport(),
    transp :: nkpacket:transport(),
    socket :: nkpacket_transport:socket(),
    listen_monitor :: reference() | undefined,
    srv_monitor :: reference() | undefined,
    user_monitor :: reference() | undefined,
    bridge :: nkpacket:nkport() | undefined,
    bridge_type :: up | down  | undefined,
    bridge_monitor :: reference() | undefined,
    ws_state :: term() | undefined,
    timeout :: non_neg_integer(),
    timeout_timer :: reference() | undefined,
    protocol :: atom(),
    proto_state :: term()
}).


%% @private 
-spec init(term()) ->
    {ok, #state{}} | {stop, term()}.

init([NkPort]) ->
    #nkport{
        id = Id,
        class = Class,
        protocol = Protocol,
        transp = Transp,
        remote_ip = Ip,
        remote_port = Port,
        pid = ListenPid,
        socket = Socket,
        opts = Opts
    } = NkPort,
    process_flag(trap_exit, true),          % Allow call to terminate/2
    nklib_proc:put(nkpacket_connections, {Id, Class}),
    Debug = maps:get(debug, Opts, false),
    put(nkpacket_debug, Debug),
    nklib_counters:async([nkpacket_connections, {nkpacket_connections, Class}]),
    Conn = {Protocol, Transp, Ip, Port},
    StoredOpts = if
        Transp==http; Transp==https ->
            maps:with([host, path], Opts);
        Transp==ws; Transp==wss ->
            maps:with([host, path, ws_proto], Opts);
        true ->
            #{}
    end,
    nklib_proc:put({nkpacket_connection, Class, Conn}, StoredOpts),
    Timeout = case maps:get(idle_timeout, Opts, undefined) of
        Timeout0 when is_integer(Timeout0) -> 
            Timeout0;
        undefined ->
            case Transp of
                udp -> nkpacket_config:udp_timeout();
                tcp -> nkpacket_config:tcp_timeout();
                tls -> nkpacket_config:tcp_timeout();
                sctp -> nkpacket_config:sctp_timeout();
                ws -> nkpacket_config:ws_timeout();
                wss -> nkpacket_config:ws_timeout();
                http -> nkpacket_config:http_timeout();
                https -> nkpacket_config:http_timeout()
            end
    end,
    ListenMonitor = case is_pid(ListenPid) of
        true -> erlang:monitor(process, ListenPid);
        _ -> undefined
    end,
    SrvMonitor = case is_pid(Socket) of
        true -> erlang:monitor(process, Socket);
        _ -> undefined
    end,
    UserMonitor = case Opts of
        #{monitor:=UserRef} -> erlang:monitor(process, UserRef);
        _ -> undefined
    end,
    WsState = case Transp==ws orelse Transp==wss of
        true -> nkpacket_connection_ws:init(#{});
        _ -> undefined
    end,
    NkPort2 = NkPort#nkport{
        pid = self(),
        opts = Opts#{idle_timeout => Timeout}
    },
    % We need to store some meta in case someone calls get_nkport
    StoredNkPort = NkPort2#nkport{
        opts=maps:with([host, path, ws_proto, udp_max_size, debug], Opts)},
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
        protocol = Protocol
    },
    %% 'user' key is only sent to conn_init, then it is removed
    ?DEBUG("started to/from ~p:~p (~p, ~p)", [Ip, Port, Class, self()], NkPort),
    case nkpacket_util:init_protocol(Protocol, conn_init, NkPort2) of
        {ok, ProtoState} ->
            State1 = State#state{proto_state=ProtoState},
            {ok, restart_timer(State1)};
        {bridge, Bridge, ProtoState} ->
            State1 = State#state{proto_state=ProtoState},
            State2 = start_bridge(Bridge, up, State1),
            {ok, restart_timer(State2)};
        {stop, Reason} ->
            gen_server:cast(self(), {nkpacket_stop, Reason}),
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
        {ok, NkPort2} ->
            {ok, State} = init([NkPort2]),
            ok = proc_lib:init_ack({ok, NkPort2#nkport{pid=self()}}),
            gen_server:enter_loop(?MODULE, [], State);
        {error, Error} ->
            proc_lib:init_ack({error, Error})
    end;

conn_init(#nkport{transp=Transp}=NkPort) when Transp==ws; Transp==wss ->
    case nkpacket_transport_ws:connect(NkPort) of
        {ok, NkPort2, Rest} ->
            {ok, State} = init([NkPort2]),
            case Rest of
                <<>> ->
                    ok;
                _ ->
                    incoming(self(), Rest)
            end,
            ok = proc_lib:init_ack({ok, NkPort2#nkport{pid=self()}}),
            gen_server:enter_loop(?MODULE, [], State);
        {error, Error} ->
            proc_lib:init_ack({error, Error})
    end;

conn_init(#nkport{transp=Transp}=NkPort) when Transp==http; Transp==https ->
    case nkpacket_transport_http:connect(NkPort) of
        {ok, NkPort2} ->
            {ok, State} = init([NkPort2]),
            ok = proc_lib:init_ack({ok, NkPort2#nkport{pid=self()}}),
            gen_server:enter_loop(?MODULE, [], State);
        {error, Error} ->
            proc_lib:init_ack({error, Error})
    end;

conn_init(#nkport{transp=Transp}) ->
    error({invalid_transport, Transp}).


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}} |
    {stop, term(), #state{}} | {stop, term(), term(), #state{}}.

handle_call({nkpacket_apply_nkport, Fun}, _From, #state{nkport=NkPort}=State) ->
    {reply, Fun(NkPort), State};

handle_call({nkpacket_reset_timeout, MSecs}, _From, State) ->
    {reply, ok, restart_timer(State#state{timeout=MSecs})};

handle_call(nkpacket_get_timeout, _From, #state{timeout_timer=Ref}=State) ->
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

handle_call({nkpacket_send, Msg}, _From, State) ->
    case do_send(Msg, State) of
        {ok, Reply, State1} ->
            {reply, Reply, State1};
        {stop, Reason, State1} ->
            {stop, normal, {error, Reason}, State1}
    end;

handle_call(Msg, From, #state{nkport=NkPort}=State) ->
    case call_protocol(conn_handle_call, [Msg, From, NkPort], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(nkpacket_reset_timeout, State) ->
    {noreply, restart_timer(State)};

handle_cast({nkpacket_incoming, Data}, State) ->
    parse(Data, restart_timer(State));

handle_cast({nkpacket_send, Msg}, State) ->
    case do_send(Msg, State) of
        {ok, _Reply, State1} ->
            {noreply, State1};
        {stop, _Reason, State1} ->
            {stop, normal, State1}
    end;

handle_cast({nkpacket_stop, Reason}, State) ->
    {stop, Reason, State};

handle_cast({nkpacket_bridged, Bridge}, #state{nkport=NkPort}=State) ->
    ?DEBUG("bridged: ~p, ~p", [?PR(Bridge), ?PR(NkPort)], NkPort),
    {noreply, start_bridge(Bridge, down, State)};

handle_cast({nkpacket_stop_bridge, Pid}, #state{bridge=#nkport{pid=Pid}}=State) ->
    #state{nkport=NkPort} = State,
    ?DEBUG("unBridged: ~p, ~p", [Pid, ?PR(NkPort)], NkPort),
    #state{bridge_monitor=Mon} = State, 
    case is_reference(Mon) of
        true -> erlang:demonitor(Mon);
        false -> ok
    end,
    {noreply, State#state{bridge_monitor=undefined, bridge=undefined}};

handle_cast({nkpacket_stop_bridge, Pid}, #state{nkport=NkPort}=State) ->
    ?LLOG(notice, "received unbridge for unknown bridge ~p", [Pid], NkPort),
    {noreply, State};

handle_cast({update_monitor, Pid}, #state{user_monitor=OldMon}=State) ->
    nklib_util:demonitor(OldMon),
    {noreply, State#state{user_monitor=monitor(process, Pid)}};

handle_cast(Msg, #state{nkport=NkPort}=State) ->
    case call_protocol(conn_handle_cast, [Msg, NkPort], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({tcp, Socket, Data}, #state{socket=Socket}=State) ->
    inet:setopts(Socket, [{active, once}]),
    parse(Data, restart_timer(State));

handle_info({ssl, Socket, Data}, #state{socket=Socket}=State) ->
    ssl:setopts(Socket, [{active, once}]),
    parse(Data, restart_timer(State));

handle_info({tcp_closed, _Socket}, #state{nkport=NkPort}=State) ->
    ?DEBUG("tcp closed", [], NkPort),
    case catch call_protocol(conn_parse, [close, NkPort], State) of
        undefined -> 
            {stop, normal, State};
        {ok, State1} ->
            {stop, normal, State1};
        {stop, _, State1} ->
            {stop, normal, State1}
    end;
    
handle_info({tcp_error, _Socket}, #state{nkport=NkPort}=State) ->
    ?DEBUG("tcp error", [], NkPort),
    {stop, normal, State};

handle_info({ssl_closed, _Socket}, #state{nkport=NkPort}=State) ->
    ?DEBUG("ssl close", [], NkPort),
    handle_info({tcp_closed, none}, State);

handle_info({ssl_error, _Socket}, #state{nkport=NkPort}=State) ->
    ?DEBUG("ssl error", [], NkPort),
    {stop, normal, State};

handle_info({timeout, _, idle_timer}, #state{nkport=NkPort}=State) ->
    case call_protocol(conn_timeout, [NkPort], State) of
        undefined ->
            ?DEBUG("timeout", [], NkPort),
            {stop, normal, State};
        {ok, State1} ->
            {noreply, restart_timer(State1)};
        {stop, Reason, State1} ->
            ?DEBUG("timeout: ~p", [Reason], NkPort),
            {stop, Reason, State1}
    end;

handle_info({'DOWN', MRef, process, _Pid, Reason}, #state{bridge_monitor=MRef}=State) ->
    case Reason of
        normal -> {stop, normal, State};
        _ -> {stop, {bridge_down, Reason}, State}
    end;

handle_info({'DOWN', MRef, process, _Pid, _Reason}, 
        #state{listen_monitor=MRef, nkport=NkPort}=State) ->
    ?DEBUG("stop (listener stop)", [], NkPort),
    {stop, normal, State};

handle_info({'DOWN', MRef, process, _Pid, _Reason}, 
        #state{srv_monitor=MRef, nkport=NkPort}=State) ->
    ?DEBUG("stop (server stop)", [], NkPort),
    {stop, normal, State};

handle_info({'DOWN', MRef, process, _Pid, _Reason}, 
        #state{user_monitor=MRef, nkport=NkPort}=State) ->
    ?DEBUG("stop (monitor stop)", [], NkPort),
    {stop, normal, State};

handle_info(Msg, #state{nkport=NkPort}=State) ->
    case call_protocol(conn_handle_info, [Msg, NkPort], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, #state{nkport = NkPort} = State) ->
    catch call_protocol(conn_stop, [Reason, NkPort], State),
    ?DEBUG("process stopped (~p, ~p)", [Reason, self()], NkPort),
    % Sometimes ssl sockets are slow to close here
    spawn(fun() -> nkpacket_connection_lib:raw_stop(NkPort) end),
    ok.




%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec parse(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

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
        nkport = From
    } = State,
    {FromIp, FromPort, ToIp, ToPort} = case Type of
        up ->
            #nkport{local_ip=FromIp0, local_port=FromPort0} = From,
            #nkport{remote_ip=ToIp0, remote_port=ToPort0} = To,
            {FromIp0, FromPort0, ToIp0, ToPort0};
        down ->
            #nkport{remote_ip=FromIp0, remote_port=FromPort0} = From,
            #nkport{local_ip=ToIp0, local_port=ToPort0} = To,
            {FromIp0, FromPort0, ToIp0, ToPort0}
    end,
    case call_protocol(conn_bridge, [Data, Type, From], State) of
        undefined ->
            case nkpacket_connection_lib:raw_send(To, Data) of
                ok ->
                    ?DEBUG("packet ~p bridged from ~p:~p to ~p:~p", 
                          [Data, FromIp, FromPort, ToIp, ToPort], From),
                    {ok, State};
                {error, Error} ->
                    ?LLOG(info, "packet ~p could not be bridged from ~p:~p to ~p:~p", 
                           [Data, FromIp, FromPort, ToIp, ToPort], From),
                    {stop, Error, State}
            end;
        {ok, Data1, State1} ->
            case nkpacket_connection_lib:raw_send(To, Data1) of
                ok ->
                    ?DEBUG("packet ~p bridged from ~p:~p to ~p:~p", 
                          [Data1, FromIp, FromPort, ToIp, ToPort], From),
                    {ok, State1};
                {error, Error} ->
                    ?LLOG(notice, "packet ~p could not be bridged from ~p:~p to ~p:~p", 
                          [Data1, FromIp, FromPort, ToIp, ToPort], From),
                    {stop, Error, State1}
            end;
        {skip, State1} ->
            {ok, State1};
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end;

do_parse(Data, #state{nkport=#nkport{protocol=Protocol}=NkPort}=State) ->
    ?DEBUG("recv: ~p", [Data], NkPort),
    case call_protocol(conn_parse, [Data, NkPort], State) of
        undefined ->
            ?LLOG(warning, "received data for undefined protocol ~p", 
                   [Protocol], NkPort),
            {ok, State};
        {ok, State1} ->
            {ok, State1};
        {reply, Msg, State1} ->
            case encode(Msg, State1) of
                {ok, OutMsg, State2} ->
                    case nkpacket_connection_lib:raw_send(NkPort, OutMsg) of
                        ok ->
                            {ok, State2};
                        {error, Error} ->
                            {stop, {reply_error, Error}, State2}
                    end;
                {stop, Reason, State2} ->
                    {stop, Reason, State2}
            end;
        {bridge, Bridge, State1} ->
            State2 = start_bridge(Bridge, up, State1),
            do_parse(Data, State2);
        {stop, normal, State1} ->
            {stop, normal, State1};
        {stop, Reason, State1} ->
            ?DEBUG("stop response from conn_parse: ~p", [Reason], NkPort),
            {stop, normal, State1}
    end.


%% @private
do_send(Msg, #state{nkport=NkPort}=State) ->
    {Updated, Msg2} = update_msg(Msg, NkPort),
    case encode(Msg2, State) of
        {ok, OutMsg, State1} ->
            ?DEBUG("raw send (process): ~p", [OutMsg], NkPort),
            case nkpacket_connection_lib:raw_send(NkPort, OutMsg) of
                ok when Updated ->
                    {ok, {ok, Msg2}, restart_timer(State1)};
                ok ->
                    {ok, ok, restart_timer(State1)};
                {error, Error} ->
                    {stop, Error, State1}
            end;
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end.


%% @private
-spec start_bridge(nkpacket:nkport(), up|down, #state{}) ->
    #state{}.

start_bridge(Bridge, Type, State) ->
    #nkport{pid=BridgePid} = Bridge,
    #state{bridge_monitor=OldMon, bridge=OldBridge, nkport=NkPort} = State,
    {FromIp, FromPort, ToIp, ToPort} = case Type of
        up ->
            #nkport{local_ip=FromIp0, local_port=FromPort0} = NkPort,
            #nkport{remote_ip=ToIp0, remote_port=ToPort0} = Bridge,
            {FromIp0, FromPort0, ToIp0, ToPort0};
        down ->
            #nkport{remote_ip=FromIp0, remote_port=FromPort0} = NkPort,
            #nkport{local_ip=ToIp0, local_port=ToPort0} = Bridge,
            {FromIp0, FromPort0, ToIp0, ToPort0}
    end,
    case OldBridge of
        undefined ->
            ?DEBUG("connection ~p started bridge ~p from ~p:~p to ~p:~p",
                  [self(), Type, FromIp, FromPort, ToIp, ToPort], NkPort),
            Mon = erlang:monitor(process, BridgePid),
            case Type of
                up -> gen_server:cast(BridgePid, {nkpacket_bridged, NkPort});
                down -> ok
            end,
            State#state{bridge=Bridge, bridge_monitor=Mon, bridge_type=Type};
        #nkport{pid=BridgePid} ->
            State;
        #nkport{pid=OldPid} ->
            erlang:demonitor(OldMon),
            gen_server:cast(OldPid, nkpacket_stop_bridge),
            start_bridge(Bridge, Type, State#state{bridge=undefined})
    end.


%% @private
get_pid(#nkport{pid=Pid}) -> Pid;
get_pid(Pid) when is_pid(Pid) -> Pid.


%% @private
restart_timer(#state{timeout=Timeout, timeout_timer=Ref}=State) ->
    nklib_util:cancel_timer(Ref),
    Timer = case Timeout > 0 of
        true -> erlang:start_timer(Timeout, self(), idle_timer);
        false -> undefined
    end,
    State#state{timeout_timer=Timer}.


%% @private
-spec encode(term(), #state{}) ->
    {ok, nkpacket:outcoming(), #state{}} | {stop, term(), #state{}}.

encode(Msg, #state{nkport=#nkport{protocol=Protocol}=NkPort}=State) -> 
    case erlang:function_exported(Protocol, conn_encode, 2) of
        true ->
            case Protocol:conn_encode(Msg, NkPort) of
                {ok, OutMsg} ->
                    {ok, OutMsg, State};
                continue ->
                    encode2(Msg, State);
                {error, Error} ->
                    {stop, {encode_error, Error}, State}
            end;
        false ->
            encode2(Msg, State)
    end.


%% @private
encode2(Msg, #state{nkport=NkPort}=State) -> 
    case call_protocol(conn_encode, [Msg, NkPort], State) of
        undefined when is_binary(Msg) ->
            {ok, Msg, State};
        undefined when is_list(Msg) ->
            case catch list_to_binary(Msg) of
                {'EXIT', Error} -> {stop, {encode_error, Error}, State};
                Bin -> {ok, Bin, State}
            end;
        undefined ->
            {stop, {encode_error, no_encode_callback}, State};
        {ok, OutMsg, State1} ->
            {ok, OutMsg, State1};
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end.


%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).
