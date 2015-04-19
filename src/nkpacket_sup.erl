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

%% @private NkPACKET main supervisor
-module(nkpacket_sup).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(supervisor).

-export([add_transport/1, del_transport/1, get_transports/0]).
-export([add_ranch/1, del_ranch/1]).
-export([init/1, start_link/0, start_transports_sup/0, start_ranch_sup/0]).

-include("nkpacket.hrl").


%% @private Adds a supervised transport
-spec add_transport(supervisor:child_spec()) ->
    {ok, pid()} | {error, term()}.

add_transport(Spec) ->
    case supervisor:start_child(nkpacket_transports_sup, Spec) of
        {ok, Pid} -> {ok, Pid};
        {error, {Error, _}} -> {error, Error};
        {error, Error} -> {error, Error}
    end.


%% @private Removes a supervised transport
-spec del_transport(term()) ->
    ok | {error, term()}.

del_transport(Id) ->
    case catch supervisor:terminate_child(nkpacket_transports_sup, Id) of
        ok -> supervisor:delete_child(nkpacket_transports_sup, Id);
        {error, Reason} -> {error, Reason}
    end.


%% @private Gets supervised transports
-spec get_transports() ->
    [{term(), pid()}].

get_transports() ->
    [{Id, Pid} || {Id, Pid, _, _} <- supervisor:which_children(nkpacket_transports_sup)].


%% @private
-spec add_ranch(supervisor:child_spec()) ->
    {ok, pid()} | {error, term()}.

add_ranch(Spec) ->
    case supervisor:start_child(nkpacket_ranch_sup, Spec) of
        {ok, Pid} -> {ok, Pid};
        {error, {Error, _}} -> {error, Error};
        {error, Error} -> {error, Error}
    end.


%% @private Removes a supervised ranch
-spec del_ranch(term()) ->
    ok | {error, term()}.

del_ranch(Id) ->
    case catch supervisor:terminate_child(nkpacket_ranch_sup, Id) of
        ok -> 
            supervisor:delete_child(nkpacket_ranch_sup, Id),
            ok;
        {error, Reason} -> 
            {error, Reason}
    end.


%% @private
start_link() ->
    ChildsSpec = [
        {nkpacket_config,
            {nkpacket_config, start_link, []},
            permanent,
            5000,
            worker,
            [nkpacket_config]},
        {nkpacket_dns,
            {nkpacket_dns, start_link, []},
            permanent,
            5000,
            worker,
            [nkpacket_dns]},
        {nkpacket_transports_sup,
            {?MODULE, start_transports_sup, []},
            permanent,
            infinity,
            supervisor,
            [?MODULE]},
        {nkpacket_ranch_sup,
            {?MODULE, start_ranch_sup, []},
            permanent,
            infinity,
            supervisor,
            [?MODULE]}
     ], 
    supervisor:start_link({local, ?MODULE}, ?MODULE, {{one_for_one, 10, 60}, ChildsSpec}).

%% @private
start_transports_sup() ->
    supervisor:start_link({local, nkpacket_transports_sup}, 
                          ?MODULE, {{one_for_one, 10, 60}, []}).

%% @private
start_ranch_sup() ->
    supervisor:start_link({local, nkpacket_ranch_sup}, 
                          ?MODULE, {{one_for_one, 10, 60}, []}).


%% @private
init(ChildSpecs) ->
    {ok, ChildSpecs}.




