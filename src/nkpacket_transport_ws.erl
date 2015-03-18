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
%% For listening, we start this server and also a 'shared' tcp/tls transport.
%% When a new connection arrives, the nkpacket_transport_tcp process will call
%% cowboy_init/2, where we must decide to process this request or 
%% pass it to the next listening sharing this transport.
%%
%% It it is for us, we start a new connection. When a new packet arrives,
%% we send it to the connection.
%%
%% For outbound connections, we start a normal tcp/ssl connection and let it be
%% managed by a fresh nkpacket_connection process

-module(nkpacket_transport_ws).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_listener/1, connect/1, get_port/1]).
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
    #nkport{domain=Domain, local_ip=Ip, local_port=Port} = NkPort,
    {
        {Domain, Transp, Ip, Port, make_ref()},
        {?MODULE, start_link, [NkPort]},
        transient,
        5000,
        worker,
        [?MODULE]
    }.


%% @private Starts a new connection to a remote server
-spec connect(nkpacket:nkport()) ->
    {ok, term()} | {error, term()}.
         
connect(NkPort) ->
    #nkport{
        domain = Domain,
        transp = Transp, 
        remote_ip = Ip, 
        remote_port = Port, 
        meta = Meta
    } = NkPort,
    try
        case nkpacket_connection_lib:is_max(Domain) of
            false -> ok;
            true -> throw(max_connections)
        end,
        {SockTransp, TranspMod} = case Transp of
            ws -> {tcp, ranch_tcp};
            wss -> {tls, ranch_ssl}
        end,
        SocketOpts = outbound_opts(NkPort),
        ConnTimeout = case maps:get(connect_timeout, Meta, undefined) of
            undefined -> nkpacket_config_cache:connect_timeout(Domain);
            Timeout0 -> Timeout0
        end,
        Socket = case TranspMod:connect(Ip, Port, SocketOpts, ConnTimeout) of
            {ok, Socket0} -> Socket0;
            {error, Error1} -> throw(Error1) 
        end,
        {ok, {LocalIp, LocalPort}} = TranspMod:sockname(Socket),
        Meta1 = case maps:is_key(idle_timeout, Meta) of
            true -> Meta;
            false -> Meta#{idle_timeout=>nkpacket_config_cache:ws_timeout(Domain)}
        end,
        NkPort1 = NkPort#nkport{
            local_ip = LocalIp,
            local_port = LocalPort,
            socket = Socket,
            meta = Meta1
        },
        case nkpacket_connection_ws:start_handshake(NkPort1) of
            {ok, ExtsMap, Rest} -> ok;
            {error, Error} -> ExtsMap = Rest = throw(Error)
        end,
        NkPort2 = NkPort1#nkport{meta=Meta1#{ws_exts=>ExtsMap}},
        {ok, Pid} = nkpacket_connection:start(NkPort2),
        TranspMod:controlling_process(Socket, Pid),
        TranspMod:setopts(Socket, [{active, once}]),
        ?notice(Domain, "~p connected to ~p", [Transp, {Ip, Port}]),
        case Rest of
            <<>> -> ok;
            _ -> nkpacket_connection:incoming(Pid, Rest)
        end,
        {ok, NkPort2#nkport{pid=Pid}}
    catch
        throw:TError -> {error, TError}
    end.


%% @private Get transport current port
-spec get_port(pid()) ->
    {ok, inet:port_number()}.

get_port(Pid) ->
    gen_server:call(Pid, get_port).



%% ===================================================================
%% gen_server
%% ===================================================================

-record(state, {
    nkport :: nkpacket:nkport(),
    protocol :: nkpacket:protocol(),
    proto_state :: term(),
    shared :: pid()
}).



%% @private
start_link(NkPort) ->
    gen_server:start_link(?MODULE, [NkPort], []).
    

%% @private Starts transport process
-spec init(term()) ->
    nklib_util:gen_server_init(#state{}).

init([NkPort]) ->
    #nkport{
        domain = Domain,
        transp = Transp, 
        local_ip = Ip, 
        local_port = Port,
        meta = Meta,
        protocol = Protocol
    } = NkPort,
    process_flag(trap_exit, true),   %% Allow calls to terminate
    try
        Host = maps:get(host, Meta, <<>>),
        HostList = [H || {H, _} <- nklib_parse:tokens(Host)],
        Path = maps:get(path, Meta, <<>>),
        PathList = [P || {P, _} <- nklib_parse:tokens(Path)],
        ParsedPaths = nkpacket_transport_http:parse_paths(PathList),
        Meta1 = Meta#{http_match=>{HostList, ParsedPaths}},
        % This is the port for tcp/tls and also what will be sent to cowboy_init
        SharedPort = NkPort#nkport{
            listen_ip = Ip,
            pid = self(),
            meta = Meta1
        },
        case nkpacket_cowboy:start(SharedPort) of
            {ok, SharedPid} -> ok;
            {error, Error} -> SharedPid = throw(Error)
        end,
        erlang:monitor(process, SharedPid),
        case Port of
            0 -> {ok, Port1} = nkpacket_transport_tcp:get_port(SharedPid);
            _ -> Port1 = Port
        end,
        RemoveOpts = [tcp_listeners, tcp_max_connections, certfile, keyfile],
        NkPort1 = NkPort#nkport{
            local_port = Port1,
            listen_ip = Ip,
            listen_port = Port1,
            pid = self(),
            socket = SharedPid,
            meta = maps:without(RemoveOpts, Meta)
        },   
        nklib_proc:put(nkpacket_transports, NkPort1),
        nklib_proc:put({nkpacket_listen, Domain, Protocol}, NkPort1),
        {Protocol1, ProtoState1} = case Protocol of
            undefined ->
                {undefined, undefined};
            _ ->
                case catch Protocol:listen_init(NkPort1) of
                    {'EXIT', _} -> {undefined, undefined};
                    ProtoState -> {Protocol, ProtoState}
                end
        end,
        State = #state{
            nkport = NkPort,
            protocol = Protocol1,
            proto_state = ProtoState1,
            shared = SharedPid
        },
        {ok, State}
    catch
        throw:TError -> 
            ?error(Domain, "could not start ~p transport on ~p:~p (~p)", 
                   [Transp, Ip, Port, TError]),
        {stop, TError}
    end.


