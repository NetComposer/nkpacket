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

-compile([export_all]).
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
	1024 = nkpacket_config_cache:global_max_connections(),
	30000 = nkpacket_config_cache:udp_timeout(test1),
	1024 = nkpacket_config_cache:max_connections(test1),
	nkpacket_config:put(global_max_connections, 100),
	100 = nkpacket_config_cache:global_max_connections(),

	{error, {invalid, udp_timeout}} = 
		nkpacket_config:load_domain(test1, #{udp_timeout=>0}),
	ok = nkpacket_config:load_domain(test1, #{udp_timeout=>5}),
	5 = nkpacket_config_cache:udp_timeout(test1),
	30000 = nkpacket_config_cache:udp_timeout(test2),

	undefined = nkpacket_config:get_protocol(test),
	undefined = nkpacket_config:get_protocol(dom1, test),
	ok = nkpacket_config:register_protocol(test, ?MODULE),
	?MODULE = nkpacket_config:get_protocol(test),
	?MODULE = nkpacket_config:get_protocol(dom1, test),
	ok = nkpacket_config:register_protocol(dom1, test, test_protocol),
	?MODULE = nkpacket_config:get_protocol(test),
	test_protocol = nkpacket_config:get_protocol(dom1, test),
	ok.

