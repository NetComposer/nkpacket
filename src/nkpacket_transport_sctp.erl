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

%% @private SCTP Transport.
-module(nkpacket_transport_sctp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([get_listener/1, connect/1]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3,   
         handle_cast/2, handle_info/2]).

-include("nkpacket.hrl").
-include_lib("kernel/include/inet_sctp.hrl").

-define(IN_STREAMS, 10).
-define(OUT_STREAMS, 10).

%% ===================================================================
%% Private
%% ===================================================================

   %% @private Starts a new listening server
-spec get_listener(nkpacket:nkport()) ->
    supervisor:child_spec().

get_listener(NkPort) ->
    #nkport{domain=Domain, transp=sctp, local_ip=Ip, local_port=Port} = NkPort,
    {
        {Domain, sctp, Ip, Port, make_ref()}, 
        {?MODULE, start_link, [NkPort]},
        transient, 
        5000, 
        worker, 
        [?MODULE]
    }.


%% @private Starts a new connection to a remote server
-spec connect(nkpacket:nkport()) ->
    {ok, nkpacket:nkport()} | {error, term()}.

connect(#nkport{transp=sctp, pid=Pid}=NkPort) ->
    case catch gen_server:call(Pid, {connect, NkPort}, ?CALL_TIMEOUT) of
        {ok, ConnPid} -> 
            {ok, ConnPid};
        {error, Error} ->
            {error, Error};
        {'EXIT', Error} -> 
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
    socket :: port(),
    pending_froms :: [{{inet:ip_address(), inet:port_number()}, {pid(), term()}, map()}],
    pending_conns :: [pid()],
    protocol :: nkpacket:protocol(),
    proto_state :: term(),
    monitor_ref :: reference()
}).


%% @private 
-spec init(term()) ->
    nklib_util:gen_server_init(#state{}).

init([NkPort]) ->
    #nkport{
        domain = Domain,
        transp = sctp,
        local_ip = Ip, 
        local_port = Port,
        protocol = Protocol,
        meta = Meta
    } = NkPort,
    process_flag(priority, high),
    process_flag(trap_exit, true),   %% Allow calls to terminate/2
    ListenOpts = listen_opts(NkPort),
    case nkpacket_transport:open_port(NkPort, ListenOpts) of
        {ok, Socket}  ->
            {ok, Port1} = inet:port(Socket),
            % RemoveOpts = [sctp_out_streams, sctp_in_streams],
            NkPort1 = NkPort#nkport{
                local_port = Port1, 
                listen_ip = Ip,
                listen_port = Port1,
                pid = self(),
                socket = {Socket, 0}
            },
            ok = gen_sctp:listen(Socket, true),
            StoredNkPort = NkPort1#nkport{meta=#{}},
            nklib_proc:put(nkpacket_transports, StoredNkPort),
            nklib_proc:put({nkpacket_listen, Domain, Protocol, sctp}, StoredNkPort),
            {ok, ProtoState} = nkpacket_util:init_protocol(Protocol, listen_init, NkPort1),
            MonRef = case Meta of
                #{monitor:=UserPid} -> erlang:monitor(process, UserPid);
                _ -> undefined
            end,
            State = #state{ 
                nkport = NkPort1#nkport{meta=maps:with(?CONN_LISTEN_OPTS, Meta)}, 
                socket = Socket,
                pending_froms = [],
                pending_conns = [],
                protocol = Protocol,
                proto_state = ProtoState,
                monitor_ref = MonRef
            },
            {ok, State};
        {error, Error} ->
            ?error(Domain, "could not start SCTP transport on ~p:~p (~p)", 
                   [Ip, Port, Error]),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), nklib_util:gen_server_from(), #state{}) ->
    nklib_util:gen_server_call(#state{}).

handle_call({connect, ConnPort}, From, State) ->
    #nkport{
        domain = Domain, 
        remote_ip = Ip, 
        remote_port = Port, 
        meta = Meta
    } = ConnPort,
    #state{
        socket = Socket, 
        pending_froms = Froms, 
        pending_conns = Conns
    } = State,
    Timeout = case maps:get(connect_timeout, Meta, undefined) of
        undefined -> nkpacket_config_cache:connect_timeout(Domain);
        Timeout0 -> Timeout0
    end,
    Self = self(),
    Fun = fun() ->
        case catch gen_sctp:connect_init(Socket, Ip, Port, [], Timeout) of
            ok ->
                % Socket process will receive the SCTP up message
                ok;
            {error, Error} ->
                gen_server:reply(From, {error, Error}),
                gen_server:cast(Self, {connection_error, From});
            Error ->
                gen_server:reply(From, {error, Error}),
                gen_server:cast(Self, {connection_error, From})
        end
    end,
    ConnPid = spawn_link(Fun),
    State1 = State#state{
        pending_froms = [{{Ip, Port}, From, Meta}|Froms],
        pending_conns = [ConnPid|Conns]
    },
    {noreply, State1};