%% @private
-spec handle_call(term(), nklib_util:gen_server_from(), #state{}) ->
    nklib_util:gen_server_call(#state{}).

handle_call(get_port, _From, #state{nkport=#nkport{local_port=Port}}=State) ->
    {reply, {ok, Port}, State};

handle_call(Msg, From, State) ->
    case call_protocol(listen_handle_call, [Msg, From], State) of
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    nklib_util:gen_server_cast(#state{}).

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    case call_protocol(listen_handle_cast, [Msg], State) of
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    nklib_util:gen_server_info(#state{}).

handle_info({'DOWN', _MRef, process, Pid, Reason}, #state{shared=Pid}=State) ->
    % lager:warning("WS received SHARED stop"),
    {stop, Reason, State};

handle_info(Msg, State) ->
    case call_protocol(listen_handle_info, [Msg], State) of
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
    catch call_protocol(listen_stop, [Reason], State),
    ok.



% %% ===================================================================
% %% Shared callbacks
% %% ===================================================================


%% @private Called from nkpacket_transport_tcp:execute/2, inside
%% cowboy's connection process
-spec cowboy_init(#nkport{}, cowboy_req:req(), list()) ->
    term().

cowboy_init(#nkport{domain=Domain, meta=Meta}=NkPort, Req, Env) ->
    {HostList, PathList} = maps:get(http_match, Meta),
    ReqHost = cowboy_req:host(Req),
    ReqPath = cowboy_req:path(Req),
    case 
        (HostList==[] orelse lists:member(ReqHost, HostList)) andalso
        (PathList==[] orelse nkpacket_transport_http:check_paths(ReqPath, PathList))
    of
        false ->
            next;
        true ->
            Req1 = case Meta of
                #{ws_proto:=WsProto} ->
                    Hd = <<"sec-websocket-protocol">>,
                    ReqWsProtos = cowboy_req:parse_header(Hd, Req, []),
                    case lists:member(WsProto, ReqWsProtos) of
                        true -> cowboy_req:set_resp_header(Hd, WsProto, Req);
                        false -> next
                    end;
                _ ->
                    Req
            end,
            case Req1 of
                next ->
                    next;
                _ ->
                    {RemoteIp, RemotePort} = cowboy_req:peer(Req1),
                    NkPort1 = NkPort#nkport{
                        remote_ip = RemoteIp,
                        remote_port = RemotePort,
                        socket = self(),
                        meta = maps:without([http_match], Meta)
                    },
                    {ok, ConnPid} = nkpacket_connection:start(NkPort1),
                    ?debug(Domain, "WS listener accepted connection: ~p", [NkPort1]),
                    cowboy_websocket:upgrade(Req1, Env, nkpacket_transport_ws, 
                                             ConnPid, infinity, run)
            end
    end.



% %% ===================================================================
% %% Cowboy's callbacks
% %% ===================================================================


%% @private
-spec websocket_handle({text | binary | ping | pong, binary()}, Req, State)
    -> {ok, Req, State}
    | {ok, Req, State, hibernate}
    | {reply, cow_ws:frame() | [cow_ws:frame()], Req, State}
    | {reply, cow_ws:frame() | [cow_ws:frame()], Req, State, hibernate}
    | {stop, Req, State}
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
-spec websocket_info(any(), Req, State)
    -> {ok, Req, State}
    | {ok, Req, State, hibernate}
    | {reply, cow_ws:frame() | [cow_ws:frame()], Req, State}
    | {reply, cow_ws:frame() | [cow_ws:frame()], Req, State, hibernate}
    | {stop, Req, State}
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
    case code:priv_dir(nkpacket) of
        PrivDir when is_list(PrivDir) ->
            DefCert = filename:join(PrivDir, "cert.pem"),
            DefKey = filename:join(PrivDir, "key.pem");
        _ ->
            DefCert = "",
            DefKey = ""
    end,
    Cert = maps:get(certfile, Opts, DefCert),
    Key = maps:get(keyfile, Opts, DefKey),
    lists:flatten([
        binary, {active, false}, {nodelay, true}, {keepalive, true}, {packet, raw},
        case Cert of "" -> []; _ -> {certfile, Cert} end,
        case Key of "" -> []; _ -> {keyfile, Key} end
    ]).




%% ===================================================================
%% Util
%% ===================================================================






%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).



