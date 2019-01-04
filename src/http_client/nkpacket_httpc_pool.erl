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
-export([start_link/2]).



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
        resolve_interval_secs => 0
    },
    start_link(test, Config).


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: nkpacket_pool:id().


-type config() ::
    #{
        targets => [
            #{
                url => string()|binary(),           % Can resolve to multiple IPs
                opts => nkpacket:connect_opts(),    % Can include debug
                weight => integer(),                % Shared weight for all IPs
                pool => integer(),                  % Connections to start
                refresh => boolean(),               % Send a periodic GET / (idle_timeout)
                headers => [{binary(), binary()}]   % To include in each request
            }
        ],
        debug => boolean(),
        resolve_interval_secs => integer()               % Secs, 0 to avoid
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
-spec start_link(id(), config()) ->
    {ok, pid()} | {error, term()}.

start_link(Id, Config) ->
    Config2 = make_pool_config(Config),
    nkpacket_pool:start_link(Id, Config2).


%% @doc
-spec request(pid(), nkpacket_httpc:method(), nkpacket:path(), nkpacket:body(), request_opts()) ->
    {ok, nkpacket_httpc:status(), [nkpacket_httpc:header()], nkpacket_httpc:body()}
    | {error, term()}.

request(Pid, Method, Path, Body, Opts) ->
    case nkpacket_pool:get_conn_pid(Pid) of
        {ok, ConnPid, _Meta} ->
            Hds = maps:get(headers, Opts, []),
            nkpacket_httpc:do_request(ConnPid, Method, Path, Hds, Body, Opts);
        {error, Error} ->
            {error, Error}
    end.


%% @private
make_pool_config(Config) ->
    Targets1 = maps:get(targets, Config, []),
    Targets2 = lists:map(
        fun(Spec1) ->
            Opts1 = maps:get(opts, Spec1, #{}),
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