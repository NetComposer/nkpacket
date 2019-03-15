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

%% @doc Default implementation for HTTP1 clients
%% Expects parameter notify_pid in user's state
%% Will send messages {nkpacket_httpc_protocol, Ref, Term},
%% Term :: {head, Status, Headers} | {body, Body} | {chunk, Chunk}

-module(nkpacket_httpc).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([request/3, request/4, request/5, request/6, do_connect/2, do_request/6]).
-export_type([method/0, path/0, header/0, body/0]).

-include("nkpacket.hrl").
-include_lib("nklib/include/nklib.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type method() :: get | post | put | delete | head | patch | binary().
-type path() :: binary().
-type header() :: {binary(), binary()}.
-type body() :: iolist().
-type status() :: 100..599.

-type opts() ::
    nkpacket:connect_opts() |
    #{
        headers => [header()]       % Headers to include in all requests
    }.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc
-spec request(nkpacket:connect_spec(), method(), path()) ->
    {ok, status(), [header()], binary()} | {error, term()}.

request(Url, Method, Path) ->
    request(Url, Method, Path, []).


%% @doc
-spec request(nkpacket:connect_spec(), method(), path(), [header()]) ->
    {ok, status(), [header()], binary()} | {error, term()}.

request(Url, Method, Path, Hds) ->
    request(Url, Method, Path, Hds, <<>>).


%% @doc
-spec request(nkpacket:connect_spec(), method(), path(), [header()], body()) ->
    {ok, status(), [header()], binary()} | {error, term()}.

request(Url, Method, Path, Hds, Body) ->
    request(Url, Method, Path, Hds, Body, #{}).


%% @doc
-spec request(nkpacket:connect_spec(), method(), path(), [header()], body(), opts()) ->
    {ok, status(), [header()], binary()} | {error, term()}.

request(Url, Method, Path, Hds, Body, Opts) ->
    case do_connect(Url, Opts) of
        {ok, ConnPid} ->
            do_request(ConnPid, Method, Path, Hds, Body, Opts);
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec do_connect(nkpacket:connect_spec(), opts()) ->
    {ok, pid()} | {error, term()}.

do_connect(Url, Opts) ->
    ConnOpts = #{
        monitor => self(),
        user_state => maps:with([headers], Opts),
        connect_timeout => maps:get(connect_timeout, Opts, 1000),
        idle_timeout => maps:get(idle_timeout, Opts, 60000),
        debug => maps:get(debug, Opts, false)
    },
    case nkpacket:connect(Url, ConnOpts) of
        {ok, ConnPid} ->
            {ok, ConnPid};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec do_request(pid(), method(), path(), [header()], body(), opts()) ->
    {ok, status(), [header()], binary()} | {error, term()}.

do_request(ConnPid, Method, Path, Hds, Body, Opts) when is_atom(Method) ->
    Ref = make_ref(),
    Req = #{
        ref => Ref,
        pid => self(),
        method => Method,
        path => Path,
        headers => Hds,
        body => Body
    },
    Timeout = maps:get(timeout, Opts, 5000),
    case nkpacket:send(ConnPid, {nkpacket_http, Req}) of
        {ok, _ConnPid2} ->
            receive
                {nkpacket_httpc_protocol, Ref, {head, Status, Headers}} ->
                    do_request_body(Ref, Opts, Timeout, Status, Headers, []);
                {nkpacket_httpc_protocol, Ref, {error, Error}} ->
                    {error, Error}
            after
                Timeout ->
                    {error, timeout}
            end;
        {error, Error} ->
            {error, Error}
    end;

do_request(ConnPid, Method, Path, Hds, Body, Opts) ->
    case catch binary_to_existing_atom(nklib_util:to_lower(Method), latin1) of
        Method2 when is_atom(Method2) ->
            do_request(ConnPid, Method2, Path, Hds, Body, Opts);
        _ ->
            {error, method_unknown}
    end.


%% @private
do_request_body(Ref, Opts, Timeout, Status, Headers, Chunks) ->
    receive
        {nkpacket_httpc_protocol, Ref, {chunk, Data}} ->
            do_request_body(Ref, Opts, Timeout, Status, Headers, [Data|Chunks]);
        {nkpacket_httpc_protocol, Ref, {body, Body}} ->
            case Chunks of
                [] ->
                    {ok, Status, Headers, Body};
                _ when Body == <<>> ->
                    {ok, Status, Headers, list_to_binary(lists:reverse(Chunks))};
                _ ->
                    {error, invalid_chunked}
            end;
        {nkpacket_httpc_protocol, Ref, {error, Error}} ->
            {error, Error}
    after Timeout ->
        {error, timeout2}
    end.
