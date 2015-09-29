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

%% @private HTTP pseudo-transport
-module(nkpacket_transport_http).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_listener/1]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3, 
         handle_cast/2, handle_info/2]).
-export([cowboy_init/3, resume/5]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


%% ===================================================================
%% Private
%% ===================================================================


%% @private Starts a new listening server
-spec get_listener(nkpacket:nkport()) ->
    supervisor:child_spec().

get_listener(#nkport{transp=Transp}=NkPort) when Transp==http; Transp==https ->
    #nkport{local_ip=Ip, local_port=Port} = NkPort,
    {
        {Transp, Ip, Port, make_ref()},
        {?MODULE, start_link, [NkPort]},
        transient,
        5000,
        worker,
        [?MODULE]
    }.


%% ===================================================================
%% gen_server
%% ===================================================================

-record(state, {
    nkport :: nkpacket:nkport(),
    protocol :: nkpacket:protocol(),
    proto_state :: term(),
    shared :: pid(),
    monitor_ref :: reference(),
    http_proto :: nkpacket:http_proto()
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
        Filter1 = maps:with([host, path], Meta),
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
            meta = ConnMeta
        },   
        % We don't yet support HTTP outgoing connections, but for the future...
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
            monitor_ref = MonRef,
            http_proto = maps:get(http_proto, Meta)
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
    #state{nkport=NkPort, http_proto=HttpProto} = State,
    #nkport{protocol=Protocol, meta=Meta} = NkPort,
    NkPort1 = NkPort#nkport{
        remote_ip = Ip,
        remote_port = Port,
        socket = Pid,
        meta = Meta#{path=>Path}
    },
    case erlang:function_exported(Protocol, http_init, 4) of
        true ->
            % Connection will monitor listen process (unsing 'pid' and 
            % the cowboy process (using 'socket')
            case nkpacket_connection:start(NkPort1) of
                {ok, #nkport{pid=ConnPid}=NkPort2} ->
                    lager:debug("HTTP listener accepted connection: ~p", 
                          [NkPort2]),
                    {reply, {ok, Protocol, HttpProto, ConnPid}, State};
                {error, Error} ->
                    lager:notice("HTTP listener did not accepted connection:"
                            " ~p", [Error]),
                    {reply, next, State}
            end;
        false ->
            lager:notice("HTTP protocol ~p missing", [Protocol]),
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
        {ok, Protocol, HttpProto, ConnPid} ->
            case Protocol:http_init(HttpProto, ConnPid, Req, Env) of
                {ok, Req1, Env1, Middlewares1} ->
                    execute(Req1, Env1, Middlewares1);
                {stop, Req1} ->
                    {ok, Req1, Env}
            end;
        next ->
            next;
        {'EXIT', _} ->
            next
    end.


%% @private
execute(Req, Env, []) ->
    {ok, Req, Env};

execute(Req, Env, [Module|Rest]) ->
    case Module:execute(Req, Env) of
        {ok, Req1, Env1} ->
            execute(Req1, Env1, Rest);
        {suspend, Module, Function, Args} ->
            erlang:hibernate(?MODULE, resume,
                             [Env, Rest, Module, Function, Args]);
        {stop, Req1} ->
            {ok, Req1, Env}
    end.


%% @private
resume(Env, Rest, Module, Function, Args) ->
    case apply(Module, Function, Args) of
        {ok, Req1, Env1} ->
            execute(Req1, Env1, Rest);
        {suspend, Module1, Function1, Args1} ->
            erlang:hibernate(?MODULE, resume,
                             [Env, Rest, Module1, Function1, Args1]);
        {stop, Req1} ->
            {ok, Req1, Env}
    end.



%% ===================================================================
%% Util
%% ===================================================================


%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).


