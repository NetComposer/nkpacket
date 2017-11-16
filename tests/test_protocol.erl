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

-module(test_protocol).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
% -behaviour(nkpacket_protocol).

-export([transports/1, default_port/1]).
-export([conn_init/1, conn_parse/3, conn_encode/3, conn_stop/3]).
-export([conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).
-export([listen_init/1, listen_parse/5, listen_stop/3]).
-export([listen_handle_call/4, listen_handle_cast/3, listen_handle_info/3]).
-export([http_init/4]).

-include("nkpacket.hrl").

%% ===================================================================
%% Types
%% ===================================================================


-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(_) -> [http, https, udp, tcp, tls, sctp, ws, wss].

-spec default_port(nkpacket:transport()) ->
    inet:port_number().

default_port(udp) -> 1234;
default_port(tcp) -> 1235;
default_port(tls) -> 1236;
default_port(sctp) -> 1237;
default_port(ws) -> 1238;
default_port(wss) -> 1239;
default_port(http) -> 1240;
default_port(https) -> 1241;
default_port(_) -> invalid.



%% ===================================================================
%% Listen callbacks
%% ===================================================================


-record(listen_state, {
	pid,
	ref
}).


-spec listen_init(nkpacket:nkport()) ->
	#listen_state{}.

listen_init(NkPort) ->
	lager:info("Protocol LISTEN init: ~p (~p)", [NkPort, self()]),
	State = case nkpacket:get_user_state(NkPort) of
		{ok, {Pid, Ref}} ->
			#listen_state{pid=Pid, ref=Ref};
		_ -> 
			#listen_state{}
	end,
	maybe_reply(listen_init, State),
	{ok, State}.


listen_handle_call(Msg, _From, _NkPort, State) ->
	lager:warning("Unexpected call: ~p", [Msg]),
	{ok, State}.


listen_handle_cast(Msg, _NkPort, State) ->
	lager:warning("Unexpected cast: ~p", [Msg]),
	{ok, State}.


listen_handle_info({'EXIT', _, forced_stop}, _NkPort, State) ->
	{stop, forced_stop, State};

listen_handle_info(Msg, _NkPort, State) ->
	lager:warning("Unexpected listen info: ~p", [Msg]),
	{ok, State}.

listen_parse(Ip, Port, Data, _NkPort, State) ->
	lager:info("LISTEN Parsing fromm ~p:~p: ~p", [Ip, Port, Data]),
	maybe_reply({listen_parse, Data}, State),
	{ok, State}.

listen_stop(Reason, _NkPort, State) ->
	lager:info("LISTEN  stop: ~p, ~p", [Reason, State]),
	maybe_reply(listen_stop, State),
	ok.


%% ===================================================================
%% Conn callbacks
%% ===================================================================


-record(conn_state, {
	pid,
	ref
}).

-spec conn_init(nkpacket:nkport()) ->
	{ok, #conn_state{}}.

conn_init(NkPort) ->
	lager:info("Protocol CONN init: ~p (~p)", [NkPort, self()]),
	State = case nkpacket:get_user_state(NkPort) of
		{ok, {Pid, Ref}} -> #conn_state{pid=Pid, ref=Ref};
		_ -> #conn_state{}
	end,
	maybe_reply(conn_init, State),
	{ok, State}.


conn_parse({text, Data}, _NkPort, State) ->
	lager:debug("Parsing WS TEXT: ~p", [Data]),
	maybe_reply({parse, {text, Data}}, State),
	{ok, State};

conn_parse({binary, <<>>}, _NkPort, State) ->
	lager:error("EMPTY"),
	{ok, State};

conn_parse({binary, Data}, _NkPort, State) ->
	Msg = erlang:binary_to_term(Data),
	lager:debug("Parsing WS BIN: ~p", [Msg]),
	maybe_reply({parse, {binary, Msg}}, State),
	{ok, State};

conn_parse(close, _NkPort, State) ->
	{ok, State};

conn_parse(pong, _NkPort, State) ->
	{ok, State};

conn_parse({pong, Payload}, _NkPort, State) ->
	lager:debug("Parsing WS PONG: ~p", [Payload]),
	maybe_reply({pong, Payload}, State),
	{ok, State};

conn_parse(Data, #nkport{class=Class}, State) ->
	Msg = erlang:binary_to_term(Data),
	lager:debug("Parsing: ~p (~p)", [Msg, Class]),
	maybe_reply({parse, Msg}, State),
	{ok, State}.

conn_encode({nkraw, Msg}, NkPort, State) ->
	lager:debug("UnParsing RAW: ~p, ~p", [Msg, NkPort]),
	maybe_reply({encode, Msg}, State),
	{ok, Msg, State};

conn_encode(Msg, NkPort, State) ->
	lager:debug("UnParsing: ~p, ~p", [Msg, NkPort]),
	maybe_reply({encode, Msg}, State),
	{ok, erlang:term_to_binary(Msg), State}.

conn_handle_call(Msg, _From, _NkPort, State) ->
	lager:warning("Unexpected call: ~p", [Msg]),
	{ok, State}.


conn_handle_cast(Msg, _NkPort, State) ->
	lager:warning("Unexpected cast: ~p", [Msg]),
	{ok, State}.


conn_handle_info(Msg, _NkPort, State) ->
	lager:warning("Unexpected conn info: ~p", [Msg]),
	{ok, State}.

conn_stop(Reason, _NkPort, State) ->
	lager:info("CONN stop: ~p", [Reason]),
	maybe_reply(conn_stop, State),
	ok.



% encode(Msg, NkPort) ->
% 	lager:info("Quick UnParsing: ~p, ~p", [Msg, NkPort]),
% 	{ok, erlang:term_to_binary(Msg)}.



%% ===================================================================
%% HTTP
%% ===================================================================

http_init(Paths, Req, Env, NkPort) ->
	case nkpacket:get_class(NkPort) of
		{ok, Class} when Class==dom1; Class==dom2; Class==dom3; Class==dom4 ->
			{ok, {Pid, Ref}} = nkpacket:get_user_state(NkPort),
			Pid ! {Ref, http_init, self()},
			Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain">>}, <<"Hello World!">>, Req),
			Pid ! {Ref, http_terminate, self()},
			{ok, Req2, Env};
		{ok, dom5} when Paths==[] ->
			{redirect, "/index.html"};
		{ok, dom5} ->
			{cowboy_static, {priv_dir, nkpacket, "/www"}}
	end.







%% ===================================================================
%% Util
%% ===================================================================


maybe_reply(Msg, #listen_state{pid=Pid, ref=Ref}) when is_pid(Pid) -> Pid ! {Ref, Msg};
maybe_reply(Msg, #conn_state{pid=Pid, ref=Ref}) when is_pid(Pid) -> Pid ! {Ref, Msg};
maybe_reply(_, _) -> ok.








