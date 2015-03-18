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

-module(test_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").
-include("nkpacket.hrl").


reset_1() ->
	ok = nkpacket_config:register_protocol(test, test_protocol),
 	ok = nkpacket:stop_all(dom1),
 	timer:sleep(100),
	Pid = self(),
	Ref = make_ref(),
	M = #{test=>{Pid, Ref}},
	{Ref, M}.


reset_2() ->
	ok = nkpacket_config:register_protocol(test, test_protocol),
 	ok = nkpacket:stop_all(dom1),
 	ok = nkpacket:stop_all(dom2),
 	timer:sleep(100),
	Pid = self(),
	Ref1 = make_ref(),
	M1 = #{test=>{Pid, Ref1}},
	Ref2 = make_ref(),
	M2 = #{test=>{Pid, Ref2}},
	{Ref1, M1, Ref2, M2}.


reset_3() ->
	ok = nkpacket_config:register_protocol(test, test_protocol),
 	ok = nkpacket:stop_all(dom1),
 	ok = nkpacket:stop_all(dom2),
 	ok = nkpacket:stop_all(dom3),
 	timer:sleep(100),
	Pid = self(),
	Ref1 = make_ref(),
	M1 = #{test=>{Pid, Ref1}},
	Ref2 = make_ref(),
	M2 = #{test=>{Pid, Ref2}},
	Ref3 = make_ref(),
	M3 = #{test=>{Pid, Ref3}},
	{Ref1, M1, Ref2, M2, Ref3, M3}.


ensure([]) -> 
	ok;

ensure([Ref|Rest]) ->
	timer:sleep(50),
	receive {Ref, V} -> error({unexpected, V}) after 0 -> ok end,
	ensure(Rest).




