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

%% @private TCP/TLS Transport.
%% This module is used for both inbound and outbound TCP and TLS connections.

-module(nkpacket_transport_tcp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_listener/1, connect/1, get_port/1, start_link/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).
-export([start_link/4]).

-include("nkpacket.hrl").


%% ===================================================================
%% Private
%% ===================================================================

%% @private Starts a new listening server
-spec get_listener(nkpacket:nkport()) ->
    supervisor:child_spec().

get_listener(#nkport{transp=Transp}=NkPort) when Transp==tcp; Transp==tls ->
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
    {ok, nkpacket:nkport()} | {error, term()}.
         
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
        SocketOpts = outbound_opts(NkPort),
        {InetMod, TranspMod, _} = get_modules(Transp),
        ConnTimeout = case maps:get(connect_timeout, Meta, undefined) of
            undefined -> nkpacket_config_cache:connect_timeout(Domain);
            Timeout0 -> Timeout0
        end,
        Socket = case TranspMod:connect(Ip, Port, SocketOpts, ConnTimeout) of
            {ok, Socket0} -> Socket0;
            {error, Error} -> throw(Error)
        end,
        {ok, {LocalIp, LocalPort}} = InetMod:sockname(Socket),
        Meta1 = case maps:is_key(idle_timeout, Meta) of
            true -> Meta;
            false -> Meta#{idle_timeout=>nkpacket_config_cache:tcp_timeout(Domain)}
        end,
        RemoveOpts = [certfile, keyfile],
        NkPort1 = NkPort#nkport{
            local_ip = LocalIp,
            local_port = LocalPort,
            socket = Socket,
            meta = maps:without(RemoveOpts, Meta1)
        },
        {ok, Pid} = nkpacket_connection:start(NkPort1),
        TranspMod:controlling_process(Socket, Pid),
        InetMod:setopts(Socket, [{active, once}]),
        ?debug(Domain, "~p connected to ~p", [Transp, {Ip, Port}]),
        {ok, NkPort1#nkport{pid=Pid}}
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

%% @private
start_link(NkPort) ->
    gen_server:start_link(?MODULE, [NkPort], []).


-record(state, {
    nkport :: nkpacket:nkport(),
    ranch_id :: term(),
    ranch_pid :: pid(),
    protocol :: nkpacket:protocol(),
    proto_state :: term()
}).


%% @private 
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
    ListenOpts = listen_opts(NkPort),
    case nkpacket_transport:open_port(NkPort, ListenOpts) of
        {ok, Socket}  ->
            Meta1 = case maps:is_key(idle_timeout, Meta) of
                true -> Meta;
                false -> Meta#{idle_timeout=>nkpacket_config_cache:tcp_timeout(Domain)}
            end,
            {InetMod, _, RanchMod} = get_modules(Transp),
            {ok, {_, Port1}} = InetMod:sockname(Socket),
            RemoveOpts = [tcp_listeners, tcp_max_connections, certfile, keyfile],
            NkPort1 = NkPort#nkport{
                local_port = Port1, 
                listen_ip = Ip,
                listen_port = Port1,
                pid = self(),
                socket = Socket,
                meta = maps:without(RemoveOpts, Meta1)
            },
            RanchId = {Transp, Ip, Port1},
            Listeners = maps:get(tcp_listeners, Meta, 100),
            Max = maps:get(tcp_max_connections, Meta, 1024),
            RanchSpec = ranch:child_spec(
                RanchId, 
                Listeners,
                RanchMod, 
                [{socket, Socket}, {max_connections, Max}],
                ?MODULE, 
                [NkPort1]),
            % we don't want a fail in ranch to switch everything off
            RanchSpec1 = setelement(3, RanchSpec, temporary),
            {ok, RanchPid} = nkpacket_sup:add_ranch(RanchSpec1),
            link(RanchPid),
            nklib_proc:put(nkpacket_transports, NkPort1),
            nklib_proc:put({nkpacket_listen, Domain, Protocol}, NkPort1),
            {Protocol1, ProtoState1} = 
                nkpacket_util:init_protocol(Protocol, listen_init, NkPort1),
            State = #state{
                nkport = NkPort1,
                ranch_id = RanchId,
                ranch_pid = RanchPid,
                protocol = Protocol1,
                proto_state = ProtoState1
            },
            {ok, State};
        {error, Error} ->
            ?error(Domain, "could not start ~p transport on ~p:~p (~p)", 
                   [Transp, Ip, Port, Error]),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), nklib_util:gen_server_from(), #state{}) ->
    nklib_util:gen_server_call(#state{}).

handle_call(get_port, _From, #state{nkport=#nkport{local_port=Port}}=State) ->
    {reply, {ok, Port}, State};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, From, State) ->
    case call_protocol(listen_handle_call, [Msg, From], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    nklib_util:gen_server_cast(#state{}).

handle_cast(Msg, State) ->
    case call_protocol(listen_handle_cast, [Msg], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    nklib_util:gen_server_info(#state{}).

handle_info({'EXIT', Pid, Reason}, #state{ranch_pid=Pid}=State) ->
    {stop, {ranch_failed, Reason}, State};

handle_info(Msg, State) ->
    case call_protocol(listen_handle_info, [Msg], State) of
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

terminate(Reason, #state{nkport=#nkport{domain=Domain}}=State) ->  
    ?debug(Domain, "TCP/TLS listener stop: ~p", [Reason]),
    #state{
        ranch_id = RanchId,
        nkport = #nkport{transp=Transp, socket=Socket}
    } = State,
    catch call_protocol(listen_stop, [Reason], State),
    catch nkpacket_sup:del_ranch({ranch_listener_sup, RanchId}),
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

start_link(Ref, Socket, TranspModule, [#nkport{meta=Meta}=NkPort]) ->
    {ok, {LocalIp, LocalPort}} = TranspModule:sockname(Socket),
    {ok, {RemoteIp, RemotePort}} = TranspModule:peername(Socket),
    NkPort1 = NkPort#nkport{
        local_ip = LocalIp,
        local_port = LocalPort,
        remote_ip = RemoteIp,
        remote_port = RemotePort,
        socket = Socket
    },
    Opts = lists:flatten([
        case Meta of #{tcp_packet:=Packet} -> {packet, Packet}; _ -> [] end,
        {keepalive, true}, {active, once}
    ]),
    TranspModule:setopts(Socket, Opts),
    nkpacket_connection:ranch_start_link(NkPort1, Ref).


%% ===================================================================
%% Internal
%% ===================================================================


%% @private Gets socket options for outbound connections
-spec outbound_opts(#nkport{}) ->
    list().

outbound_opts(#nkport{transp=tcp, meta=Opts}) ->
    [
        {packet, case Opts of #{tcp_packet:=Packet} -> Packet; _ -> raw end},
        binary, {active, false}, {nodelay, true}, {keepalive, true}
    ];

outbound_opts(#nkport{transp=tls, meta=Opts}) ->
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
        {packet, case Opts of #{tcp_packet:=Packet} -> Packet; _ -> raw end},
        binary, {active, false}, {nodelay, true}, {keepalive, true},
        case Cert of "" -> []; _ -> {certfile, Cert} end,
        case Key of "" -> []; _ -> {keyfile, Key} end
    ]).


%% @private Gets socket options for listening connections
-spec listen_opts(#nkport{}) ->
    list().

listen_opts(#nkport{transp=tcp, local_ip=Ip, meta=Opts}) ->
    [
        {packet, case Opts of #{tcp_packet:=Packet} -> Packet; _ -> raw end},
        {ip, Ip}, {active, false}, binary,
        {nodelay, true}, {keepalive, true},
        {reuseaddr, true}, {backlog, 1024}
    ];

listen_opts(#nkport{transp=tls, local_ip=Ip, meta=Opts}) ->
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
        {packet, case Opts of #{tcp_packet:=Packet} -> Packet; _ -> raw end},
        {ip, Ip}, {active, false}, binary,
        {nodelay, true}, {keepalive, true},
        {reuseaddr, true}, {backlog, 1024},
        {versions, ['tlsv1.2', 'tlsv1.1', 'tlsv1']}, % Avoid SSLv3
        case Cert of "" -> []; _ -> {certfile, Cert} end,
        case Key of "" -> []; _ -> {keyfile, Key} end
    ]).


%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).


%% @private
get_modules(tcp) -> {inet, gen_tcp, ranch_tcp};
get_modules(tls) -> {ssl, ssl, ranch_ssl}.




