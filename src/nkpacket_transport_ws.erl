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

%% @private Websocket (WS/WSS) Transport.
%%
%% For listening, we start this server and also a 'shared' nkpacket_cowboy transport.
%% cowboy_init/3 will be called is the connection is for us
%%
%% For outbound connections, we start a normal tcp/ssl connection and let it be
%% managed by a fresh nkpacket_connection process

-module(nkpacket_transport_ws).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_listener/1, connect/1]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3, 
         handle_cast/2, handle_info/2]).
-export([websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).
-export([cowboy_init/5]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


%% To get debug info, start with debug=>true

-define(DEBUG(Txt, Args),
    case get(nkpacket_debug) of
        true -> ?LLOG(debug, Txt, Args);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args), lager:Type("NkPACKET WS "++Txt, Args)).


%% ===================================================================
%% Private
%% ===================================================================


%% @private Starts a new listening server
-spec get_listener(nkpacket:nkport()) ->
    supervisor:child_spec().

get_listener(#nkport{id=Id, listen_ip=Ip, listen_port=Port, transp=Transp}=NkPort)
        when Transp==ws; Transp==wss ->
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
    {ok, nkpacket:nkport(), binary()} | {error, term()}.
         
connect(NkPort) ->
    #nkport{opts=Opts} = NkPort,
    Debug = maps:get(debug, Opts, false),
    put(nkpacket_debug, Debug),
    case connect_outbound(NkPort) of
        {ok, TranspMod, Socket} ->
            {ok, {LocalIp, LocalPort}} = TranspMod:sockname(Socket),
            Opts2 = maps:merge(#{path => <<"/">>}, Opts),
            NkPort2 = NkPort#nkport{
                local_ip = LocalIp,
                local_port = LocalPort,
                socket = Socket,
                opts  = Opts2
            },
            case nkpacket_connection_ws:start_handshake(NkPort2) of
                {ok, WsProto, Rest} -> 
                    Opts2 = case WsProto of
                        undefined -> Opts2;
                        _ -> Opts2#{ws_proto=>WsProto}
                    end,
                    TranspMod:setopts(Socket, [{active, once}]),
                    {ok, NkPort2#nkport{opts=Opts2}, Rest};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} -> 
            {error, Error}
    end.


%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    nkport :: nkpacket:nkport(),
    protocol :: nkpacket:protocol(),
    proto_state :: term(),
    shared :: pid(),
    monitor_ref :: reference()
}).


start_link(NkPort) ->
    gen_server:start_link(?MODULE, [NkPort], []).
    

%% @private Starts transport process
-spec init(term()) ->
    {ok, #state{}} | {stop, term()}.

init([NkPort]) ->
    #nkport{
        class = Class,
        transp = Transp,
        listen_ip  = ListenIp,
        listen_port = ListenPort,
        opts = Meta,
        protocol = Protocol
    } = NkPort,
    process_flag(trap_exit, true),   %% Allow calls to terminate
    Debug = maps:get(debug, Meta, false),
    put(nkpacket_debug, Debug),
    try
        Timeout = case Meta of
            #{idle_timeout:=Timeout0} ->
                Timeout0;
            _ ->
                nkpacket_config:ws_timeout()
        end,
        NkPort1 = NkPort#nkport{pid = self()},
        Meta1 = maps:with([get_headers], Meta),
        Meta2 = Meta1#{
            compress => true,
            idle_timeout => Timeout     % WS has its own timeout
        },
        Filter = #cowboy_filter{
            pid = self(),
            module = ?MODULE,
            transp = Transp,
            host = maps:get(host, Meta, any),
            paths = nkpacket_util:norm_path(maps:get(path, Meta, any)),
            ws_proto = maps:get(ws_proto, Meta, any),
            meta = Meta2
        },
        ?DEBUG("starting nkpacket_cowboy (~p) (~p)",
               [lager:pr(NkPort1, ?MODULE), lager:pr(Filter, ?MODULE)]),
        SharedPid = case nkpacket_cowboy:start(NkPort1, Filter) of
            {ok, SharedPid0} -> SharedPid0;
            {error, Error} -> throw(Error)
        end,
        % See description in nkpacket_transport_http
        erlang:monitor(process, SharedPid),
        {ok, {_, _, LocalIp, LocalPort}} = nkpacket:get_local(SharedPid),
        ConnMeta = maps:with(?CONN_LISTEN_OPTS, Meta),
        ConnPort = NkPort1#nkport{
            local_ip   = LocalIp,
            local_port = LocalPort,
            listen_port= LocalPort,
            socket     = SharedPid,
            opts       = ConnMeta
        },   
        Host = maps:get(host, Meta, any),
        Path = maps:get(path, Meta, any),
        WsProto = maps:get(ws_proto, Meta, any),
        nkpacket_util:register_listener(NkPort),
        ListenType = case size(ListenIp) of
            4 -> nkpacket_listen4;
            8 -> nkpacket_listen6
        end,
        nklib_proc:put({ListenType, Class, Protocol, Transp}, ConnPort),
        {ok, ProtoState} = nkpacket_util:init_protocol(Protocol, listen_init, ConnPort),
        MonRef = case Meta of
            #{monitor:=UserRef} -> 
                erlang:monitor(process, UserRef);
            _ -> 
                undefined
        end,
        ?DEBUG("created ~p listener for ~p:~p:~p (~p, ~p, ~p) (~p)", 
               [Protocol, Transp, LocalIp, LocalPort, 
                Host, Path, WsProto, self()]),
        State = #state{
            nkport = ConnPort,
            protocol = Protocol,
            proto_state = ProtoState,
            shared = SharedPid,
            monitor_ref = MonRef
        },
        {ok, State}
    catch
        throw:TError -> 
            ?LLOG(error, "could not start ~p transport on ~p:~p (~p)", 
                   [Transp, ListenIp, ListenPort, TError]),
        {stop, TError}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}} |
    {stop, term(), #state{}} | {stop, term(), term(), #state{}}.

handle_call({nkpacket_apply_nkport, Fun}, _From, #state{nkport=NkPort}=State) ->
    {reply, Fun(NkPort), State};

handle_call({nkpacket_start, Ip, Port, FilterMeta, Pid}, _From, State) ->
    #state{nkport=#nkport{opts=Meta} = NkPort} = State,
    % We remove host and path because the connection we are going to start
    % is not related (from the remote point of view) of the local host and path
    % In case to be reused, they should not be taken into account.
    % Anycase, the reuse of ws connections at the server is nearly always going
    % to be used based on the flow (the socket of #nkport{})
    % Connection will monitor listen process (using 'pid' and
    % the cowboy process (using 'socket')
    Meta1 = maps:without([host, path], Meta),
    Meta2 = maps:merge(Meta1, FilterMeta),
    NkPort1 = NkPort#nkport{
        remote_ip  = Ip,
        remote_port= Port,
        socket     = Pid,
        opts       = Meta2
    },
    {reply, {ok, NkPort1}, State};

%%
%%    case nkpacket_connection:start(NkPort1) of
%%        {ok, #nkport{pid=ConnPid}=NkPort2} ->
%%            ?DEBUG("listener accepted connection: ~p", [NkPort2]),
%%            {reply, {ok, ConnPid}, State};
%%        {error, Error} ->
%%            ?DEBUG("listener did not accepted connection: ~p", [Error]),
%%            {reply, next, State}
%%    end;

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

handle_cast(stop, State) ->
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

handle_info({'DOWN', _MRef, process, Pid, Reason}, #state{shared=Pid}=State) ->
    ?DEBUG("received SHARED stop", []),
    {stop, Reason, State};

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

terminate(Reason, #state{nkport=NkPort}=State) ->  
    catch call_protocol(listen_stop, [Reason, NkPort], State),
    ok.



% %% ===================================================================
% %% Shared callbacks
% %% ===================================================================


%% @private Called from nkpacket_cowboy:execute/2, inside
%% cowboy's connection process
-spec cowboy_init(pid(), cowboy_req:req(), [binary()], map(), map()) ->
    term().

cowboy_init(Pid, Req, _PathList, FilterMeta, Env) ->
    {Ip, Port} = cowboy_req:peer(Req),
    case catch gen_server:call(Pid, {nkpacket_start, Ip, Port, FilterMeta, self()}, infinity) of
        {ok, NkPort} ->
            %% @see cowboy_websocket:upgrade/5
            Opts = maps:with([idle_timeout, compress], FilterMeta),
            cowboy_websocket:upgrade(Req, Env, ?MODULE, NkPort, Opts);
        next ->
            next;
        {'EXIT', _} ->
            next
    end.



% %% ===================================================================
% %% Cowboy's callbacks
% %% ===================================================================


%% @doc We could use websocket_init/1
-spec websocket_init(State) ->
    {ok, State} |
    {ok, State, hibernate} |
    {reply, cow_ws:frame() | [cow_ws:frame()], State} |
    {reply, cow_ws:frame() | [cow_ws:frame()], State, hibernate} |
    {stop, State}
    when State::any().

websocket_init(NkPort) ->
    case nkpacket_connection:start(NkPort#nkport{socket=self()}) of
        {ok, ConnPid} ->
            {ok, ConnPid};
        {error, Error} ->
            ?LLOG(notice, "WS could not start session: ~p", [Error]),
            {stop, NkPort}
    end.


%% @private
-spec websocket_handle({text | binary | ping | pong, binary()}, State) ->
    {ok, State} |
    {ok, State, hibernate} |
    {reply, cow_ws:frame() | [cow_ws:frame()], State} |
    {reply, cow_ws:frame() | [cow_ws:frame()], State, hibernate} |
    {stop, State}
    when State::any().

websocket_handle({text, Msg}, ConnPid) ->
    nkpacket_connection:incoming(ConnPid, {text, Msg}),
    {ok, ConnPid};

websocket_handle({binary, Msg}, ConnPid) ->
    nkpacket_connection:incoming(ConnPid, {binary, Msg}),
    {ok, ConnPid};

% We don't need to reply to ping or ping requests, it's automatic
websocket_handle(ping, ConnPid) ->
    {reply, pong, ConnPid};
    %{ok, ConnPid};

websocket_handle({ping, _Body}, ConnPid) ->
    {reply, {pong, _Body}, ConnPid};
    %{ok, ConnPid};

websocket_handle(pong, ConnPid) ->
    {ok, ConnPid};

websocket_handle({pong, Body}, ConnPid) ->
    nkpacket_connection:incoming(ConnPid, {pong, Body}),
    {ok, ConnPid};

websocket_handle(Other, ConnPid) ->
    ?LLOG(warning, "WS Handler received unexpected ~p", [Other]),
    {stop, ConnPid}.



%% @private
-spec websocket_info(any(), State) ->
    {ok, State} |
    {ok, State, hibernate} |
    {reply, cow_ws:frame() | [cow_ws:frame()], State} |
    {reply, cow_ws:frame() | [cow_ws:frame()], State, hibernate} |
    {stop, State}
    when State::any().

websocket_info({nkpacket_send, Fun}, ConnPid) when is_function(Fun, 0) ->
    {reply, Fun(), ConnPid};

websocket_info({nkpacket_send, Frames}, ConnPid) ->
    {reply, Frames, ConnPid};

websocket_info({nkpacket_send, Ref, Pid, Fun}, ConnPid) when is_function(Fun, 0) ->
    self() ! {nkpacket_reply, Ref, Pid},
    {reply, Fun(), ConnPid};

websocket_info({nkpacket_send, Ref, Pid, Frames}, ConnPid) ->
    self() ! {nkpacket_reply, Ref, Pid},
    {reply, Frames, ConnPid};

websocket_info({nkpacket_reply, Ref, Pid}, ConnPid) ->
    Pid ! {nkpacket_reply, Ref},
    {ok, ConnPid};

websocket_info(nkpacket_stop, ConnPid) ->
    {stop, ConnPid};

websocket_info(Info, ConnPid) ->
    lager:error("Module ~p received unexpected info ~p", [?MODULE, Info]),
    {ok, ConnPid}.


%%%% @private
terminate(Reason, _Req, ConnPid) ->
    ?DEBUG("WS terminate: ~p (~p)", [Reason, ConnPid]),
    nkpacket_connection:stop(ConnPid, normal),
    ok.



%% ===================================================================
%% Util
%% ===================================================================

%% @private Gets socket options for outbound connections
-spec connect_outbound(#nkport{}) ->
    {ok, inet|ssl, inet:socket()} | {error, term()}.

connect_outbound(#nkport{remote_ip=Ip, remote_port=Port, opts=Opts, transp=ws}) ->
    SocketOpts = outbound_opts(),
    ConnTimeout = case maps:get(connect_timeout, Opts, undefined) of
        undefined ->
            nkpacket_config:connect_timeout();
        Timeout0 ->
            Timeout0
    end,
    ?DEBUG("connect to: ws:~p:~p (~p)", [Ip, Port, SocketOpts]),
    case gen_tcp:connect(Ip, Port, SocketOpts, ConnTimeout) of
        {ok, Socket} ->
            {ok, inet, Socket};
        {error, Error} ->
            {error, Error}
    end;

connect_outbound(#nkport{remote_ip=Ip, remote_port=Port, opts=Opts, transp=wss}) ->
    SocketOpts = outbound_opts() ++ nkpacket_tls:make_outbound_opts(Opts),
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
    ?DEBUG("connect to: wss:~p:~p (~p)", [Host, Port, SocketOpts]),
    case ssl:connect(Host, Port, SocketOpts, ConnTimeout) of
        {ok, Socket} ->
            {ok, ssl, Socket};
        {error, Error} ->
            {error, Error}
    end.


%% @private Gets socket options for outbound connections
-spec outbound_opts() ->
    list().

outbound_opts() ->
    [
        binary,
        {active, false},
        {nodelay, true},
        {keepalive, true},
        {packet, raw}
    ].





%% ===================================================================
%% Util
%% ===================================================================

%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).


%% @private


