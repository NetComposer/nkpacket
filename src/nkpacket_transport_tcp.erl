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

%% @private TCP/TLS Transport.
%% This module is used for both inbound and outbound TCP and TLS connections.

-module(nkpacket_transport_tcp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(ranch_protocol).

-export([get_listener/1, connect/1, start_link/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).
-export([start_link/4]).

-include("nkpacket.hrl").


%% To get debug info, start with debug=>true

-define(DEBUG(Txt, Args),
    case get(nkpacket_debug) of
        true -> ?LLOG(debug, Txt, Args);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args), lager:Type("NkPACKET TCP "++Txt, Args)).




%% ===================================================================
%% Private
%% ===================================================================

%% @private Starts a new listening server
-spec get_listener(nkpacket:nkport()) ->
    supervisor:child_spec().

get_listener(#nkport{id=Id, listen_ip=Ip, listen_port=Port, transp=Transp}=NkPort)
        when Transp==tcp; Transp==tls ->
    Str = nkpacket_util:conn_string(Transp, Ip, Port),
    #{
        id => {Id, Str},
        start => {?MODULE, start_link, [NkPort]},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.


%% @private Starts a new connection to a remote server
-spec connect(nkpacket:nkport()) ->
    {ok, nkpacket:nkport()} | {error, term()}.
         
connect(NkPort) ->
    #nkport{opts=Meta} = NkPort,
    Debug = maps:get(debug, Meta, false),
    put(nkpacket_debug, Debug),
    case connect_outbound(NkPort) of
        {ok, InetMod, Socket} ->
            {ok, {LocalIp, LocalPort}} = InetMod:sockname(Socket),
            NkPort2 = NkPort#nkport{
                local_ip = LocalIp,
                local_port = LocalPort,
                socket = Socket
            },
            InetMod:setopts(Socket, [{active, once}]),
            {ok, NkPort2};
        {error, Error} -> 
            {error, Error}
    end.



%% ===================================================================
%% gen_server
%% ===================================================================

%% @private
start_link(NkPort) ->
    gen_server:start_link(?MODULE, [NkPort], []).


-record(state, {
    nkport :: nkpacket:nkport(),
    ranch_id :: term(),
    ranch_pid :: pid(),
    protocol :: nkpacket:protocol(),
    proto_state :: term(),
    monitor_ref :: reference()
}).


%% @private 
-spec init(term()) ->
    {ok, #state{}} | {stop, term()}.

init([NkPort]) ->
    #nkport{
        class = Class,
        protocol = Protocol,
        transp = Transp,
        listen_ip = ListenIp,
        listen_port = ListenPort,
        opts = Meta
    } = NkPort,
    process_flag(trap_exit, true),   %% Allow calls to terminate
    Debug = maps:get(debug, Meta, false),
    put(nkpacket_debug, Debug),
    ListenOpts = listen_opts(NkPort),
    case nkpacket_transport:open_port(NkPort, ListenOpts) of
        {ok, Socket}  ->
            {InetMod, _, RanchMod} = get_modules(Transp),
            {ok, {LocalIp, LocalPort}} = InetMod:sockname(Socket),
            NkPort1 = NkPort#nkport{
                local_ip = LocalIp,
                local_port = LocalPort, 
                listen_ip = ListenIp,
                listen_port = LocalPort,
                pid = self(),
                socket = Socket
            },
            RanchId = {Transp, ListenIp, LocalPort},
            RanchPort = NkPort1#nkport{opts=maps:with(?CONN_LISTEN_OPTS, Meta)},
            Listeners = maps:get(tcp_listeners, Meta, 100),
            ?DEBUG("active listeners: ~p", [Listeners]),
            {ok, RanchPid} = ranch_listener_sup:start_link(
                RanchId,
                RanchMod,
                #{
                    socket => Socket,
                    max_connections =>  maps:get(tcp_max_connections, Meta, 1024)
                },
                ?MODULE,
                [RanchPort]),
            % We take the 'real' port (in case it is '0')
            nkpacket_util:register_listener(NkPort),
            ConnMetaOpts = [
                tcp_packet, send_timeout, send_timeout_close,
                tls_certfile, tls_keyfile, tls_cacertfile
                | ?CONN_LISTEN_OPTS
            ],
            % ConnMetaOpts = [tcp_packet, tls_opts | ?CONN_LISTEN_OPTS],
            ConnMeta = maps:with(ConnMetaOpts, Meta),
            ConnPort = NkPort1#nkport{opts=ConnMeta},
            ListenType = case size(ListenIp) of
                4 -> nkpacket_listen4;
                8 -> nkpacket_listen6
            end,
            nklib_proc:put({ListenType, Class, Protocol, Transp}, ConnPort),
            {ok, ProtoState} = nkpacket_util:init_protocol(Protocol, listen_init, NkPort1),
            MonRef = case Meta of
                #{monitor:=UserRef} -> erlang:monitor(process, UserRef);
                _ -> undefined
            end,
            State = #state{
                nkport = ConnPort,
                ranch_id = RanchId,
                ranch_pid = RanchPid,
                protocol = Protocol,
                proto_state = ProtoState,
                monitor_ref = MonRef
            },
            {ok, State};
        {error, Error} ->
            ?LLOG(error, "could not start ~p transport on ~p:~p (~p)", 
                   [Transp, ListenIp, ListenPort, Error]),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}} |
    {stop, term(), #state{}} | {stop, term(), term(), #state{}}.

handle_call({nkpacket_apply_nkport, Fun}, _From, #state{nkport=NkPort}=State) ->
    {reply, Fun(NkPort), State};

handle_call(nkpacket_stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(Msg, From, #state{nkport=NkPort}=State) ->
    case call_protocol(listen_handle_call, [Msg, From, NkPort], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(nkpacket_stop, State) ->
    {stop, normal, State};

handle_cast(Msg, #state{nkport=NkPort}=State) ->
    case call_protocol(listen_handle_cast, [Msg, NkPort], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({'DOWN', MRef, process, _Pid, _Reason}, #state{monitor_ref=MRef}=State) ->
    {stop, normal, State};

handle_info({'EXIT', Pid, Reason}, #state{ranch_pid=Pid}=State) ->
    {stop, {ranch_stop, Reason}, State};

handle_info(Msg, #state{nkport=NkPort}=State) ->
    case call_protocol(listen_handle_info, [Msg, NkPort], State) of
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

terminate(Reason, State) ->  
    #state{
        ranch_id = RanchId,
        ranch_pid = RanchPid,
        nkport = #nkport{transp=Transp, socket=Socket} = NkPort
    } = State,
    ?DEBUG("listener stop: ~p", [Reason]),
    catch call_protocol(listen_stop, [Reason, NkPort], State),
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

start_link(Ref, Socket, TranspModule, [#nkport{opts=Meta} = NkPort]) ->
    {ok, {LocalIp, LocalPort}} = TranspModule:sockname(Socket),
    {ok, {RemoteIp, RemotePort}} = TranspModule:peername(Socket),
    NkPort1 = NkPort#nkport{
        local_ip = LocalIp,
        local_port = LocalPort,
        remote_ip = RemoteIp,
        remote_port = RemotePort,
        socket = Socket
    },
    case TranspModule of
        ranch_ssl ->
            ok;
        ranch_tcp ->
            Opts1 = maps:to_list(maps:with([send_timeout, send_timeout_close], Meta)),
            Opts2 = [{keepalive, true}, {active, once} | Opts1],
            Opts3 = case Meta of
                #{tcp_packet:=Packet} ->
                    [{packet, Packet}|Opts2];
                _ ->
                    Opts2
            end,
            TranspModule:setopts(Socket, Opts3)
    end,
    nkpacket_connection:ranch_start_link(NkPort1, Ref).


%% ===================================================================
%% Internal
%% ===================================================================

%% @private Gets socket options for outbound connections
-spec connect_outbound(#nkport{}) ->
    {ok, inet|ssl, inet:socket()} | {error, term()}.

connect_outbound(#nkport{remote_ip=Ip, remote_port=Port, opts=Opts, transp=tcp}=NkPort) ->
    SocketOpts = outbound_opts(NkPort),
    ConnTimeout = case maps:get(connect_timeout, Opts, undefined) of
        undefined ->
            nkpacket_config:connect_timeout();
        Timeout0 ->
            Timeout0
    end,
    ?DEBUG("connect to: tcp:~p:~p (~p)", [ Ip, Port, SocketOpts]),
    case gen_tcp:connect(Ip, Port, SocketOpts, ConnTimeout) of
        {ok, Socket} ->
            {ok, inet, Socket};
        {error, Error} ->
            {error, Error}
    end;

connect_outbound(#nkport{remote_ip=Ip, remote_port=Port, opts=Opts, transp=tls}=NkPort) ->
    SocketOpts = outbound_opts(NkPort) ++ nkpacket_tls:make_outbound_opts(Opts),
    ConnTimeout = case maps:get(connect_timeout, Opts, undefined) of
        undefined ->
            nkpacket_config:connect_timeout();
        Timeout0 ->
            Timeout0
    end,
    Host = case Opts of
        #{tls_verify:=host, host:=Host0} ->
            binary_to_list(Host0);
        _ ->
            Ip
    end,
    ?DEBUG("connect to: tls:~p:~p (~p)", [Host, Port, SocketOpts]),
    case ssl:connect(Host, Port, SocketOpts, ConnTimeout) of
        {ok, Socket} ->
            {ok, ssl, Socket};
        {error, Error} ->
            {error, Error}
    end.


%% @private Gets socket options for outbound connections
-spec outbound_opts(#nkport{}) ->
    list().

outbound_opts(#nkport{opts=Opts}) ->
    Opts1 = maps:to_list(maps:with([send_timeout, send_timeout_close, tos], Opts)),
    [
        binary,
        {active, false},
        {nodelay, true},
        {keepalive, true},
        {packet, case Opts of #{tcp_packet:=Packet} -> Packet; _ -> raw end}
        | Opts1
    ].


%% @private Gets socket options for listening connections
-spec listen_opts(#nkport{}) ->
    list().

listen_opts(#nkport{transp=tcp, listen_ip=Ip, opts=Opts}) ->
    Opts1 = maps:to_list(maps:with([send_timeout, send_timeout_close, tos], Opts)),
    [
        {packet, case Opts of #{tcp_packet:=Packet} -> Packet; _ -> raw end},
        binary,
        {ip, Ip},
        {active, false},
        {nodelay, true},
        {keepalive, true},
        {reuseaddr, true},
        {backlog, 1024}
        | Opts1
    ];

listen_opts(#nkport{transp=tls, listen_ip=Ip, opts=Opts}) ->
    Opts1 = maps:to_list(maps:with([send_timeout, send_timeout_close], Opts)),
    [
        % From Cowboy 2.0:
        %{next_protocols_advertised, [<<"h2">>, <<"http/1.1">>]},
        %{alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]},
        {packet, case Opts of #{tcp_packet:=Packet} -> Packet; _ -> raw end},
        {ip, Ip}, {active, once}, binary,
        {nodelay, true}, {keepalive, true},
        {reuseaddr, true}, {backlog, 1024}
        | Opts1
    ]
    ++nkpacket_tls:make_inbound_opts(Opts).


%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).


%% @private
get_modules(tcp) -> {inet, gen_tcp, ranch_tcp};
get_modules(tls) -> {ssl, ssl, ranch_ssl}.




