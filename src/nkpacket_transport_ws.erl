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
-export([websocket_handle/3, websocket_info/3, terminate/3]).
-export([cowboy_init/3]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


%% ===================================================================
%% Private
%% ===================================================================


%% @private Starts a new listening server
-spec get_listener(nkpacket:nkport()) ->
    supervisor:child_spec().

get_listener(#nkport{transp=Transp}=NkPort) when Transp==ws; Transp==wss ->
    #nkport{local_ip=Ip, local_port=Port} = NkPort,
    {
        {Transp, Ip, Port, make_ref()},
        {?MODULE, start_link, [NkPort]},
        transient,
        5000,
        worker,
        [?MODULE]
    }.


%% @private Starts a new connection to a remote server
-spec connect(nkpacket:nkport()) ->
    {ok, nkpacket:nkport(), binary()} | {error, term()}.
         
connect(NkPort) ->
    #nkport{
        transp = Transp, 
        remote_ip = Ip, 
        remote_port = Port, 
        meta = Meta
    } = NkPort,
    SocketOpts = outbound_opts(NkPort),
    TranspMod = case Transp of ws -> tcp, ranch_tcp; wss -> ranch_ssl end,
    ConnTimeout = case maps:get(connect_timeout, Meta, undefined) of
        undefined -> nkpacket_config_cache:connect_timeout();
        Timeout0 -> Timeout0
    end,
    case TranspMod:connect(Ip, Port, SocketOpts, ConnTimeout) of
        {ok, Socket} -> 
            {ok, {LocalIp, LocalPort}} = TranspMod:sockname(Socket),
            Meta1 = maps:merge(#{path => <<"/">>}, Meta),
            NkPort1 = NkPort#nkport{
                local_ip = LocalIp,
                local_port = LocalPort,
                socket = Socket,
                meta = Meta1
            },
            case nkpacket_connection_ws:start_handshake(NkPort1) of
                {ok, WsProto, Rest} -> 
                    NkPort2 = case WsProto of
                        undefined -> NkPort1;
                        _ -> NkPort1#nkport{meta=Meta#{ws_proto=>WsProto}}
                    end,
                    TranspMod:setopts(Socket, [{active, once}]),
                    {ok, NkPort2, Rest};
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


%% @private
start_link(NkPort) ->
    gen_server:start_link(?MODULE, [NkPort], []).
    

%% @private Starts transport process
-spec init(term()) ->
    {ok, #state{}} | {stop, term()}.

init([NkPort]) ->
    #nkport{
        transp = Transp, 
        local_ip = Ip, 
        local_port = Port,
        meta = Meta,
        protocol = Protocol
    } = NkPort,
    process_flag(trap_exit, true),   %% Allow calls to terminate
    try
        NkPort1 = NkPort#nkport{
            listen_ip = Ip,
            listen_port = Port,
            pid = self()
        },
        Filter1 = maps:with([group, host, path, ws_proto], Meta),
        Filter2 = Filter1#{id=>self(), module=>?MODULE},
        case nkpacket_cowboy:start(NkPort1, Filter2) of
            {ok, SharedPid} -> ok;
            {error, Error} -> SharedPid = throw(Error)
        end,
        erlang:monitor(process, SharedPid),
        case Port of
            0 -> 
                {ok, {_, _, Port1}} = nkpacket:get_local(SharedPid);
            _ -> 
                Port1 = Port
        end,
        Group = maps:get(group, Meta, none),
        nklib_proc:put(nkpacket_listeners, Group),
        ConnMeta = maps:with(?CONN_LISTEN_OPTS, Meta),
        ConnPort = NkPort1#nkport{
            local_port = Port1,
            listen_port = Port1,
            socket = SharedPid,
            meta = maps:with(?CONN_LISTEN_OPTS, Meta)        
        },   
        nklib_proc:put({nkpacket_listen, Group, Protocol, Transp}, ConnPort),
        {ok, ProtoState} = nkpacket_util:init_protocol(Protocol, listen_init, ConnPort),
        MonRef = case Meta of
            #{monitor:=UserRef} -> 
                erlang:monitor(process, UserRef);
            _ -> 
                undefined
        end,
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
            lager:error("could not start ~p transport on ~p:~p (~p)", 
                   [Transp, Ip, Port, TError]),
        {stop, TError}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, term(), #state{}} | 
    {stop, term(), #state{}} | {stop, term(), term(), #state{}}.

handle_call({nkpacket_apply_nkport, Fun}, _From, #state{nkport=NkPort}=State) ->
    {reply, Fun(NkPort), State};

handle_call({start, Ip, Port, Path, Pid}, _From, State) ->
    #state{nkport=#nkport{meta=Meta}=NkPort} = State,
    NkPort1 = NkPort#nkport{
        remote_ip = Ip,
        remote_port = Port,
        socket = Pid,
        meta = Meta#{path=>Path}
    },
    % Connection will monitor listen process (unsing 'pid' and 
    % the cowboy process (using 'socket')
    case nkpacket_connection:start(NkPort1) of
        {ok, #nkport{pid=ConnPid}=NkPort2} ->
            lager:debug("WS listener accepted connection: ~p", 
                  [NkPort2]),
            {reply, {ok, ConnPid}, State};
        {error, Error} ->
            lager:notice("WS listener did not accepted connection:"
                    " ~p", [Error]),
            {reply, next, State}
    end;

handle_call(Msg, From, State) ->
    case call_protocol(listen_handle_call, [Msg, From], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    case call_protocol(listen_handle_cast, [Msg], State) of
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
    % lager:warning("WS received SHARED stop"),
    {stop, Reason, State};

handle_info(Msg, State) ->
    case call_protocol(listen_handle_info, [Msg], State) of
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
    catch call_protocol(listen_stop, [Reason], State),
    ok.



% %% ===================================================================
% %% Shared callbacks
% %% ===================================================================


%% @private Called from nkpacket_cowboy:execute/2, inside
%% cowboy's connection process
-spec cowboy_init(#nkport{}, cowboy_req:req(), list()) ->
    term().

cowboy_init(Pid, Req, Env) ->
    {Ip, Port} = cowboy_req:peer(Req),
    Path = cowboy_req:path(Req),
    case catch gen_server:call(Pid, {start, Ip, Port, Path, self()}, infinity) of
        {ok, ConnPid} ->
            cowboy_websocket:upgrade(Req, Env, ?MODULE, ConnPid, infinity, run);
        next ->
            next;
        {'EXIT', _} ->
            next
    end.



% %% ===================================================================
% %% Cowboy's callbacks
% %% ===================================================================


%% @private
-spec websocket_handle({text | binary | ping | pong, binary()}, Req, State) ->
    {ok, Req, State} |
    {ok, Req, State, hibernate} |
    {reply, cow_ws:frame() | [cow_ws:frame()], Req, State} |
    {reply, cow_ws:frame() | [cow_ws:frame()], Req, State, hibernate} | 
    {stop, Req, State}
    when Req::cowboy_req:req(), State::any().

websocket_handle({text, Msg}, Req, ConnPid) ->
    nkpacket_connection:incoming(ConnPid, {text, Msg}),
    {ok, Req, ConnPid};

websocket_handle({binary, Msg}, Req, ConnPid) ->
    nkpacket_connection:incoming(ConnPid, {binary, Msg}),
    {ok, Req, ConnPid};

websocket_handle(ping, Req, ConnPid) ->
    {reply, pong, Req, ConnPid};

websocket_handle({ping, Body}, Req, ConnPid) ->
    {reply, {pong, Body}, Req, ConnPid};

websocket_handle(pong, Req, ConnPid) ->
    {ok, Req, ConnPid};

websocket_handle({pong, Body}, Req, ConnPid) ->
    nkpacket_connection:incoming(ConnPid, {pong, Body}),
    {ok, Req, ConnPid};

websocket_handle(Other, Req, ConnPid) ->
    lager:warning("WS Handler received unexpected ~p", [Other]),
    {stop, Req, ConnPid}.


%% @private
-spec websocket_info(any(), Req, State) ->
    {ok, Req, State} |
    {ok, Req, State, hibernate} |
    {reply, cow_ws:frame() | [cow_ws:frame()], Req, State} |
    {reply, cow_ws:frame() | [cow_ws:frame()], Req, State, hibernate} |
    {stop, Req, State}
    when Req::cowboy_req:req(), State::any().

websocket_info({nkpacket_send, Frames}, Req, State) ->
    {reply, Frames, Req, State};

websocket_info(nkpacket_stop, Req, State) ->
    {stop, Req, State};

websocket_info(Info, Req, State) ->
    lager:error("Module ~p received unexpected info ~p", [?MODULE, Info]),
    {ok, Req, State}.


%% @private
terminate(Reason, _Req, ConnPid) ->
    lager:debug("WS process terminate: ~p", [Reason]),
    nkpacket_connection:stop(ConnPid, normal),
    ok.



%% ===================================================================
%% Util
%% ===================================================================



%% @private Gets socket options for outbound connections
-spec outbound_opts(#nkport{}) ->
    list().

outbound_opts(#nkport{transp=ws}) ->
    [binary, {active, false}, {nodelay, true}, {keepalive, true}, {packet, raw}];

outbound_opts(#nkport{transp=wss, meta=Opts}) ->
    Base = [binary, {active, false}, {nodelay, true}, {keepalive, true}, {packet, raw}],
    nkpacket_config:add_tls_opts(Base, Opts).




%% ===================================================================
%% Util
%% ===================================================================

%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).


%% @private


