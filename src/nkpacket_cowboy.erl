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
-module(nkpacket_cowboy).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).
-export([start_link/4, execute/2]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


%% ===================================================================
%% Private
%% ===================================================================

%% @private Starts a 'shared' tcp/tls listener.
%% The caller must include its pid in the nkport.
%% For http/https, a standard Cowboy is sytarted. A 'cowboy_dispatch'
%% must be included.
%% For ws/wss, for each  incoming connection, we will call 
%% nkpacket_transport_ws:cowboy_init
start(NkPort) ->
    #nkport{transp=Transp, local_ip=Ip, local_port=Port} = NkPort,
    case nklib_proc:values({nkpacket_cowboy, Transp, Ip, Port}) of
        [{_, Pid}|_] ->
            case catch gen_server:call(Pid, {start, NkPort}, infinity) of
                ok -> {ok, Pid};
                _ -> {error, shared_failed}
            end;
        [] ->
            gen_server:start(?MODULE, [NkPort], [])
    end.




%% ===================================================================
%% gen_server
%% ===================================================================

-record(state, {
    nkport :: nkpacket:nkport(),
    ranch_id :: term(),
    ranch_pid :: pid(),
    cowboy_opts = [] :: list(),
    shared = [] :: [nkpacket:nkport()]
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
        meta = Meta
    } = NkPort,
    process_flag(trap_exit, true),   %% Allow calls to terminate
    ListenOpts = listen_opts(NkPort),
    case nkpacket_transport:open_port(NkPort, ListenOpts) of
        {ok, Socket}  ->
            {InetMod, _, RanchMod} = get_modules(Transp),
            {ok, {_, Port1}} = InetMod:sockname(Socket),
            RemoveOpts = [tcp_listeners, tcp_max_connections, certfile, keyfile],
            NkPort1 = NkPort#nkport{
                local_port = Port1, 
                listen_ip = Ip,
                listen_port = Port1,
                pid = self(),
                socket = Socket,
                meta = maps:without(RemoveOpts, Meta)
            },
            RanchId = {Transp, Ip, Port1},
            Listeners = maps:get(tcp_listeners, Meta, 100),
            Max = maps:get(tcp_max_connections, Meta, 1024),
            SharedPort = NkPort#nkport{        
                local_port = Port1, 
                listen_ip = Ip,
                listen_port = Port1
            },
            CowboyOpts = maps:get(cowboy_opts, Meta, []),
            RanchSpec = ranch:child_spec(
                RanchId, 
                Listeners,
                RanchMod, 
                [{socket, Socket}, {max_connections, Max}],
                ?MODULE, 
                [{nkpacket, CowboyOpts, [SharedPort]}]),
            % we don't want a fail in ranch to switch everything off
            RanchSpec1 = setelement(3, RanchSpec, temporary),
            {ok, RanchPid} = nkpacket_sup:add_ranch(RanchSpec1),
            link(RanchPid),
            nklib_proc:put({nkpacket_cowboy, Transp, Ip, Port1}),
            erlang:monitor(process, NkPort#nkport.pid),
            State = #state{
                nkport = NkPort1#nkport{domain='$nkcowboy'},
                ranch_id = RanchId,
                ranch_pid = RanchPid,
                cowboy_opts = CowboyOpts,
                shared = [SharedPort]
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

handle_call({start, #nkport{pid=Pid}=SharedPort}, _From, State) ->
    #state{shared=Shared, nkport=NkPort} = State,
    #nkport{local_port=Port} = NkPort,
    SharedPort1 = SharedPort#nkport{local_port=Port, listen_port=Port},
    Shared1 = case lists:keymember(Pid, #nkport.pid, Shared) of
        false ->
            erlang:monitor(process, Pid),
            [SharedPort1|Shared];
        true ->
            lists:keystore(Pid, #nkport.pid, Shared, SharedPort1)
    end,
    {reply, ok, set_ranch_opts(Shared1, State)};

handle_call(get_port, _From, #state{nkport=#nkport{local_port=Port}}=State) ->
    {reply, {ok, Port}, State};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    nklib_util:gen_server_cast(#state{}).

handle_cast(Msg, State) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    nklib_util:gen_server_info(#state{}).

handle_info({'DOWN', _MRef, process, Pid, _Reason}=Msg, State) ->
    #state{shared=Shared} = State,
    case lists:keytake(Pid, #nkport.pid, Shared) of
        false ->
            lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
            {noreply, State};
        {value, _, []} ->
            % lager:warning("Last master leave"),
            {stop, normal, State};
        {value, _, Shared1} ->
            % lager:warning("master leave"),
            {noreply, set_ranch_opts(Shared1, State)}
    end;

handle_info({'EXIT', Pid, Reason}, #state{ranch_pid=Pid}=State) ->
    {stop, Reason, State};

handle_info(Msg, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    nklib_util:gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    nklib_util:gen_server_terminate().

terminate(Reason, #state{nkport=#nkport{domain=Domain}}=State) ->  
    ?debug(Domain, "Cowboy listener stop: ~p", [Reason]),
    #state{
        ranch_id = RanchId,
        nkport = #nkport{transp=Transp, socket=Socket}
    } = State,
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

start_link(Ref, Socket, TranspModule, [{nkpacket, CowboyOpts, Shared}]) ->
    Env = nklib_util:get_value(env, CowboyOpts, []),
    CowboyOpts1 = nklib_util:store_values(
        [
            {middlewares, [?MODULE]},
            {env, [{nkpacket, Shared}|Env]},
            {timeout, 5000},    % Time to close the connection if no requests
            {compress, true}    % Allow compress in WS and HTTP?
        ],
        CowboyOpts),
    % Now Cowboy will call execute/2
    cowboy_protocol:start_link(Ref, Socket, TranspModule, CowboyOpts1).


%% @private Cowboy middleware callback
-spec execute(Req, Env)-> {ok, Req, Env} | {stop, Req}
    when Req::cowboy_req:req(), Env::cowboy_middleware:env().

execute(Req, Env) ->
    Shared = nklib_util:get_value(nkpacket, Env),
    execute(Shared, Req, Env).


%% @private 
-spec execute([#nkport{}], cowboy_req:req(), list()) ->
    term().

execute([], Req, _Env) ->
    {stop, cowboy_req:reply(404, [{<<"server">>, <<"NkPACKET">>}], Req)};

execute([#nkport{transp=Transp}=SharedPort|Rest], Req, Env) ->
    Module = case Transp of
        http -> nkpacket_transport_http;
        https -> nkpacket_transport_http;
        ws -> nkpacket_transport_ws;
        wss -> nkpacket_transport_ws
    end,
    case Module:cowboy_init(SharedPort, Req, Env) of
        next -> 
            execute(Rest, Req, Env);
        Result ->
            Result
    end.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private Gets socket options for listening connections
-spec listen_opts(#nkport{}) ->
    list().

listen_opts(#nkport{transp=Transp, local_ip=Ip, meta=Opts})
        when Transp==ws; Transp==http ->
    [
        {packet, case Opts of #{tcp_packet:=Packet} -> Packet; _ -> raw end},
        {ip, Ip}, {active, false}, binary,
        {nodelay, true}, {keepalive, true},
        {reuseaddr, true}, {backlog, 1024}
    ];

listen_opts(#nkport{transp=Transp, local_ip=Ip, meta=Opts})
        when Transp==wss; Transp==https ->
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
set_ranch_opts(Shared, #state{cowboy_opts=Opts, ranch_id=RanchId}=State) ->
    ok = ranch_server:set_protocol_options(RanchId, [{nkpacket, Opts, Shared}]),
    State#state{shared=Shared}.


%% @private
get_modules(ws) -> {inet, gen_tcp, ranch_tcp};
get_modules(wss) -> {ssl, ssl, ranch_ssl};
get_modules(http) -> {inet, gen_tcp, ranch_tcp};
get_modules(https) -> {ssl, ssl, ranch_ssl}.





