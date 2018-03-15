%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc HTTP Client Pool server
%% It resolves periodically the destinations and assign weights
%% When a pid is request, one destination is selected randomly based on weight
%% We see if we are already at full pool capacity for that destination,
%% in that case one of the connections is selected randomly. If not,
%% a new connection is started
%% If we cannot connect to a destination, is marked as failed and retried later


-module(nkpacket_httpc_pool).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([sample/0, request/5]).
-export([start_link/1, get_pid/1, get_status/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-include("nkpacket.hrl").


sample() ->
    Config = #{
        conns => [
            #{
                url => "http://127.0.0.1:9000",
                weight => 10,
                opts => #{idle_timeout=>5000, debug=>false},
                pool => 3,
                refresh => true
            }
%%            #{
%%                url => "http://microsoft.com",
%%                opts => #{debug => true},
%%                weight => 20
%%            }
        ],
        debug => true,
        resolve_interval => 5
    },
    start_link(Config).



-define(DEBUG(Txt, Args, State),
    case State#state.debug of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkPACKET HTTP Pool (~s) "++Txt, [State#state.id|Args])).

-define(NUM_TRIES, 2).
-define(MAX_RETRY_TIME, 60).    % Secs

%% ===================================================================
%% Types
%% ===================================================================

-type config() ::
    #{
        id => term(),
        conns => [
            #{
                url => binary(),                    % Can resolve to multiple IPs
                opts => nkpacket:connect_opts(),    % Can include debug
                weigth => integer(),                % Shared weight for all IPs
                pool => integer,                    % Connections to start
                refresh => boolean(),               % Send a periodic GET / (idle_timeout)
                headers => [{binary(), binary()}]   % To include in each request
            }
        ],
        resolve_interval => integer()               % Secs, 0 to avoid
    }.



%% ===================================================================
%% Public
%% ===================================================================


syntax() ->
    #{
        id => binary,
        conns => {list,
            #{
                url => binary,
                opts => nkpacket_syntax:safe_syntax(),
                weight => {integer, 0, 1000},
                pool => {integer, 1, 1000},
                refresh => boolean,
                headers => list,
                '__mandatory' => [url],
                '__defaults' => #{weigth=>100, pool=>1}
            }},
        debug => boolean,
        resolve_interval => {integer, 0, none}
    }.


%% @doc
-spec start_link(config()) ->
    {ok, pid()} | {error, term()}.

start_link(Config) ->
    Syntax = syntax(),
    case nklib_syntax:parse(Config, Syntax) of
        {ok, Parsed, _} ->
           gen_server:start_link(?MODULE, [Parsed], []);
        {error, Error} ->
            {error, Error}
    end.


%% @doc
request(Pid, Method, Path, Body, Opts) ->
    case get_pid(Pid) of
        {ok, ConnPid} ->
            Ref = make_ref(),
            Hds = maps:get(headers, Opts, []),
            Timeout = maps:get(timeout, Opts, 5000),
            case nkpacket:send(ConnPid, {http, Ref, self(), Method, Path, Hds, Body}) of
                {ok, ConnPid} ->
                    receive
                        {nkpacket_httpc_protocol, Ref, {head, Status, Headers}} ->
                            request_body(Ref, Opts, Timeout, Status, Headers, [])
                    after
                        Timeout ->
                            {error, timeout}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
request_body(Ref, Opts, Timeout, Status, Headers, Chunks) ->
    receive
        {nkpacket_httpc_protocol, Ref, {chunk, Data}} ->
            request_body(Ref, Opts, Timeout, Status, Headers, [Data|Chunks]);
        {nkpacket_httpc_protocol, Ref, {body, Body}} ->
            case Chunks of
                [] ->
                    {ok, Status, Headers, Body};
                _ when Body == <<>> ->
                    {ok, Status, Headers, list_to_binary(lists:reverse(Chunks))};
                _ ->
                    {error, invalid_chunked}
            end
        after Timeout ->
            {error, timeout}
    end.


get_pid(P) ->
    gen_server:call(P, get_pid).


get_status(P) ->
    gen_server:call(P, get_status).


% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(conn_spec, {
    id :: conn_id(),
    nkconn :: #nkconn{},
    pool :: integer()
}).

-record(conn_status, {
    conn_pids = [] :: [pid()],
    status = active :: active | inactive,
    errors = 0 :: integer(),
    next_try = 0 :: nklib_util:timestamp()
}).

-type conn_id() :: {inet:ip_address(), inet:port_number()}.

