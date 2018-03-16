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
        targets => [
%%            #{
%%                url => "https://microsoft.com",
%%                opts => #{debug => true},
%%                weight => 20
%%            },
            #{
                url => "http://127.0.0.1:9000",
                weight => 10,
                opts => #{idle_timeout=>5000, debug=>false},
                pool => 3,
                refresh => true
            }
        ],
        debug => true,
        resolve_interval => 0
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
-define(INITIAL_DELAY_SECS, 5).    % Secs
-define(MAX_DELAY_SECS, 60).    % Secs

%% ===================================================================
%% Types
%% ===================================================================

-type config() ::
    #{
        id => term(),
        targets => [
            #{
                url => binary(),                    % Can resolve to multiple IPs
                opts => nkpacket:connect_opts(),    % Can include debug
                weigth => integer(),                % Shared weight for all IPs
                pool => integer,                    % Connections to start
                refresh => boolean(),               % Send a periodic GET / (idle_timeout)
                headers => [{binary(), binary()}]   % To include in each request
            }
        ],
        debug => boolean(),
        resolve_interval => integer()               % Secs, 0 to avoid
    }.



%% ===================================================================
%% Public
%% ===================================================================


%% @doc
-spec start_link(config()) ->
    {ok, pid()} | {error, term()}.

start_link(Config) ->
   gen_server:start_link(?MODULE, [Config], []).


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
    delay = 0 :: integer(),
    next_try = 0 :: nklib_util:timestamp()
}).

-type conn_id() :: {nkpacket:transport(), inet:ip_address(), inet:port_number()}.

-record(state, {
    id :: term(),
    targets :: map(),
    conn_spec :: #{conn_id() => #conn_spec{}},
    conn_weight :: [{Start::integer(), Stop::integer(), conn_id()}],
    conn_status :: #{conn_id() => #conn_status{}},
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
        targets = maps:get(targets, Config),
        conn_spec = #{},
        conn_weight = [],
        conn_status = #{},
        conn_pids = #{},
        debug = maps:get(debug, Config, false),
        headers = maps:get(headers, Config, []),
        resolve_interval = maps:get(resolve_interval, Config, 0)
    },
    self() ! launch_resolve,
    {ok, State1}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_pid, From, State) ->
    State2 = find_conn_pid(?NUM_TRIES, From, State),
    {noreply, State2};

