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

-export([sample/0, request/5]).
-export([start_link/1]).



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


%% ===================================================================
%% Types
%% ===================================================================

-type method() :: get | post | put | delete | head | patch.
-type path() :: binary().
-type body() :: iolist().

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

-type request_opts() ::
    #{
        headers => [{binary(), binary()}],
        timeout => integer()
    }.



%% ===================================================================
%% Public
%% ===================================================================


%% @doc
-spec start_link(config()) ->
    {ok, pid()} | {error, term()}.

start_link(Config) ->
    Config2 = update_config(Config),
    nkpacket_pool:start_link(Config2).


%% @doc
-spec request(pid(), method(), path(), body(), request_opts()) ->
    {ok, Status::100..599, Headers::[{binary(), binary()}], Body::binary()} |
    {error, term()}.

request(Pid, Method, Path, Body, Opts) ->
    case nkpacket_pool:get_pid(Pid) of
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


%% @private
update_config(Config) ->
    Targets1 = maps:get(targets, Config, []),
    Targets2 = lists:map(
        fun(Spec1) ->
            Opts1 = maps:get(opts, Spec1),
            UserState1 = case maps:get(refresh, Spec1, false) of
                true ->
                    #{refresh_request=>{get, <<"/">>, [], <<>>}};
                false ->
                    #{}
            end,
            UserState2 = case maps:get(headers, Spec1, []) of
                [] ->
                    UserState1;
                Headers ->
                    UserState1#{headers=>Headers}
            end,
            Opts2 = Opts1#{user_state => UserState2},
            Spec2 = maps:without([refresh, headers], Spec1),
            Spec2#{opts=>Opts2}
        end,
        Targets1),
    Config#{targets=>Targets2}.