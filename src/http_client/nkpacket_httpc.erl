%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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

-export([request/3, request/4, request/5, request/6]).
-export([put/0]).
%-export([get/0, put/0, url_get/0, url_put/0]).

-include_lib("nkpacket.hrl").

%% ===================================================================
%% Public
%% ===================================================================

%% @doc
request(Url, Method, Path) ->
    request(Url, Method, Path, []).


%% @doc
request(Url, Method, Path, Hds) ->
    request(Url, Method, Path, Hds, <<>>).


%% @doc
request(Url, Method, Path, Hds, Body) ->
    request(Url, Method, Path, Hds, Body, 5000).


%% @doc
request(Url, Method, Path, Hds, Body, Timeout) ->
    Opts = #{
        monitor => self(),
        user_state => #{},
        connect_timeout => 1000,
        idle_timeout => 60000,
        debug => true
    },
    case nkpacket:connect(Url, Opts) of
        {ok, ConnPid, _} ->
            Ref = make_ref(),
            Msg = {
                http,
                Ref,
                self(),
                nklib_util:to_upper(Method),
                to_bin(Path),
                [{to_bin(K), to_bin(V)} || {K, V} <- Hds],
                to_bin(Body)
            },
            case nkpacket:send(ConnPid, Msg) of
                {ok, ConnPid} ->
                    lager:error("NKLOG STRT ~p ~p", [self(), Ref]),
                    receive
                        {nkpacket_httpc_protocol, Ref, {head, Status, Headers}} ->
                            request_body(Ref, Opts, Timeout, Status, Headers, []);
                        {nkpacket_httpc_protocol, Ref, {error, Error}} ->
                            {error, Error}
                    after
                        Timeout ->
                            {error, timeout}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
request_body(Ref, Opts, Timeout, Status, Headers, Chunks) ->
    receive
        {nkpacket_httpc_protocol, Ref, {chunk, Data}} ->
            request_body(Ref, Opts, Timeout, Status, Headers, [Data|Chunks]);
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


%% ===================================================================
%% S3 Test
%% ===================================================================

% Set your credentials here
% export MINIO_ACCESS_KEY=5UBED0Q9FB7MFZ5EWIOJ; export MINIO_SECRET_KEY=CaK4frX0uixBOh16puEsWEvdjQ3X3RTDvkvE+tUI; minio server 1

config() ->
    #{
        key_id => <<"5UBED0Q9FB7MFZ5EWIOJ">>,
        key => <<"CaK4frX0uixBOh16puEsWEvdjQ3X3RTDvkvE+tUI">>,
        host => <<"http://127.0.0.1:9000">>
    }.


%%get() ->
%%    C1 = config(),
%%    C2 = C1#{access_method=>path},
%%    {ReqURI, ReqHeaders} = nkpacket_httpc_s3:get_object("bucket1", "/test1", C2),
%%    nkpacket_httpc:request(ReqURI, get, Path, Hds, <<>>).
%%
%%
%%
%%
put() ->
    C1 = config(),
    C2 = C1#{
        headers => [{<<"content-type">>, <<"application/json">>}],
        params => [{<<"a">>, <<"1">>}, {<<"b">>, <<"2">>}],
        meta => [{<<"b">>, <<"2">>}],
        acl => private
    },
    {Uri, Path, Headers} = nkpacket_httpc_s3:get_object("bucket1", "/test1", C2),
    request(Uri, put, Path, Headers, <<"val5">>).



%%
%%url_put() ->
%%    URL = make_put_url("carlos-publico", "/test1", "application/json", 5000, config()),
%%    hackney:request(put, URL, [{<<"content-type">>, <<"application/json">>}], <<>>, [with_body]).
%%
%%
%%
%%url_get() ->
%%    URL = make_get_url("carlos-publico", "/test1", 5000, config()),
%%    hackney:request(get, URL, [], <<>>, [with_body]).



%% @private
to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) -> nklib_util:to_binary(Term).

