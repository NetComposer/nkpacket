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

%% @private SCTP Transport.
-module(nkpacket_transport_sctp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([get_listener/1, connect/1]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3,   
         handle_cast/2, handle_info/2]).

-include("nkpacket.hrl").
-include_lib("kernel/include/inet_sctp.hrl").

%% To get debug info, start with debug=>true

-define(DEBUG(Txt, Args),
    case get(nkpacket_debug) of
        true -> ?LLOG(debug, Txt, Args);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args), lager:Type("NkPACKET SCTP "++Txt, Args)).


%% ===================================================================
%% Private
%% ===================================================================

   %% @private Starts a new listening server
-spec get_listener(nkpacket:nkport()) ->
    supervisor:child_spec().

get_listener(#nkport{id=Id, listen_ip=Ip, listen_port=Port, transp=sctp}=NkPort) ->
    Str = nkpacket_util:conn_string(sctp, Ip, Port),
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
    {ok, #nkport{}} | {error, term()}.

connect(#nkport{transp=sctp, pid=Pid}=NkPort) ->
    case catch gen_server:call(Pid, {nkpacket_connect, NkPort}, 180000) of
        {ok, NkPort2} ->
            {ok, NkPort2};
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
        class = Class,
        transp = sctp,
        listen_ip  = Ip,
        listen_port = Port,
        protocol = Protocol,
        opts = Meta
    } = NkPort,
    process_flag(priority, high),
    process_flag(trap_exit, true),   %% Allow calls to terminate/2
    Debug = maps:get(debug, Meta, false),
    put(nkpacket_debug, Debug),
    ListenOpts = listen_opts(NkPort),
    case nkpacket_transport:open_port(NkPort, ListenOpts) of
        {ok, Socket}  ->
            {ok, Port1} = inet:port(Socket),
            NkPort1 = NkPort#nkport{
                local_ip = Ip,
                local_port = Port1, 
                listen_port = Port1,
                pid = self(),
                socket = {Socket, 0}
            },
            ok = gen_sctp:listen(Socket, true),
            nkpacket_util:register_listener(NkPort),
            ConnMeta = maps:with(?CONN_LISTEN_OPTS, Meta),
            ConnPort = NkPort1#nkport{opts=ConnMeta},
            ListenType = case size(Ip) of
                4 -> nkpacket_listen4;
                8 -> nkpacket_listen6
            end,
            nklib_proc:put({ListenType, Class, Protocol, sctp}, ConnPort),
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
            ?LLOG(error, "could not start SCTP transport on ~p:~p (~p)", 
                   [Ip, Port, Error]),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}} |
    {stop, term(), #state{}} | {stop, term(), term(), #state{}}.

handle_call({nkpacket_connect, ConnPort}, From, State) ->
    #nkport{
        remote_ip = Ip,
        remote_port = Port,
        opts = Meta
    } = ConnPort,
    #state{
        socket = Socket, 
        pending_froms = Froms, 
        pending_conns = Conns
    } = State,
    Timeout = case maps:get(connect_timeout, Meta, undefined) of
        undefined ->
            nkpacket_config:connect_timeout();
        Timeout0 ->
            Timeout0
    end,
    Self = self(),
    Fun = fun() ->
        case catch gen_sctp:connect_init(Socket, Ip, Port, [], Timeout) of
            ok ->
                % Socket process will receive the SCTP up message
                ok;
            {error, Error} ->
                gen_server:reply(From, {error, Error}),
                gen_server:cast(Self, {nkpacket_connection_error, From});
            Error ->
                gen_server:reply(From, {error, Error}),
                gen_server:cast(Self, {nkpacket_connection_error, From})
        end
    end,
    ConnPid = spawn_link(Fun),
    State2 = State#state{
        pending_froms = [{{Ip, Port}, From, Meta}|Froms],
        pending_conns = [ConnPid|Conns]
    },
    {noreply, State2};

