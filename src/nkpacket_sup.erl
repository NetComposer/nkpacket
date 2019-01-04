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

%% @private NkPACKET main supervisor
-module(nkpacket_sup).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(supervisor).

-export([add_listener/2, del_listener/1, get_listeners/0]).
-export([init/1, start_link/0, start_listen_sup/0]).

-include("nkpacket.hrl").


%% @private Adds a supervised listener
-spec add_listener(nkpacket:id(), supervisor:child_spec()) ->
    {ok, pid()} | {error, term()}.

add_listener(Id, Spec) ->
    case supervisor:start_child(nkpacket_listen_sup, Spec) of
        {ok, Pid} -> 
            {ok, Id, Pid};
        {error, already_present} ->
            ok = supervisor:delete_child(nkpacket_listen_sup, Id),
            add_listener(Id, Spec);
        {error, {Error, _}} -> 
            {error, Error};
        {error, Error} -> 
            {error, Error}
    end.


%% @private Removes a supervised listener
-spec del_listener(term()) ->
    ok | {error, term()}.

del_listener(Id) ->
    case catch supervisor:terminate_child(nkpacket_listen_sup, Id) of
        ok ->
            supervisor:delete_child(nkpacket_listen_sup, Id);
        {error, Reason} ->
            {error, Reason}
    end.


%% @private Gets supervised listeners
-spec get_listeners() ->
    [{term(), pid()}].

get_listeners() ->
    [{Id, Pid} || {Id, Pid, _, _} <- supervisor:which_children(nkpacket_listen_sup)].


%% @private
start_link() ->
    ChildsSpec = [
        {nkpacket_dns,
            {nkpacket_dns, start_link, []},
            permanent,
            5000,
            worker,
            [nkpacket_dns]},
        {nkpacket_listen_sup,
            {?MODULE, start_listen_sup, []},
            permanent,
            infinity,
            supervisor,
            [?MODULE]}
     ], 
    supervisor:start_link({local, ?MODULE}, ?MODULE, {{one_for_one, 10, 60}, ChildsSpec}).

%% @private
start_listen_sup() ->
    supervisor:start_link({local, nkpacket_listen_sup}, 
                          ?MODULE, {{one_for_one, 10, 60}, []}).


%% @private
init(ChildSpecs) ->
    {ok, ChildSpecs}.




