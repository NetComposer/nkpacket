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

%% @private HTTP pseudo-transport
-module(nkpacket_transport_http).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_listener/1, connect/1]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3, 
         handle_cast/2, handle_info/2]).
-export([cowboy_init/5]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


%% ===================================================================
%% Private
%% ===================================================================


%% @private Starts a new listening server
-spec get_listener(nkpacket:nkport()) ->
    supervisor:child_spec().

get_listener(#nkport{id=Id, listen_ip=Ip, listen_port=Port, transp=Transp}=NkPort)
        when Transp==http; Transp==https ->
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
            TranspMod:setopts(Socket, [{active, once}]),
            {ok, {LocalIp, LocalPort}} = TranspMod:sockname(Socket),
            Opts2 = maps:merge(#{path => <<"/">>}, Opts),
            NkPort2 = NkPort#nkport{
                local_ip = LocalIp,
                local_port = LocalPort,
                socket = Socket,
                opts = Opts2
            },
            {ok, NkPort2};
        {error, Error} ->
            {error, Error}
    end.



%% To get debug info, start with debug=>true

-define(DEBUG(Txt, Args),
    case get(nkpacket_debug) of
        true -> ?LLOG(debug, Txt, Args);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args), lager:Type("NkPACKET HTTP "++Txt, Args)).


%% ===================================================================
%% gen_server
%% ===================================================================

-record(state, {
    nkport :: nkpacket:nkport(),
    protocol :: nkpacket:protocol(),
    proto_state :: term(),
    shared :: pid(),
    monitor_ref :: reference()
    %http_proto :: nkpacket:http_proto()
}).


%% @private
start_link(NkPort) ->
    gen_server:start_link(?MODULE, [NkPort], []).
    

%% @private Starts transport process
-spec init(term()) ->
    {ok, #state{}} | {stop, term()}.

init([NkPort]) ->
    #nkport{
        class = Class,
        protocol = Protocol,
        transp = Transp,
        listen_ip = Ip,
        listen_port = Port,
        opts = Meta
    } = NkPort,
    process_flag(trap_exit, true),   %% Allow calls to terminate
    Debug = maps:get(debug, Meta, false),
    put(nkpacket_debug, Debug),
    try
        NkPort1 = NkPort#nkport{
            % listen_ip = Ip,
            % listen_port = Port,
            pid = self()
        },
        Filter = #cowboy_filter{
            pid = self(),
            module = ?MODULE,
            transp = Transp,
            host = maps:get(host, Meta, any),
            paths = nkpacket_util:norm_path(maps:get(path, Meta, any)),
            meta = maps:with([get_headers], Meta)
        },
        SharedPid = case nkpacket_cowboy:start(NkPort1, Filter) of
            {ok, SharedPid0} -> SharedPid0;
            {error, Error} -> throw(Error)
        end,
        erlang:monitor(process, SharedPid),
        case Port of
            0 -> 
                {ok, {_, _, _, Port1}} = nkpacket:get_local(SharedPid);
            _ -> 
                Port1 = Port
        end,
        ConnMeta = maps:with(?CONN_LISTEN_OPTS, Meta),
        ConnPort = NkPort1#nkport{
            local_ip   = Ip,
            local_port = Port1,
            listen_port= Port1,
            socket     = SharedPid,
            opts       = ConnMeta
        },
        nkpacket_util:register_listener(NkPort),
        % We don't yet support HTTP outgoing connections, but for the future...
        ListenType = case size(Ip) of
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
        State = #state{
            nkport = ConnPort,
            protocol = Protocol,
            proto_state = ProtoState,
            shared = SharedPid,
            monitor_ref = MonRef
            %http_proto = maps:get(http_proto, Meta, #{})
        },
        {ok, State}
    catch
        throw:TError -> 
            ?LLOG(error, "could not start ~p transport on ~p:~p (~p)", 
                   [Transp, Ip, Port, TError]),
        {stop, TError}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}} |
    {stop, term(), #state{}} | {stop, term(), term(), #state{}}.

handle_call({nkpacket_apply_nkport, Fun}, _From, #state{nkport=NkPort}=State) ->
    {reply, Fun(NkPort), State};

handle_call({nkpacket_start, Ip, Port, Pid}, _From, State) ->
    #state{nkport=NkPort} = State,
    #nkport{protocol=Protocol, opts=Opts} = NkPort,
    NkPort1 = NkPort#nkport{
        remote_ip  = Ip,
        remote_port= Port,
        socket     = Pid,
        opts       = maps:without([host, path], Opts)
    },
    % See comment on nkpacket_transport_ws for removal of host and path
    case erlang:function_exported(Protocol, http_init, 4) of
        true ->
            % Connection will monitor listen process (using 'pid')
            % and the cowboy process (using 'socket')
            % TODO Should the connection call the http_init of the protocol?
            case nkpacket_connection:start(NkPort1) of
                {ok, ConnPid} ->
                    NkPort2 = NkPort1#nkport{pid=ConnPid, opts=Opts},
                    ?DEBUG("listener accepted connection: ~p", [NkPort2]),
                    {reply, {ok, NkPort2}, State};
                {error, Error} ->
                    ?DEBUG("listener did not accepted connection:"
                            " ~p", [Error]),
                    {reply, next, State}
            end;
        false ->
            ?LLOG(warning, "protocol ~p is missing", [Protocol]),
            {reply, next, State}
    end;

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
-spec cowboy_init(pid(), cowboy_req:req(), [binary()],
                  nkpacket_cowboy:user_meta(), map()) ->
    term().

cowboy_init(Pid, Req, PathList, _FilterMeta, Env) ->
    {Ip, Port} = cowboy_req:peer(Req),
    Fun = fun() ->
        case gen_server:call(Pid, {nkpacket_start, Ip, Port, self()}, infinity) of
            {ok, #nkport{protocol=Protocol}=NkPort} ->
                case Protocol:http_init(PathList, Req, Env, NkPort) of
                    {redirect, Path} ->
                        Uri = list_to_binary(cowboy_req:uri(Req)),
                        Url = nkpacket_util:join_path(Uri, Path),
                        ?DEBUG("HTTP redirected to ~s", [Url]),
                        Req2 = cowboy_req:set_resp_header(<<"location">>, Url, Req),
                        {ok, nkpacket_cowboy:reply(301, #{}, <<>>, Req2), Env};
                    {cowboy_static, Opts} ->
                        % Emulate cowboy_router additions, expected by cowboy_static
                        Req2 = Req#{
                            path_info => PathList,
                            host_info => undefined,
                            bindings => #{}
                        },
                        {cowboy_rest, Req2, CowState} = cowboy_static:init(Req2, Opts),
                        cowboy_rest:upgrade(Req2, Env, cowboy_static, CowState);
                    {cowboy_rest, Module, State} ->
                        % Emulate cowboy_router additions, expected by cowboy_static
                        Req2 = Req#{
                            path_info => PathList,
                            host_info => undefined,
                            bindings => #{}
                        },
                        cowboy_rest:upgrade(Req2, Env, Module, State);
                    {ok, Req2, Env2} ->
                        {ok, Req2, Env2};
                    {stop, Req1} ->
                        {ok, Req1, Env}
                end;
            next ->
                next;
            {'EXIT', _} ->
                next
        end
    end,
    case nklib_util:do_try(Fun) of
        {exception, {Class, {Error, Trace}}} ->
            lager:warning("NkPACKET HTTP EXPCEPTION ~p", [{Class, {Error, Trace}}]),
            erlang:raise(Class, Error, Trace);
        Other ->
            Other
    end.


%% ===================================================================
%% Util
%% ===================================================================

%% @private Gets socket options for outbound connections
-spec connect_outbound(#nkport{}) ->
    {ok, inet|ssl, inet:socket()} | {error, term()}.

connect_outbound(#nkport{remote_ip=Ip, remote_port=Port, opts=Opts, transp=http}) ->
    SocketOpts = outbound_opts(),
    ConnTimeout = case maps:get(connect_timeout, Opts, undefined) of
        undefined ->
            nkpacket_config:connect_timeout();
        Timeout0 ->
            Timeout0
    end,
    ?DEBUG("connecting to http:~p:~p (~p)", [Ip, Port, SocketOpts]),
    case gen_tcp:connect(Ip, Port, SocketOpts, ConnTimeout) of
        {ok, Socket} ->
            {ok, inet, Socket};
        {error, Error} ->
            {error, Error}
    end;

connect_outbound(#nkport{remote_ip=Ip, remote_port=Port, opts=Opts, transp=https}) ->
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
    ?DEBUG("connecting to https:~p:~p (~p)", [Host, Port, SocketOpts]),
    case ssl:connect(Host, Port, SocketOpts, ConnTimeout) of
        {ok, Socket} ->
            {ok, ssl, Socket};
        {error, Error} ->
            {error, Error}
    end.

%% @private
outbound_opts() ->
    [
        binary,
        {active, false},
        {nodelay, true},
        {keepalive, true},
        {packet, raw}
    ].


%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).


