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

%% @private UDP Transport Module.
-module(nkpacket_transport_udp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([send_stun_sync/4, send_stun_async/3, get_port/1]).
-export([get_listener/1, connect/1, send/5]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
             handle_info/2]).

-include("nkpacket.hrl").

-define(RECV_BURST, 100).


%% ===================================================================
%% Public
%% ===================================================================


%% @private Sends a STUN binding request
%% It does not open a new NkPACKET's UDP connection
send_stun_sync(Pid, Ip, Port, Timeout) ->
    case catch gen_server:call(Pid, {send_stun, Ip, Port}, Timeout) of
        {ok, StunIp, StunPort} -> 
            {ok, StunIp, StunPort};
        error -> 
            error
    end.


%% @private Sends a STUN binding request
send_stun_async(Pid, Ip, Port) ->
    gen_server:cast(Pid, {send_stun, Ip, Port, self()}).


%% @private Get transport current port
-spec get_port(pid()) ->
    {ok, inet:port_number()}.

get_port(Pid) ->
    gen_server:call(Pid, get_port).



%% ===================================================================
%% Private
%% ===================================================================


%% @private Starts a new listening server
-spec get_listener(nkpacket:nkport()) ->
    supervisor:child_spec().

get_listener(NkPort) ->
    #nkport{domain=Domain, transp=udp, local_ip=Ip, local_port=Port} = NkPort,
    {
        {Domain, udp, Ip, Port, make_ref()}, 
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
        transp = udp, 
        remote_ip = Ip,
        remote_port = Port, 
        pid = Pid, 
        meta = Meta
    } = NkPort,
    Timeout = case maps:get(connect_timeout, Meta, undefined) of
        undefined -> nkpacket_config_cache:connect_timeout(Domain);
        Timeout0 -> Timeout0
    end,
    case catch gen_server:call(Pid, {connect, Ip, Port}, Timeout) of
        {ok, NkPort1} -> 
            {ok, NkPort1};
        {error, Error} ->
            {error, Error};
        {'EXIT', Error} -> 
            {error, Error}
    end.


%% @private Function to send data if connections are not started 
send(#nkport{transp=udp, pid=Pid}, Ip, Port, Data, Timeout) ->
    gen_server:call(Pid, {send, Ip, Port, Data}, Timeout).


%% ===================================================================
%% gen_server
%% ===================================================================

%% @private
start_link(NkPort) -> 
    gen_server:start_link(?MODULE, [NkPort], []).


-record(stun, {
    id :: binary(),
    dest :: {inet:ip_address(), inet:port_number()},
    packet :: binary(),
    retrans_timer :: reference(),
    next_retrans :: integer(),
    from :: {call, nklib_util:gen_server_from()} | {cast, pid()}
}).

-record(state, {
    nkport :: nkpacket:nkport(),
    socket :: port(),
    tcp_pid :: pid(),
    no_connections :: boolean(),
    reply_stun :: boolean(),
    stuns :: [#stun{}],
    timer_t1 :: integer(),
    protocol :: nkpacket:protocol(),
    proto_state :: term(),
    user_ref :: reference()
}).


%% @private 
-spec init(term()) ->
    nklib_util:gen_server_init(#state{}).

init([NkPort]) ->
    #nkport{
        domain = Domain, 
        transp = udp,
        local_ip = Ip, 
        local_port = Port,
        protocol = Protocol, 
        meta = Meta
    } = NkPort,
    process_flag(priority, high),
    process_flag(trap_exit, true),   %% Allow calls to terminate/2
    try
        ListenOpts = [binary, {reuseaddr, true}, {ip, Ip}, {active, once}],
        Socket = case nkpacket_transport:open_port(NkPort, ListenOpts) of
            {ok, Socket0}  -> Socket0;
            {error, Error} -> throw(Error) 
        end,
        {ok, Port1} = inet:port(Socket),
        Self = self(),
        TcpPid = case Meta of
            #{udp_starts_tcp:=true} -> 
                TcpNkPort = NkPort#nkport{transp=tcp, local_port=Port1},
                case nkpacket_transport_tcp:start_link(TcpNkPort) of
                    {ok, TcpPid0} -> 
                        TcpPid0;
                    {error, TcpError} -> 
                        ?warning(Domain, 
                                 "UDP transport could not open TCP port ~p: ~p",
                                 [Port1, TcpError]),
                        throw(could_not_open_tcp)
                end;
            _ ->
                undefined
        end,
        Meta1 = case maps:is_key(idle_timeout, Meta) of
            true -> Meta;
            false -> Meta#{idle_timeout=>nkpacket_config_cache:udp_timeout(Domain)}
        end,
        RemoveOpts = [udp_starts_tcp],
        NkPort1 = NkPort#nkport{
            local_port = Port1, 
            listen_ip = Ip,
            listen_port = Port1,
            pid = self(),
            socket = Socket,
            meta = maps:without(RemoveOpts, Meta1)
        },
        nklib_proc:put(nkpacket_transports, NkPort1),
        nklib_proc:put({nkpacket_listen, Domain, Protocol}, NkPort1),
        {Protocol1, ProtoState1} = 
            nkpacket_util:init_protocol(Protocol, listen_init, NkPort1),
        UserRef = case Meta of
            #{link:=UserPid} -> erlang:monitor(process, UserPid);
            _ -> undefined
        end,
        State = #state{
            nkport = NkPort1, 
            socket = Socket,
            tcp_pid = TcpPid,
            no_connections = maps:get(udp_no_connections, Meta, false),
            reply_stun = maps:get(udp_stun_reply, Meta, false),
            stuns = [],
            timer_t1 = maps:get(udp_stun_t1, Meta, 500),
            protocol = Protocol1,
            proto_state = ProtoState1,
            user_ref = UserRef
        },
        {ok, State}
    catch
        throw:Throw ->
            ?error(Domain, "could not start UDP transport on ~p:~p (~p)", 
                   [Ip, Port, Throw]),
            {stop, Throw}
    end.