-record(state, {
    id :: term(),
    conns_spec :: map(),
    conns_select :: [{Start::integer(), Stop::integer(), #conn_spec{}}],
    conns_status :: #{conn_id() => #conn_status{}},
    conn_pids :: #{pid() => conn_id()},
    max_weight :: integer(),
    resolve_interval :: integer(),
    debug :: boolean(),
    headers :: [{binary(), binary()}]
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([Config]) ->
    State1 = #state{
        id = maps:get(id, Config, <<"none">>),
        conns_spec = maps:get(conns, Config),
        debug = maps:get(debug, Config, false),
        headers = maps:get(headers, Config, []),
        conns_select = [],
        conns_status = #{},
        conn_pids = #{},
        resolve_interval = maps:get(resolve_interval, Config, 0)
    },
    self() ! launch_resolve,
    {ok, State1}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_pid, _From, State) ->
    case find_conn(State) of
        {ok, Pid, State2} ->
            {reply, {ok, Pid}, State2};
        {error, Error, State2} ->
            {reply, {error, Error}, State2}
    end;

handle_call(get_status, _From, #state{conns_status=ConnStatus}=State) ->
    {reply, {ok, ConnStatus}, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({resolve_data, {Select, Max}}, #state{resolve_interval=Time}=State) ->
    case Select of
        [] ->
            ?LLOG(warning, "no connections spec", [], State);
        _ ->
            %?DEBUG("new resolved data: ~p", [Select], State),
            ok
    end,
    case Time > 0 of
        true ->
            erlang:send_after(Time*1000, self(), launch_resolve);
        false ->
            ok
    end,
    State2 = State#state{conns_select=Select, max_weight=Max},
    {noreply, State2};

handle_cast(Msg, State) ->
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(launch_resolve, #state{conns_spec=Spec}=State) ->
    Self = self(),
    spawn_link(fun() -> resolve(Self, Spec) end),
    {noreply, State};

handle_info({'DOWN', _Ref, process, Pid, Reason}=Msg, State) ->
    #state{conn_pids=ConnPids, conns_status=ConnStatus} = State,
    case maps:take(Pid, ConnPids) of
        {ConnId, ConnPids2} ->
            ?DEBUG("connection ~p down (~p)", [ConnId, Reason], State),
            #conn_status{conn_pids=Pids}=Status1 = maps:get(ConnId, ConnStatus),
            Status2 = Status1#conn_status{conn_pids=Pids -- [Pid]},
            ConnStatus2 = ConnStatus#{ConnId => Status2},
            State2 = State#state{conn_pids=ConnPids2, conns_status=ConnStatus2},
            {noreply, State2};
        error ->
            lager:warning("Module ~p received unexpected info: ~p (~p)", [?MODULE, Msg, State]),
            {noreply, State}
    end;

handle_info(Info, State) ->
    lager:warning("Module ~p received unexpected info: ~p (~p)", [?MODULE, Info, State]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, _State) ->
    ok.



% ===================================================================
%% Internal
%% ===================================================================



%% @private
resolve(Pid, Specs) ->
    Data = do_resolve(Specs, Pid, []),
    gen_server:cast(Pid, {resolve_data, Data}).


%% @private
do_resolve([], _Pid, Weights) ->
    Max = case Weights of
        [{_Start, Stop, _}|_] ->
            Stop;
        [] ->
            0
    end,
    {lists:reverse(Weights), Max};

do_resolve([#{url:=Url}=Spec|Rest], Pid, Weights) ->
    Opts = maps:get(opts, Spec, #{}),
    Pool = maps:get(pool, Spec, 1),
    UserState1 = case maps:get(refresh, Spec, false) of
        true ->
            #{refresh_request=>{get, <<"/">>, [], <<>>}};
        false ->
            #{}
    end,
    UserState2 = case maps:get(headers, Spec, []) of
        [] ->
            UserState1;
        Headers ->
            UserState1#{headers=>Headers}
    end,
    Opts2 = Opts#{
        user_state => UserState2,
        monitor => Pid
    },
    ConnList = case nkpacket_resolve:resolve(Url, Opts2) of
        {ok, ConnList0} ->
            ConnList0;
        {error, Error} ->
            lager:error("NKLOG Error resolving ~s: ~p", [Url, Error]),
            []
    end,
    Weights2 = case ConnList of
        [] ->
            Weights;
        _ ->
            GroupWeight = maps:get(weight, Spec, 100),
            ConnWeight = GroupWeight div length(ConnList),
            lists:foldl(
                fun(#nkconn{ip=Ip, port=Port}=NkConn, Acc) ->
                    ConnSpec = #conn_spec{id={Ip, Port}, nkconn=NkConn, pool=Pool},
                    case Acc of
                        [] ->
                            [{1, ConnWeight, ConnSpec}];
                        [{_Start, Stop, _ConnSpec}|_] ->
                            [{Stop+1, Stop+ConnWeight, ConnSpec}|Acc]
                    end
                end,
                Weights,
                ConnList)
    end,
    do_resolve(Rest, Pid, Weights2).


%% @private
find_conn(#state{conns_select=[]}=State) ->
    {error, no_connections, State};

find_conn(State) ->
    find_conn(?NUM_TRIES, State).


%% @private
find_conn(Tries, State) when Tries > 0 ->
    #state{
        max_weight = Max,
        conns_select = Select,
        conns_status = ConnsStatus
    } = State,
    Pos = rand:uniform(Max),
    #conn_spec{id=ConnId, pool=Pool} = ConnSpec = do_find_conn(Pos, Select),
    ?DEBUG("selected ~p: ~p", [Pos, ConnId], State),
    case maps:find(ConnId, ConnsStatus) of
        {ok, #conn_status{status=active, conn_pids=Pids}} ->
            case length(Pids) < Pool of
                true ->
                    case connect(ConnSpec, State) of
                        {ok, Pid, State2} ->
                            {ok, Pid, State2};
                        {error, State2} ->
                            ?DEBUG("retrying (remaining ~p)", [Tries], State2),
                            find_conn(Tries-1, State2)
                    end;
                false ->
                    ?DEBUG("selecting existing pid ~p: ~p", [Pos, ConnId], State),
                    {ok, do_get_pid(Pids), State}
            end;
        _ ->
            case connect(ConnSpec, State) of
                {ok, Pid, State2} ->
                    {ok, Pid, State2};
                {error, State2} ->
                    ?DEBUG("retrying (remaining ~p)", [Tries], State2),
                    find_conn(Tries-1, State2)
            end
    end;

find_conn(_Tries, State) ->
    ?DEBUG("too many tries", [], State),
    {error, no_connections, State}.


%% @private
do_find_conn(Pos, [{Min, Max, ConnSpec}|_]) when Pos >= Min, Pos =< Max ->
    ConnSpec;

do_find_conn(Pos, [_|Rest]) ->
    do_find_conn(Pos, Rest).


%% @private
do_get_pid([Pid]) ->
    Pid;
do_get_pid(Pids) ->
    lists:nth(rand:uniform(length(Pids)), Pids).


%% @private
connect(#conn_spec{id=ConnId}=ConnSpec, State) ->
    #state{conns_status=ConnStatus} = State,
    Status = maps:get(ConnId, ConnStatus, #conn_status{}),
    case Status of
        #conn_status{status=active} ->
            ?DEBUG("connecting to active: ~p", [ConnId], State),
            do_connect(ConnSpec, Status, State);
        #conn_status{status=inactive, next_try=Next} ->
            case nklib_util:timestamp() > Next of
                true ->
                    ?DEBUG("starting next try for ~p", [ConnId], State),
                    do_connect(ConnSpec, Status, State);
                false ->
                    ?DEBUG("not yet next try for ~p", [ConnId], State),
                    {error, State}
            end
    end.


%% @private
do_connect(#conn_spec{id=ConnId, nkconn=Conn, pool=Pool}, Status, State) ->
    #state{conns_status=ConnStatus, conn_pids=ConnPids} = State,
    case nkpacket_transport:connect([Conn]) of
        {ok, Pid} ->
            monitor(process, Pid),
            #conn_status{conn_pids=Pids} = Status,
            Status2 = Status#conn_status{
                status = active,
                conn_pids = [Pid|Pids],
                errors = 0
            },
            ?DEBUG("connected to ~p (~p) (~p/~p pids started)",
                   [ConnId, Pid, length(Pids)+1, Pool], State),
            State2 = State#state{
                conns_status = ConnStatus#{ConnId => Status2},
                conn_pids = ConnPids#{Pid => ConnId}
            },
            {ok, Pid, State2};
        {error, Error} ->
            Now = nklib_util:timestamp(),
            #conn_status{errors=Errors} = Status,
            Delay = min((Errors+1)*5, ?MAX_RETRY_TIME),
            Status2 = Status#conn_status{
                status = inactive,
                errors = Errors+1,
                next_try = Now + Delay
            },
            ?LLOG(notice, "error connecting to ~p: ~p (~p errors, next try in ~p)",
                  [ConnId, Error,Errors+1,Delay], State),
            State2 = State#state{
                conns_status = ConnStatus#{ConnId => Status2}
            },
            {error, State2}
    end.