handle_call(get_status, _From, #state{conn_status=ConnStatus}=State) ->
    {reply, {ok, ConnStatus}, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({retry_get_pid, Tries, From}, State) when Tries > 0 ->
    ?DEBUG("retrying get pid (remaining tries:~p)", [Tries], State),
    State2 = find_conn_pid(Tries, From, State),
    {noreply, State2};

handle_cast({retry_get_pid, _Tries, From}, State) ->
    ?DEBUG("retrying get pid: too many retries", [], State),
    gen_server:reply(From, {error, no_connections}),
    {noreply, State};

 handle_cast({resolve_data, {Specs, Weights, Max}}, State) ->
    case Weights of
        [] ->
            ?LLOG(warning, "no connections spec", [], State);
        _ ->
            ?DEBUG("new resolved spec: ~p", [Specs], State),
            ?DEBUG("new resolved weights: ~p", [Weights], State),
            ok
    end,
    #state{resolve_interval=Time} = State,
    case Time > 0 of
        true ->
            erlang:send_after(Time*1000, self(), launch_resolve);
        false ->
            ok
    end,
    State2 = State#state{
        conn_spec = Specs,
        conn_weight = Weights,
        max_weight = Max
    },
    {noreply, State2};

handle_cast({new_connection_ok, ConnId, Pid, Tries, From}, State) ->
    {noreply, do_connect_ok(ConnId, Pid, Tries, From, State)};

handle_cast({new_connection_error, ConnId, Error, Tries, From}, State) ->
    {noreply, do_connect_error(ConnId, Error, Tries, From, State)};

handle_cast(Msg, State) ->
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(launch_resolve, #state{targets =ConnConfig}=State) ->
    Self = self(),
    spawn_link(fun() -> resolve(Self, ConnConfig) end),
    {noreply, State};

handle_info({'DOWN', _Ref, process, Pid, Reason}=Msg, State) ->
    #state{conn_pids=ConnPids, conn_status=ConnStatus} = State,
    case maps:take(Pid, ConnPids) of
        {ConnId, ConnPids2} ->
            ?DEBUG("connection ~p down (~p)", [ConnId, Reason], State),
            #conn_status{conn_pids=Pids}= Status1 = maps:get(ConnId, ConnStatus),
            Status2 = Status1#conn_status{conn_pids=Pids -- [Pid]},
            ConnStatus2 = ConnStatus#{ConnId => Status2},
            State2 = State#state{conn_pids=ConnPids2, conn_status=ConnStatus2},
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
resolve(Pid, ConnsConfig) ->
    Data = do_resolve(ConnsConfig, Pid, #{}, []),
    gen_server:cast(Pid, {resolve_data, Data}).


%% @private
do_resolve([], _Pid, Specs, Weights) ->
    Max = case Weights of
        [{_Start, Stop, _}|_] ->
            Stop;
        [] ->
            0
    end,
    {Specs, lists:reverse(Weights), Max};

do_resolve([#{url:=Url}=Spec|Rest], Pid, Specs, Weights) ->
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
    Specs2 = lists:foldl(
        fun(#nkconn{transp=Transp, ip=Ip, port=Port}=NkConn, Acc) ->
            ConnId = {Transp, Ip, Port},
            ConnSpec = #conn_spec{id=ConnId, nkconn=NkConn, pool=Pool},
            Acc#{ConnId => ConnSpec}
        end,
        Specs,
        ConnList),
    Weights2 = case ConnList of
        [] ->
            Weights;
        _ ->
            GroupWeight = maps:get(weight, Spec, 100),
            ConnWeight = GroupWeight div length(ConnList),
            lists:foldl(
                fun(#nkconn{transp=Transp, ip=Ip, port=Port}, Acc) ->
                    ConnId = {Transp, Ip, Port},
                    case Acc of
                        [] ->
                            [{1, ConnWeight, ConnId}];
                        [{_Start, Stop, _ConnId}|_] ->
                            [{Stop+1, Stop+ConnWeight, ConnId}|Acc]
                    end
                end,
                Weights,
                ConnList)
    end,
    do_resolve(Rest, Pid, Specs2, Weights2).


%% @private
find_conn_pid(_Tries, From, #state{conn_weight=[]}=State) ->
    gen_server:reply(From, {error, no_connections}),
    State;

find_conn_pid(Tries, From, State) ->
    #state{
        max_weight = Max,
        conn_spec = ConnSpec,
        conn_weight = Weights,
        conn_status = ConnStatus
    } = State,
    Pos = rand:uniform(Max),
    ConnId = do_find_conn(Pos, Weights),
    Spec = maps:get(ConnId, ConnSpec),
    #conn_spec{id=ConnId, pool=Pool} = Spec,
    ?DEBUG("selected weight ~p: ~p", [Pos, ConnId], State),
    case maps:find(ConnId, ConnStatus) of
        {ok, #conn_status{status=active, conn_pids=Pids}} ->
            case length(Pids) < Pool of
                true ->
                    connect(Spec, Tries, From, State);
                false ->
                    ?DEBUG("selecting existing pid ~p: ~p", [Pos, ConnId], State),
                    gen_server:reply(From, {ok, do_get_pid(Pids)}),
                    State
            end;
        _ ->
            % If inactive or not yet created
            connect(Spec, Tries, From, State)
    end.


%% @private
connect(#conn_spec{id=ConnId, nkconn=Conn}, Tries, From, State) ->
    #state{conn_status=ConnStatus} = State,
    Status = maps:get(ConnId, ConnStatus, #conn_status{}),
    case Status of
        #conn_status{status=active} ->
            ?DEBUG("connecting to active: ~p (tries:~p)", [ConnId, Tries], State),
            spawn_connect(ConnId, Conn, Tries, From);
        #conn_status{status=inactive, next_try=Next} ->
            case nklib_util:timestamp() > Next of
                true ->
                    ?DEBUG("reconnecting to inactive: ~p", [ConnId], State),
                    spawn_connect(ConnId, Conn, Tries, From);
                false ->
                    ?DEBUG("not yet time to recconnect to: ~p", [ConnId], State),
                    retry(Tries, From)
            end
    end,
    ConnStatus2 = ConnStatus#{ConnId => Status},
    State#state{conn_status=ConnStatus2}.


%% @private
spawn_connect(ConnId, Conn, Tries, From) ->
    Self = self(),
    spawn_link(
        fun() ->
            Msg = case nkpacket_transport:connect([Conn]) of
                {ok, Pid} ->
                    {new_connection_ok, ConnId, Pid, Tries, From};
                {error, Error} ->
                    {new_connection_error, ConnId, Error, Tries, From}
            end,
            gen_server:cast(Self, Msg)
        end).


%% @private
do_connect_ok(ConnId, Pid, Tries, From, State) ->
    #state{
        conn_spec = ConnSpec,
        conn_status = ConnStatus,
        conn_pids = ConnPids
    } = State,
    case maps:find(ConnId, ConnSpec) of
        {ok, #conn_spec{pool=Pool}} ->
            Status1 = maps:get(ConnId, ConnStatus),
            #conn_status{conn_pids=Pids} = Status1,
            case length(Pids) >= Pool of
                true ->
                    % We started too much
                    ?DEBUG("selecting existing pid: ~p", [ConnId], State),
                    gen_server:reply(From, {ok, do_get_pid(Pids)}),
                    nkpacket_connection:stop(Pid),
                    State;
                false ->
                    ?DEBUG("connected to ~p (~p) (~p/~p pids started)",
                        [ConnId, Pid, length(Pids)+1, Pool], State),
                    gen_server:reply(From, {ok, Pid}),
                    monitor(process, Pid),
                    Status2 = Status1#conn_status{
                        status = active,
                        conn_pids = [Pid|Pids],
                        errors = 0,
                        delay = 0
                    },
                    State#state{
                        conn_status = ConnStatus#{ConnId => Status2},
                        conn_pids = ConnPids#{Pid => ConnId}
                    }
            end;
        error ->
            % It could have disappeared in new resolve
            retry(Tries, From),
            State
    end.


%% @private
do_connect_error(ConnId, Error, Tries, From, State) ->
    #state{conn_status = ConnStatus} = State,
    Status1 = maps:get(ConnId, ConnStatus),
    #conn_status{errors=Errors, delay=Delay} = Status1,
    Delay2 = case Delay of
        0 -> ?INITIAL_DELAY_SECS;
        _ -> min(2*Delay, ?MAX_DELAY_SECS)
    end,
    Status2 = Status1#conn_status{
        status = inactive,
        errors = Errors + 1,
        delay = Delay2,
        next_try = nklib_util:timestamp() + Delay2
    },
    ?LLOG(notice, "error connecting to ~p: ~p (~p errors, next try in ~p)",
          [ConnId, Error, Errors+1, Delay2], State),
    retry(Tries, From),
    State#state{conn_status = ConnStatus#{ConnId => Status2}}.


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
retry(Tries, From) ->
    gen_server:cast(self(), {retry_get_pid, Tries-1, From}).
