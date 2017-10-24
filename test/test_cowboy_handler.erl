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

%% @doc TEST Protocol behaviour

-module(test_cowboy_handler).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([init/2, terminate/3]).

-include("nkpacket.hrl").
-include_lib("nklib/include/nklib.hrl").


init(Req, Opts) ->
	[#{user_state:={Pid, Ref}}] = Opts,
	Pid ! {Ref, http_init, self()},
    Req2 = cowboy_req:reply(200, [
        {<<"content-type">>, <<"text/plain">>}
    ], <<"Hello World!">>, Req),
    {ok, Req2, Opts}.


terminate(_Reason, _Req, [#{user_state:={Pid, Ref}}]) ->
	Pid ! {Ref, http_terminate, self()},
	ok.

