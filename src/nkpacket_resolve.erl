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

%% @doc Resolver


-module(nkpacket_resolve).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([resolve/1, resolve/2, check_syntax/2]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


%% @private
-spec resolve(nkpacket:send_spec()|[nkpacket:send_spec()]) ->
    {ok, [nkpacket:send_spec()]} | {error, term()}.


resolve(Any) ->
    resolve(Any, #{}).


%% @private
resolve([], _Opts) ->
    {ok, []};

resolve(List, Opts) when is_list(List), not is_integer(hd(List)) ->
    resolve(List, Opts, []);

resolve(Other, Opts) ->
    resolve([Other], Opts, []).


%% @private
resolve([], _Opts, Acc) ->
    {ok, Acc};

resolve([#nkconn{}=Conn|Rest], Opts, Acc) ->
    case do_resolve_nkconn(Conn, Opts) of
        {ok, Conns} ->
            resolve(Rest, Opts, Acc++Conns);
        {error, Error} ->
            {error, Error}
    end;

resolve([#uri{}=Uri|Rest], Opts, Acc) ->
    case do_resolve_uri(Uri, Opts) of
        {ok, Conns} ->
            resolve(Rest, Opts, Acc++Conns);
        {error, Error} ->
            {error, Error}
    end;

resolve([Pid|Rest], #{resolve_type:=send}=Opts, Acc) when is_pid(Pid) ->
    resolve(Rest, Opts, Acc++[Pid]);

resolve([#nkport{}=Port|Rest], #{resolve_type:=send}=Opts, Acc) ->
    resolve(Rest, Opts, Acc++[Port]);

resolve([{connect, #nkconn{}=Conn}|Rest], #{resolve_type:=send}=Opts, Acc) ->
    case do_resolve_nkconn(Conn, Opts) of
        {ok, Conns} ->
            resolve(Rest, Opts, Acc++[{connect, C} || C <- Conns]);
        {error, Error} ->
            {error, Error}
    end;

resolve([{current, #nkconn{}=Conn}|Rest], #{resolve_type:=send}=Opts, Acc) ->
    case do_resolve_nkconn(Conn, Opts) of
        {ok, Conns} ->
            resolve(Rest, Opts, Acc++[{current ,C} || C <- Conns]);
        {error, Error} ->
            {error, Error}
    end;

resolve([Uri|Rest], Opts, Acc) ->
    case nklib_parse:uris(Uri) of
        error ->
            {error, {invalid_uri, Uri}};
        Parsed ->
            resolve(Parsed++Rest, Opts, Acc)
    end.


%% @private
do_resolve_nkconn(#nkconn{protocol=Protocol, opts=Opts0} = Conn, Opts) ->
    Opts2 = case erlang:function_exported(Protocol, resolve_opts, 0) of
        true ->
            ProtocolOpts = Protocol:resolve_opts(),
            maps:merge(ProtocolOpts, Opts);
        false ->
            Opts
    end,
    Opts3 = maps:merge(Opts0, Opts2),
    case nkpacket_util:parse_opts(Opts3) of
        {ok, Opts4} ->
            Conn2 = Conn#nkconn{opts=Opts4},
            Conn3 = resolve_external(Conn2),
            {ok, [Conn3]};
        {error, Error} ->
            {error, Error}
    end.


%% @private
%% Generates key "external_url" for http transports
%% No final '/'
resolve_external(#nkconn{transp=Transp}=Conn) when Transp==http; Transp==https ->
    #nkconn{ip=Ip, port=Port, opts=Opts} = Conn,
    Ext1 = list_to_binary([
        nklib_util:to_binary(Transp), "://",
        case maps:get(external_host, Opts, <<>>) of
            <<>> ->
                nklib_util:to_host(Ip);
            ExtHost ->
                ExtHost
        end,
        case
            case maps:get(external_port, Opts, 0) of
                0 ->
                    Port;
                ExtPort ->
                    ExtPort
            end
        of
            80 when Transp == http ->
                <<>>;
            443 when Transp == https ->
                <<>>;
            MyPort ->
                [":", integer_to_binary(MyPort)]
        end,
        filename:join([
            maps:get(path, Opts, "/"),
            maps:get(external_path, Opts, "/")
        ])
    ]),
    Ext2 = nklib_url:norm(Ext1),
    Conn#nkconn{opts=Opts#{external_url=>Ext2}};

resolve_external(Conn) ->
    Conn.


%% @private
do_resolve_uri(Uri, Opts) ->
    #uri{
        scheme = Scheme,
        user = User,
        pass = Pass,
        domain = Host, 
        path = Path, 
        ext_opts = UriOpts, 
        ext_headers = Headers
    } = Uri,
    Protocol = case Opts of
        #{protocol:=UserProtocol} ->
            UserProtocol;
        _ when Scheme==http; Scheme==https ->
            nkpacket_httpc_protocol;
        #{class:=Class} ->
            nkpacket:get_protocol(Class, Scheme);
        #{schemes:=Schemes} ->
            case maps:find(Scheme, Schemes) of
                {ok, SchemeProto} ->
                    SchemeProto;
                error ->
                    nkpacket:get_protocol(Scheme)
            end;
        _ ->
            nkpacket:get_protocol(Scheme)
    end,
    Opts2 = case erlang:function_exported(Protocol, resolve_opts, 0) of
        true ->
            ProtocolOpts = Protocol:resolve_opts(),
            maps:merge(ProtocolOpts, Opts);
        false ->
            Opts
    end,
    UriOpts1 = [{nklib_parse:unquote(K), nklib_parse:unquote(V)} || {K, V} <- UriOpts],
    % Let's see if we want to listen or connect to a specific host
    UriOpts2 = case Host of
        <<"0.0.0.0">> ->
            UriOpts1;
        <<"0:0:0:0:0:0:0:0">> ->
            UriOpts1;
        <<"::0">> ->
            UriOpts1;
        <<"all">> ->
            UriOpts1;
        <<"node">> ->
            UriOpts1;
        _ ->
            [{host, Host}|UriOpts1]            % Host to listen on for WS/HTTP
    end,
    UriOpts3 = case User of
        <<>> ->
            UriOpts2;
        _ ->
            case Pass of
                <<>> ->
                    [{user, User}|UriOpts2];
                _ ->
                    [{user, User}, {password, Pass}|UriOpts2]
            end
    end,
    UriOpts4 = case Path of
        <<>> ->
            UriOpts3;
        _ ->
            [{path, Path}|UriOpts3]            % Path to listen on for WS/HTTP
    end,
    UriOpts5 = case Headers of
        [] ->
            UriOpts4;
        _ ->
            [{user, Headers}|UriOpts4]          % TODO Is this right?
    end,
    try
        % Opts is used here only for parse_syntax
        UriOpts6 = case nkpacket_util:parse_uri_opts(UriOpts5, Opts) of
            {ok, ParsedUriOpts} ->
                ParsedUriOpts;
            {error, Error1} ->
                throw(Error1)
        end,
        Opts3 = case nkpacket_util:parse_opts(Opts2) of
            {ok, CoreOpts} ->
                maps:merge(UriOpts6, CoreOpts);
            {error, Error2} ->
                throw(Error2)
        end,
        % Now we have all the options, from the uri and the supplied options
        Opts4 = maps:without([resolve_type, protocol], Opts3),
        case nkpacket_dns:resolve(Uri, Opts3#{protocol=>Protocol}) of
            {ok, Addrs} ->
                Conns = lists:map(
                    fun({Transp, Addr, Port}) ->
                        Conn = #nkconn{protocol=Protocol, transp=Transp, ip=Addr, port=Port, opts=Opts4},
                        resolve_external(Conn)
                    end,
                    Addrs),
                {ok, Conns};
            {error, Error} ->
                {error, Error}
        end
    catch
        throw:Throw -> {error, Throw}
    end.


%% @doc
check_syntax(Protocol, Url) ->
    case resolve(Url, #{protocol=>Protocol}) of
        {ok, _Conns} ->
            ok;
        {error, _Error} ->
            error
    end.