handle_call(get_nkport, _From, #state{nkport=NkPort}=State) ->
    {reply, {ok, NkPort}, State};

handle_call(get_local, _From, #state{nkport=NkPort}=State) ->
    {reply, nkpacket:get_local(NkPort), State};

handle_call(get_user, _From, #state{nkport=NkPort}=State) ->
    {reply, nkpacket:get_user(NkPort), State};

handle_call(Msg, From, State) ->
    case call_protocol(listen_handle_call, [Msg, From], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    nklib_util:gen_server_cast(#state{}).

handle_cast({connection_error, From}, #state{pending_froms=Froms}=State) ->
    Froms1 = lists:keydelete(From, 2, Froms),
    {noreply, State#state{pending_froms=Froms1}};

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
    nklib_util:gen_server_info(#state{}).

handle_info({sctp, Socket, Ip, Port, {Anc, SAC}}, State) ->
    #state{socket=Socket, nkport=#nkport{domain=Domain, protocol=Proto}} = State,
    State1 = case SAC of
        #sctp_assoc_change{state=comm_up, assoc_id=AssocId} ->
            % lager:error("COMM_UP: ~p, ~p", [Domain, AssocId]),
            #state{pending_froms=Froms} = State,
            case lists:keytake({Ip, Port}, 1, Froms) of
                {value, {_, From, Meta}, Froms1} -> 
                    Reply = do_connect(Ip, Port, AssocId, Meta, State),
                    gen_server:reply(From, Reply),
                    State#state{pending_froms=Froms1};
                false ->
                    State
            end;
        #sctp_assoc_change{state=shutdown_comp, assoc_id=AssocId} ->
            % lager:error("COMM_DOWN: ~p, ~p", [Domain, AssocId]),
            case nkpacket_transport:get_connected(Domain, {Proto, sctp, Ip, Port}) of
                [#nkport{socket={_, AssocId}, pid=Pid}|_] ->
                    nkpacket_connection:stop(Pid, normal);
                _ ->
                    ok
            end,
            State;
        #sctp_paddr_change{} ->
            % We don't support address change yet
            State;
        #sctp_shutdown_event{assoc_id=_AssocId} ->
            % Should be already processed
            State; 
        Data when is_binary(Data) ->
            [#sctp_sndrcvinfo{assoc_id=AssocId}] = Anc,
            case do_connect(Ip, Port, AssocId, State) of
                {ok, #nkport{pid=Pid}} ->
                    nkpacket_connection:incoming(Pid, Data);
                {error, Error} ->
                    ?notice(Domain, "Error ~p on SCTP connection up", [Error])
            end,
            State;
        Other ->
            ?notice(Domain, "SCTP unknown data from ~p, ~p: ~p", [Ip, Port, Other]),
            State
    end,
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State1};

handle_info({'DOWN', MRef, process, _Pid, _Reason}, #state{monitor_ref=MRef}=State) ->
    {stop, normal, State};

handle_info({'EXIT', Pid, _Status}=Msg, #state{pending_conns=Conns}=State) ->
    case lists:member(Pid, Conns) of
        true ->
            {noreply, State#state{pending_conns=Conns--[Pid]}};
        false ->
            case call_protocol(listen_handle_info, [Msg], State) of
                undefined -> {noreply, State};
                {ok, State1} -> {noreply, State1};
                {stop, Reason, State1} -> {stop, Reason, State1}
            end
    end;

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

terminate(Reason, State) ->  
    #state{
        nkport = #nkport{domain=Domain},
        socket = Socket
    } = State,
    ?debug(Domain, "SCTP server process stopped", []),
    catch call_protocol(listen_stop, [Reason], State),
    gen_sctp:close(Socket).



%% ===================================================================
%% Internal
%% ===================================================================


-spec listen_opts(#nkport{}) ->
    list().

listen_opts(#nkport{domain=Domain, local_ip=Ip, meta=Meta}) ->
    Timeout = case maps:get(idle_timeout, Meta, undefined) of
        undefined -> nkpacket_config_cache:sctp_timeout(Domain);
        Timeout0 -> Timeout0
    end,
    OutStreams = maps:get(sctp_out_streams, Meta, ?OUT_STREAMS),
    InStreams = maps:get(sctp_in_streams, Meta, ?IN_STREAMS),
    [
        binary, {reuseaddr, true}, {ip, Ip}, {active, once},
        {sctp_initmsg, #sctp_initmsg{num_ostreams=OutStreams, max_instreams=InStreams}},
        {sctp_autoclose, Timeout},    
        {sctp_default_send_param, #sctp_sndrcvinfo{stream=0, flags=[unordered]}}
    ].


%% @private
do_connect(Ip, Port, AssocId, State) ->
    do_connect(Ip, Port, AssocId, undefined, State).


%% @private
do_connect(Ip, Port, AssocId, Meta, State) ->
    #state{nkport=NkPort, socket=Socket} = State,
    #nkport{domain=Domain, protocol=Proto, meta=ListenMeta} = NkPort,
    case nkpacket_transport:get_connected(Domain, {Proto, sctp, Ip, Port}) of
        [NkPort1|_] -> 
            {ok, NkPort1};
        [] -> 
            Meta1 = case Meta of
                undefined -> ListenMeta;
                _ -> maps:merge(ListenMeta, Meta)
            end,
            NkPort1 = NkPort#nkport{
                remote_ip = Ip, 
                remote_port = Port,
                socket = {Socket, AssocId},
                meta = Meta1
            },
            % Connection will monitor us using nkport's pid
            nkpacket_connection:start(NkPort1)
    end.
        

%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).