%% @private
-spec handle_call(term(), nklib_util:gen_server_from(), #state{}) ->
    nklib_util:gen_server_call(#state{}).

handle_call({connect, Ip, Port}, _From, State) ->
    {reply, do_connect(Ip, Port, State), State};

% It should not be used normally, use the nkpacket_connection version
handle_call({send, Ip, Port, Packet}, _From, #state{socket=Socket}=State) ->
    {reply, gen_udp:send(Socket, Ip, Port, Packet), State};

handle_call({send_stun, Ip, Port}, From, #state{nkport=NkPort}=State) ->
    #nkport{domain=Domain} = NkPort,
    {noreply, do_send_stun(Domain, Ip, Port, {call, From}, State)};

handle_call(get_port, _From, #state{nkport=#nkport{local_port=Port}}=State) ->
    {reply, {ok, Port}, State};

handle_call(Msg, From, State) ->
    case call_protocol(listen_handle_call, [Msg, From], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    nklib_util:gen_server_cast(#state{}).

handle_cast({send_stun, Ip, Port, Pid}, #state{nkport=NkPort}=State) ->
    #nkport{domain=Domain} = NkPort,
    {noreply, do_send_stun(Domain, Ip, Port, {cast, Pid}, State)};

handle_cast(Msg, State) ->
    case call_protocol(listen_handle_cast, [Msg], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    nklib_util:gen_server_info(#state{}).

handle_info({udp, Socket, Ip, Port, <<0:2, _Header:158, _Msg/binary>>=Packet}, State) ->
    #state{nkport=NkPort, stuns=Stuns, reply_stun=StunReply, socket=Socket} = State,
    #nkport{domain=Domain} = NkPort,
    case nkpacket_stun:decode(Packet) of
        {request, binding, TransId, _} when StunReply ->
            Response = nkpacket_stun:binding_response(TransId, Ip, Port),
            gen_udp:send(Socket, Ip, Port, Response),
            ?debug(Domain, "sent STUN bind response to ~p:~p", [Ip, Port]),
            ok = inet:setopts(Socket, [{active, once}]),
            {noreply, State};
        {response, binding, TransId, Attrs} when Stuns/=[] ->
            State1 = do_stun_response(TransId, Attrs, State),
            ok = inet:setopts(Socket, [{active, once}]),
            {noreply, State1};
        _ ->
            case read_packets(Ip, Port, Packet, State, ?RECV_BURST) of
                {ok, State1} ->
                    ok = inet:setopts(Socket, [{active, once}]),
                    {noreply, State1};
                {stop, Reason, State1} ->
                    {stop, Reason, State1}
            end
    end;

handle_info({udp, Socket, Ip, Port, Packet}, #state{socket=Socket}=State) ->
    case read_packets(Ip, Port, Packet, State, ?RECV_BURST) of
        {ok, State1} ->
            ok = inet:setopts(Socket, [{active, once}]),
            {noreply, State1};
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end;

handle_info({timeout, Ref, stun_retrans}, #state{stuns=Stuns}=State) ->
    {value, Stun1, Stuns1} = lists:keytake(Ref, #stun.retrans_timer, Stuns),
    {noreply, do_stun_retrans(Stun1, State#state{stuns=Stuns1})};
   
handle_info({'DOWN', MRef, process, _Pid, _Reason}, #state{user_ref=MRef}=State) ->
    {stop, normal, State};

handle_info({'EXIT', Pid, _Error}, #state{tcp_pid=Pid}=State) ->
    {stop, {error, tcp_error}, State};

handle_info({'EXIT', _Pid, normal}, State) ->
    %% Connection stops go here
    {noreply, State};

handle_info(killme, _State) ->
    error(killme);

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
    #state{tcp_pid = Pid} = State,
    case is_pid(Pid) of
        true ->
            exit(Pid, shutdown);
        false ->
            ok
    end,
    catch call_protocol(listen_stop, [Reason], State).



%% ========= STUN processing ================================================

%% @private
do_send_stun(Domain, Ip, Port, From, State) ->
    #state{timer_t1=T1, stuns=Stuns, socket=Socket} = State,
    {Id, Packet} = nkpacket_stun:binding_request(),
    case gen_udp:send(Socket, Ip, Port, Packet) of
        ok -> 
            ?debug(Domain, "sent STUN request to ~p", [{Ip, Port}]),
            Stun = #stun{
                id = Id,
                dest = {Ip, Port},
                packet = Packet,
                retrans_timer = erlang:start_timer(T1, self(), stun_retrans),
                next_retrans = 2*T1,
                from = From
            },
            State#state{stuns=[Stun|Stuns]};
        {error, Error} ->
            ?notice(Domain, "could not send UDP STUN request to ~p:~p: ~p", 
                         [Ip, Port, Error]),
            case From of
                {call, CallFrom} -> gen_server:reply(CallFrom, error);
                {cast, CastPid} -> gen_server:cast(CastPid, {stun, error})
            end,
            State
    end.


%% @private
do_stun_retrans(Stun, State) ->
    #stun{dest={Ip, Port}, packet=Packet, next_retrans=Next} = Stun,
    #state{nkport=NkPort, stuns=Stuns, timer_t1=T1, socket=Socket} = State,
    #nkport{domain=Domain} = NkPort,
    case Next =< (16*T1) of
        true ->
            case gen_udp:send(Socket, Ip, Port, Packet) of
                ok -> 
                    ?warning(Domain, "sent STUN refresh", []),
                    Stun1 = Stun#stun{
                        retrans_timer = erlang:start_timer(Next, self(), stun_retrans),
                        next_retrans = 2*Next
                    },
                    State#state{stuns=[Stun1|Stuns]};
                {error, Error} ->
                    ?notice(Domain, "could not send UDP STUN request to ~p:~p: ~p", 
                                 [Ip, Port, Error]),
                    do_stun_timeout(Stun, State)
            end;
        false ->
            do_stun_timeout(Stun, State)
    end.


%% @private
do_stun_timeout(Stun, State) ->
    #stun{dest={Ip, Port}, from=From} = Stun,
    #state{nkport=#nkport{domain=Domain}} = State,
    ?notice(Domain, "STUN request to ~p timeout", [{Ip, Port}]),
    case From of
        {call, CallFrom} -> gen_server:reply(CallFrom, error);
        {cast, CastPid} -> gen_server:cast(CastPid, {stun, error})
    end,
    State.
        

%% @private
do_stun_response(TransId, Attrs, State) ->
    #state{nkport=#nkport{domain=Domain}, stuns=Stuns} = State,
    case lists:keytake(TransId, #stun.id, Stuns) of
        {value, #stun{retrans_timer=Retrans, from=From}, Stuns1} ->
            nklib_util:cancel_timer(Retrans),
            case nklib_util:get_value(xor_mapped_address, Attrs) of
                {StunIp, StunPort} -> 
                    ok;
                _ ->
                    case nklib_util:get_value(mapped_address, Attrs) of
                        {StunIp, StunPort} -> ok;
                        _ -> StunIp = StunPort = undefined
                    end
            end,
            Msg = {ok, StunIp, StunPort},
            case From of
                {call, CallFrom} -> gen_server:reply(CallFrom, Msg);
                {cast, CastPid} -> gen_server:cast(CastPid, {stun, Msg})
            end,
            State#state{stuns=Stuns1};
        false ->
            ?notice(Domain, "received unexpected STUN response", []),
            State
    end.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private 
read_packets(Ip, Port, Packet, #state{no_connections=true}=State, N) ->
    #state{nkport=#nkport{domain=Domain}, socket=Socket} = State,
    case call_protocol(listen_parse, [Ip, Port, Packet], State) of
        undefined -> 
            ?warning(Domain, "Received data for uknown protocol", []),
            {ok, State};
        {ok, State1} ->
            case N>0 andalso gen_udp:recv(Socket, 0, 0) of
                {ok, {Ip1, Port1, Packet1}} -> 
                    read_packets(Ip1, Port1, Packet1, State1, N-1);
                _ ->
                    {ok, State1}
            end;
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end;

read_packets(Ip, Port, Packet, #state{socket=Socket}=State, N) ->
    case do_connect(Ip, Port, State) of
        {ok, #nkport{pid=Pid}} ->
            nkpacket_connection:incoming(Pid, Packet),
            case N>0 andalso gen_udp:recv(Socket, 0, 0) of
                {ok, {Ip1, Port1, Packet1}} -> 
                    read_packets(Ip1, Port1, Packet1, State, N-1);
                _ ->
                    {ok, State}
            end;
        {error, _} ->
            {ok, State}
    end.


%% @private
do_connect(Ip, Port, #state{nkport=NkPort}) ->
    #nkport{domain=Domain, protocol=Proto} = NkPort,
    case nkpacket_transport:get_connected(Domain, {Proto, udp, Ip, Port}) of
        [NkPort1|_] -> 
            {ok, NkPort1};
        [] ->
            case nkpacket_connection_lib:is_max(Domain) of
                false ->
                    NkPort1 = NkPort#nkport{
                        remote_ip = Ip, 
                        remote_port = Port
                    },
                    {ok, Pid} = nkpacket_connection:start(NkPort1),
                    {ok, NkPort1#nkport{pid=Pid}};
                true ->
                    {error, max_connections}
            end
    end.


%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).


