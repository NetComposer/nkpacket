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
    #nkport{transp=sctp, local_ip=Ip, local_port=Port} = NkPort,
    {
        {sctp, Ip, Port, make_ref()}, 
        {?MODULE, start_link, [NkPort]},
        transient, 
        5000, 
        worker, 
        [?MODULE]
    }.


%% @private Starts a new connection to a remote server
-spec connect(nkpacket:nkport()) ->
    {ok, pid()} | {error, term()}.

connect(#nkport{transp=sctp, pid=Pid}=NkPort) ->
    case catch gen_server:call(Pid, {connect, NkPort}, 180000) of
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
    {ok, #state{}} | {stop, term()}.

init([NkPort]) ->
    #nkport{
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
            Group = maps:get(group, Meta, none),
            nklib_proc:put(nkpacket_listeners, Group),
            ConnMeta = maps:with(?CONN_LISTEN_OPTS, Meta),
            ConnPort = NkPort1#nkport{meta=ConnMeta},
            nklib_proc:put({nkpacket_listen, Group, Protocol, sctp}, ConnPort),
            {ok, ProtoState} = nkpacket_util:init_protocol(Protocol, listen_init, NkPort1),
            MonRef = case Meta of
                #{monitor:=UserPid} -> erlang:monitor(process, UserPid);
                _ -> undefined
            end,
            State = #state{ 
                nkport = ConnPort, 
                socket = Socket,
                pending_froms = [],
                pending_conns = [],
                protocol = Protocol,
                proto_state = ProtoState,
                monitor_ref = MonRef
            },
            {ok, State};
        {error, Error} ->
            lager:error("could not start SCTP transport on ~p:~p (~p)", 
                   [Ip, Port, Error]),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, term(), #state{}} | 
    {stop, term(), #state{}} | {stop, term(), term(), #state{}}.

handle_call({connect, ConnPort}, From, State) ->
    #nkport{
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
        undefined -> nkpacket_config_cache:connect_timeout();
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

handle_call({nkpacket_apply_nkport, Fun}, _From, #state{nkport=NkPort}=State) ->
    {reply, Fun(NkPort), State};

handle_call(Msg, From, State) ->
    case call_protocol(listen_handle_call, [Msg, From], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

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
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({sctp, Socket, Ip, Port, {Anc, SAC}}, State) ->
    #state{socket=Socket, nkport=#nkport{protocol=Proto, meta=ListenMeta}} = State,
    State1 = case SAC of
        #sctp_assoc_change{state=comm_up, assoc_id=AssocId} ->
            % lager:error("COMM_UP: ~p", [AssocId]),
            #state{pending_froms=Froms} = State,
            case lists:keytake({Ip, Port}, 1, Froms) of
                {value, {_, From, Meta}, Froms1} -> 
                    Reply = do_connect(Ip, Port, AssocId, Meta, State),
                    gen_server:reply(From, Reply),
                    State#state{pending_froms=Froms1};
                false ->
                    State
            end;
        #sctp_assoc_change{state=shutdown_comp, assoc_id=_AssocId} ->
            % lager:error("COMM_DOWN: ~p", [AssocId]),
            case nkpacket_transport:get_connected({Proto, sctp, Ip, Port}, ListenMeta) of
                [Pid|_] -> nkpacket_connection:stop(Pid, normal);
                _ -> ok
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
                    lager:notice("Error ~p on SCTP connection up", [Error])
            end,
            State;
        Other ->
            lager:notice("SCTP unknown data from ~p, ~p: ~p", [Ip, Port, Other]),
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
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, #state{socket=Socket}=State) ->  
    lager:debug("SCTP server process stopped", []),
    catch call_protocol(listen_stop, [Reason], State),
    gen_sctp:close(Socket).



%% ===================================================================
%% Internal
%% ===================================================================


-spec listen_opts(#nkport{}) ->
    list().

listen_opts(#nkport{local_ip=Ip, meta=Meta}) ->
    Timeout = case maps:get(idle_timeout, Meta, undefined) of
        undefined -> nkpacket_config_cache:sctp_timeout();
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
    #nkport{protocol=Proto, meta=ListenMeta} = NkPort,
    case nkpacket_transport:get_connected({Proto, sctp, Ip, Port}, ListenMeta) of
        [Pid|_] -> 
            {ok, Pid};
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
