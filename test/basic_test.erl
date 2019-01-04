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

-module(basic_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all, nowarn_export_all]).
-include_lib("eunit/include/eunit.hrl").
-include("nkpacket.hrl").

basic_test_() ->
  	{setup, spawn, 
    	fun() -> 
    		application:stop(nkpacket),
    		ok = nkpacket_app:start(),
    		?debugMsg("Starting BASIC test")
		end,
		fun(_) -> 
			ok 
		end,
	    fun(_) ->
		    [
				fun() -> config() end
			]
		end
  	}.


config() ->
	1024 = nkpacket_config:max_connections(),
	30000 = nkpacket_config:udp_timeout(),
	nkpacket_app:put(max_connections, 100),
	nkpacket_config:set_config(),
	100 = nkpacket_config:max_connections(),

	nklib_config:del(nkpacket, {protocol, scheme}),
	nklib_config:del_domain(nkpacket, srv1, {protocol, scheme}),

	undefined = nkpacket:get_protocol(scheme),
	undefined = nkpacket:get_protocol(srv1, scheme),
	ok = nkpacket:register_protocol(scheme, ?MODULE),
	?MODULE = nkpacket:get_protocol(scheme),
	?MODULE = nkpacket:get_protocol(srv1, scheme),
	ok = nkpacket:register_protocol(srv1, scheme, test_protocol),
	?MODULE = nkpacket:get_protocol(scheme),
	test_protocol = nkpacket:get_protocol(srv1, scheme),
	ok.

