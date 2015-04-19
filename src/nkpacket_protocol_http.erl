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

%% @doc Protocol behaviour

-module(nkpacket_protocol_http).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([transports/1, default_port/1]).
-export([http_init/3]).

-include("nkpacket.hrl").
-include_lib("nklib/include/nklib.hrl").


%% ===================================================================
%% Types
%% ===================================================================




%% ===================================================================
%% Common callbacks
%% ===================================================================


-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(http) -> [http];
transports(https) -> [https].


-spec default_port(nkpacket:transport()) ->
    inet:port_number().

default_port(http) -> 80;
default_port(https) -> 443;
default_port(_) -> invalid.


-spec http_init(nkpacket:nkport(), cowboy_req:req(), cowboy_middleware:env()) ->
    {ok, Req::cowboy_req:req(), Env::cowboy_middleware:env(), Middlewares::[module()]} |
    {stop, cowboy_req:req()}.

http_init(#nkport{meta=Meta}=NkPort, Req, Env) ->
	case Meta of
		#{cowboy_dispatch:=Dispatch} ->
			Env1 = [{dispatch, Dispatch}, {nkport, NkPort} | Env],
 			{ok, Req, Env1, [cowboy_router, cowboy_handler]};
 		#{cowboy_opts:=CowboyOpts} ->
 			UserEnv = nklib_util:get_value(env, CowboyOpts, []),
 			Middlewares = nklib_util:get_value(middlewares, CowboyOpts, 
 											   [cowboy_router, cowboy_handler]),
 			UserEnv1 = [{nkport, NkPort}|UserEnv], 
 			Env1 = nklib_util:store_values(UserEnv1, Env),
 			{ok, Req, Env1, Middlewares};
 		_ ->
			{stop, cowboy_req:reply(500, [{<<"server">>, <<"NkPACKET">>}], Req)}
 	end.



