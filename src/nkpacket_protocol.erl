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
%% This module shows the behaviour that NkPACKET protocols must follow
%% All functions are optional. The implementation in this module shows the
%% default behaviour

-module(nkpacket_protocol).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([transports/1, default_port/1, unparse/2]).
-export([conn_init/1, conn_parse/2, conn_unparse/2, conn_handle_call/3,
		 conn_handle_cast/2, conn_handle_info/2, conn_stop/2]).
-export([listen_init/1, listen_parse/4, listen_handle_call/3,
		 listen_handle_cast/2, listen_handle_info/2, listen_stop/2]).
-export([http_init/3]).


%% ===================================================================
%% Types
%% ===================================================================


-type listen_state() :: term().
-type conn_state() :: term().



%% ===================================================================
%% Common callbacks
%% ===================================================================

%% @doc If you implement this function, it must return, for any supported scheme,
%% the list of supported transports. 
-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(_) ->
	[tcp, tls, udp, sctp, ws, wss].


%% @doc If you implement this function, it will be used to find the default port
%% for this transport. If not implemented, port '0' will use any port for
%% listener transports, and will fail for outbound connections.
-spec default_port(nkpacket:transport()) ->
    inet:port_number() | invalid.

default_port(_) ->
    invalid.

%% @doc Implement this function to provide a 'quick' unparse functions, 
%% in case you don't need the connection state to perform the unparse.
%% Do not implement it or return 'continue' to call conn_unparse/2
-spec unparse(term(), nkpacket:nkport()) ->
    {ok, nkpacket:raw_msg()} | continue | {error, term()}.

unparse(_, _) ->
    continue.




%% ===================================================================
%% Connection callbacks
%% ===================================================================

%% Connection callbacks, if implemented, are called during the life cicle of a
%% connection

%% @doc Called when the connection starts
-spec conn_init(nkpacket:nkport()) ->
	conn_state().

conn_init(_) ->
	none.


%% @doc This function is called when a new message arrives to the connection
-spec conn_parse(term()|closed, conn_state()) ->
	{ok, conn_state()} | {bridge, nkpacket:nkport()} | 
	{stop, Reason::term(), conn_state()}.

conn_parse(_Msg, ConnState) ->
	{ok, ConnState}.


%% @doc This function is called when a new message must be send to the connection
-spec conn_unparse(term(), conn_state()) ->
	{ok, nkpacket:raw_msg(), conn_state()} | {error, term(), conn_state()} |
	{stop, Reason::term()}.

conn_unparse(_Term, ConnState) ->
	{error, not_defined, ConnState}.


%% @doc Called when the connection received a gen_server:call/2,3
-spec conn_handle_call(term(), {pid(), term()}, conn_state()) ->
	{ok, conn_state()} | {stop, Reason::term()}.

conn_handle_call(_Msg, _From, ListenState) ->
	{stop, not_defined, ListenState}.


%% @doc Called when the connection received a gen_server:cast/2
-spec conn_handle_cast(term(), conn_state()) ->
	{ok, conn_state()} | {stop, Reason::term()}.

conn_handle_cast(_Msg, ListenState) ->
	{stop, not_defined, ListenState}.


%% @doc Called when the connection received an erlang message
-spec conn_handle_info(term(), conn_state()) ->
	{ok, conn_state()} | {stop, Reason::term()}.

conn_handle_info(_Msg, ListenState) ->
	{stop, not_defined, ListenState}.

%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), conn_state()) ->
	ok.

conn_stop(_Reason, _State) ->
	ok.



%% ===================================================================
%% Listen callbacks
%% ===================================================================

%% Listen callbacks, if implemented, are called during the life cicle of a
%% listening transport

%% @doc Called when the listening transport starts
-spec listen_init(nkpacket:nkport()) ->
	listen_state().

listen_init(_) ->
	none.


%% @doc This function is called only for UDP transports using no_connections=>true
-spec listen_parse(inet:ip_address(), inet:port_number(), 
				   nkpacket:raw_msg(), listen_state()) ->
    {ok, listen_state()} | {stop, Reason::term(), listen_state()}.

listen_parse(_Ip, _Port, _Msg, ListenState) ->
	{stop, not_defined, ListenState}.


%% @doc Called when the listening transport received a gen_server:call/2,3
-spec listen_handle_call(term(), {pid(), term()}, listen_state()) ->
	{ok, listen_state()} | {stop, Reason::term(), listen_state()}.

listen_handle_call(_Msg, _From, ListenState) ->
	{stop, not_defined, ListenState}.


%% @doc Called when the listening transport received a gen_server:cast/2
-spec listen_handle_cast(term(), listen_state()) ->
	{ok, listen_state()} | {stop, Reason::term(), listen_state()}.

listen_handle_cast(_Msg, ListenState) ->
	{stop, not_defined, ListenState}.


%% @doc Called when the listening transport received an erlang message
-spec listen_handle_info(term(), listen_state()) ->
	{ok, listen_state()} | {stop, Reason::term(), listen_state()}.

listen_handle_info(_Msg, ListenState) ->
	{stop, not_defined, ListenState}.


%% @doc Called when the listening transport stops
-spec listen_stop(Reason::term(), listen_state()) ->
	ok.

listen_stop(_Reason, _State) ->
	ok.



%% ===================================================================
%% HTTP callbacks
%% ===================================================================

%% @doc This callback is called for the http/https "pseudo" transports.
%% It is used by the built-in http protocol, nkpacket_protocol_http.erl

-spec http_init(nkpacket:nkport(), cowboy_req:req(), cowboy_middleware:env()) ->
    {ok, Req::cowboy_req:req(),  Env::cowboy_middleware:env(), Middlewares::[module()]}.
    
http_init(_NkPort, _Req, _Env) ->
	error(not_defined).

