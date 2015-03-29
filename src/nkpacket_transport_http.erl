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

-export([get_listener/1, get_port/1]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3, 
         handle_cast/2, handle_info/2]).
-export([parse_paths/1, check_paths/2]).
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
    #nkport{domain=Domain, local_ip=Ip, local_port=Port} = NkPort,
    {
        {Domain, Transp, Ip, Port, make_ref()},
        {?MODULE, start_link, [NkPort]},
        transient,
        5000,
        worker,
        [?MODULE]
    }.



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
    shared :: pid(),
    user_ref :: reference()
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
        {Protocol1, ProtoState1} = 
            nkpacket_util:init_protocol(Protocol, listen_init, NkPort1),
        UserRef = case Meta of
            #{link:=UserPid} -> erlang:monitor(process, UserPid);
            _ -> undefined
        end,
        State = #state{
            nkport = NkPort1,
            protocol = Protocol1,
            proto_state = ProtoState1,
            shared = SharedPid,
            user_ref = UserRef
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
        undefined -> {noreply, State};
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
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    nklib_util:gen_server_info(#state{}).

handle_info({'DOWN', MRef, process, _Pid, _Reason}, #state{user_ref=MRef}=State) ->
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

cowboy_init(#nkport{domain=Domain, meta=Meta, protocol=Protocol}=NkPort, Req, Env) ->
    {HostList, PathList} = maps:get(http_match, Meta),
    ReqHost = cowboy_req:host(Req),
    ReqPath = cowboy_req:path(Req),
    case 
        (HostList==[] orelse lists:member(ReqHost, HostList)) andalso
        (PathList==[] orelse check_paths(ReqPath, PathList))
    of
        false ->
            next;
        true ->
            {RemoteIp, RemotePort} = cowboy_req:peer(Req),
            NkPort1 = NkPort#nkport{
                remote_ip = RemoteIp,
                remote_port = RemotePort,
                socket = self(),
                meta = maps:without([http_match], Meta)
            },
            {ok, ConnPid} = nkpacket_connection:start(NkPort1),
            NkPort2 = NkPort1#nkport{pid=ConnPid},
            ?debug(Domain, "HTTP listener accepted connection: ~p", [NkPort1]),
            {ok, Req1, Env1, Middlewares1} = Protocol:http_init(NkPort2, Req, Env),
            execute(Req1, Env1, Middlewares1)
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


%% @private
-spec parse_paths([string()|binary()]) ->
    [[binary()]].

parse_paths(List) ->
    parse_paths(List, []).


%% @private
parse_paths([], Acc) ->
    Acc;

parse_paths([Spec|Rest], Acc) when is_binary(Spec) ->
    case binary:split(Spec, <<"/">>, [global]) of
        [<<>>|Parts] -> parse_paths(Rest, [Parts|Acc]);     % starting /
        Parts -> parse_paths(Rest, [Parts|Acc])
    end;

parse_paths([Spec|Rest], Acc) when is_list(Spec), is_integer(hd(Spec)) ->
    parse_paths([list_to_binary(Spec)|Rest], Acc).


%% @private
check_paths(_ReqPath, []) ->
    true;

check_paths(ReqPath, Paths) ->
    case binary:split(ReqPath, <<"/">>, [global]) of
        [<<>>, <<>>] -> check_paths1([<<>>], Paths);
        [<<>>|ReqParts] -> check_paths1(ReqParts, Paths)
    end.


%% @private
check_paths1(_, []) ->
    false;

check_paths1(Parts, [FirstPath|Rest]) ->
    case check_paths2(Parts, FirstPath) of
        true -> true;
        false -> check_paths1(Parts, Rest)
    end.


%% @private
check_paths2([Common|Rest1], [Common|Rest2]) -> 
    check_paths2(Rest1, Rest2);

check_paths2(_Parts, Paths) -> 
    Paths==[].

    

% -define(TEST, true).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").


path_test() ->
    true = test_path("/a/b/c", []),
    true = test_path("/", ["/"]),
    false = test_path("/", ["/a"]),
    true = test_path("/", ["/a", "bc", "/"]),
    true = test_path("/a/b/c", ["a"]),
    false = test_path("/a/b/c", ["d"]),
    true = test_path("/a/b/c", ["d", "a/b/c"]),
    true = test_path("/a/b/c", ["d", "/a/b"]),
    false = test_path("/a/b/c", ["d", "a/b/c/d"]),
    true = test_path("/a/b/c", ["d", "a/b/c/d", "/a/b/c"]),
    ok.


test_path(Req, Paths) ->
    Paths1 = parse_paths(Paths),
    check_paths(list_to_binary(Req), Paths1).

-endif.




% %% @private
% routes([H|_]=String, Module, Args) when is_integer(H) ->
%     routes([String], Module, Args);

% routes(Bin, Module, Args) when is_binary(Bin) ->
%     routes([Bin], Module, Args);

% routes(List, Module, Args) ->
%     lists:map(
%         fun(Spec) ->
%             case Spec of
%                 {Host, Constraints, PathsList} 
%                     when is_list(Constraints), is_list(PathsList) -> 
%                     ok;
%                 {Host, PathsList} when is_list(PathsList) -> 
%                     Constraints = [];
%                 SinglePath when is_binary(SinglePath) ->
%                     Host = '_', Constraints = [], PathsList = [SinglePath];
%                 SinglePath when is_list(SinglePath), is_integer(hd(SinglePath)) ->
%                     Host = '_', Constraints = [], PathsList = [SinglePath];
%                 PathsList when is_list(PathsList) ->
%                     Host = '_', Constraints = []
%             end,
%             Paths = lists:map(
%                 fun(PatchSpec) ->
%                     case PatchSpec of
%                         {Path, PathConstraints} 
%                             when is_list(Path), is_list(PathConstraints) ->
%                             {Path, PathConstraints, Module, Args};
%                         Path when is_binary(Path) ->
%                             {Path, [], Module, Args};
%                         Path when is_list(Path) ->
%                             {Path, [], Module, Args}
%                     end
%                 end,
%                 PathsList),
%             {Host, Constraints, Paths}
%         end,
%         List).