handle_call({nkpacket_apply_nkport, Fun}, _From, #state{nkport=NkPort}=State) ->
    {reply, Fun(NkPort), State};

handle_call(nkpacket_stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(Msg, From, #state{nkport=NkPort}=State) ->
    case call_protocol(listen_handle_call, [Msg, From, NkPort], State) of
        undefined ->
            {noreply, State};
        {ok, State1} ->
            {noreply, State1};
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({nkpacket_connection_error, From}, #state{pending_froms=Froms}=State) ->
    Froms1 = lists:keydelete(From, 2, Froms),
    {noreply, State#state{pending_froms=Froms1}};

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

handle_info({sctp, Socket, Ip, Port, {Anc, SAC}}, State) ->
    #state{socket=Socket, nkport=NkPort} = State,
    #nkport{class=Class, protocol=Proto} = NkPort,
    State1 = case SAC of
        #sctp_assoc_change{state=comm_up, assoc_id=AssocId} ->
            ?DEBUG("COMM_UP: ~p", [AssocId]),
            #state{pending_froms=Froms} = State,
            case lists:keytake({Ip, Port}, 1, Froms) of
                {value, {_, From, Meta}, Froms1} -> 
                    Reply = case do_connect(Ip, Port, AssocId, Meta, State) of
                        {ok, Pid} ->
                            {ok, NkPort#nkport{pid=Pid}};
                        {error, Error} ->
                            {error, Error}
                    end,
                    gen_server:reply(From, Reply),
                    State#state{pending_froms=Froms1};
                false ->
                    State
            end;
        #sctp_assoc_change{state=shutdown_comp, assoc_id=AssocId} ->
            ?DEBUG("COMM_DOWN: ~p", [AssocId]),
            Conn = #nkconn{protocol=Proto, transp=sctp, ip=Ip, port=Port, opts=#{class=>Class}},
            case nkpacket_transport:get_connected(Conn) of
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
                {ok, Pid} when is_pid(Pid) ->
                    nkpacket_connection:incoming(Pid, Data);
                {error, Error} ->
                    ?LLOG(info, "error ~p on SCTP connection up", [Error])
            end,
            State;
        Other ->
            ?LLOG(info, "SCTP unknown data from ~p, ~p: ~p", [Ip, Port, Other]),
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
            #state{nkport=NkPort} = State,
            case call_protocol(listen_handle_info, [Msg, NkPort], State) of
                undefined -> {noreply, State};
                {ok, State1} -> {noreply, State1};
                {stop, Reason, State1} -> {stop, Reason, State1}
            end
    end;

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

terminate(Reason, #state{nkport=NkPort, socket=Socket}=State) ->  
    ?DEBUG("server process stopped", []),
    catch call_protocol(listen_stop, [Reason, NkPort], State),
    gen_sctp:close(Socket).



%% ===================================================================
%% Internal
%% ===================================================================


-spec listen_opts(#nkport{}) ->
    list().

listen_opts(#nkport{listen_ip=Ip, opts=Meta}) ->
    Timeout = case maps:get(idle_timeout, Meta, undefined) of
        undefined -> nkpacket_config:sctp_timeout();
        Timeout0 -> Timeout0
    end,
    OutStreams = case maps:get(sctp_out_streams, Meta, undefined) of
        undefined -> nkpacket_config:sctp_out_streams();
        OS -> OS
    end,
    InStreams = case maps:get(sctp_in_streams, Meta, undefined) of
        undefined -> nkpacket_config:sctp_in_streams();
        IS -> IS
    end,
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
    #nkport{class=Class, protocol=Proto, opts=ListenMeta} = NkPort,
    Conn = #nkconn{protocol=Proto, transp=sctp, ip=Ip, port=Port, opts=#{class=>Class}},
    case nkpacket_transport:get_connected(Conn) of
        [Pid|_] -> 
            {ok, Pid};
        [] -> 
            Meta2 = case Meta of
                undefined ->
                    ListenMeta;
                _ ->
                    maps:merge(ListenMeta, Meta)
            end,
            NkPort2 = NkPort#nkport{
                remote_ip = Ip,
                remote_port = Port,
                socket = {Socket, AssocId},
                opts = Meta2
            },
            % Connection will monitor us using nkport's pid
            nkpacket_connection:start(NkPort2)
    end.
        

%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).
