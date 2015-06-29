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

%% @doc NkPACKET Transport control module
-module(nkpacket_transport).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([connect/2, send/3, get_connected/1, get_connected/2]).
-export([get_listener/1, open_port/2, get_defport/2]).
-export_type([socket/0]).

-compile({no_auto_import,[get/1]}).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


-type socket() :: 
    port() | ssl:sslsocket() | {port(), integer()} | pid().

-define(CONN_TRIES, 100).
-define(OPEN_ITERS, 5).


%% ===================================================================
%% Public
%% ===================================================================


%% @private Finds a connected transport
-spec get_connected(nkpacket:raw_connection()) ->
    [nkpacket:nkport()].

get_connected(Conn) ->
    get_connected(Conn, #{}).


%% @private Finds a connected transport
-spec get_connected(nkpacket:raw_connection(), map()) ->
    [nkpacket:nkport()].

get_connected({_Proto, Transp, _Ip, _Port}, _Opts) when Transp==http; Transp==https ->
    [];

get_connected({_Proto, Transp, _Ip, _Port}=Conn, Opts) when Transp==ws; Transp==wss ->
    Path = maps:get(path, Opts, <<"/">>),
    Host = maps:get(host, Opts, all),
    WsProto = maps:get(ws_proto, Opts, all),
    Group = maps:get(group, Opts, none),
    All = [
        NkPort || 
        {NkPort, _} <- nklib_proc:values({nkpacket_connection, Group, Conn})
    ],
    lists:filter(
        fun(#nkport{meta=#{path:=ConnPath}=Meta}) ->
            ConnPath==Path andalso
            case maps:get(host, Meta, all) of
                all -> true;
                Host -> true;
                _ -> false
            end andalso
            case maps:get(ws_proto, Meta, all) of
                all -> true;
                WsProto -> true;
                _ -> false
            end
        end,
        All);

get_connected({_, _, _, _}=Conn, Opts) ->
    Group = maps:get(group, Opts, none),
    [
        NkPort || 
        {NkPort, _} <- nklib_proc:values({nkpacket_connection, Group, Conn})
    ].


%% @private
-spec send([nkpacket:send_spec()], term(), nkpacket:send_opts()) ->
    ok | {error, term()}.

send([Uri|Rest], Msg, Opts) when is_binary(Uri); is_list(Uri) ->
    case nklib_parse:uris(Uri) of
        PUris when is_list(PUris) ->
            send([PUri || PUri <- PUris]++Rest, Msg, Opts);
        error ->
            send(Rest, Msg, Opts#{last_error=>{invalid_uri, Uri}})
    end;
     
send([#uri{}=Uri|Rest], Msg, Opts) ->
    case nkpacket:resolve(Uri, Opts) of
        {ok, RawConns, Opts1} ->
            lager:debug("Transport send to ~p (~p)", [RawConns, Rest]),
            send(RawConns++Rest, Msg, Opts1);
        {error, Error} ->
            lager:notice("Error sending to ~p: ~p", [Uri, Error]),
            send(Rest, Msg, Opts#{last_error=>Error})
    end;

send([#nkport{}=NkPort|Rest], Msg, Opts) ->
    lager:debug("Transport send to nkport ~p", [NkPort]),
    case do_send(Msg, [NkPort], Opts#{udp_to_tcp=>false}) of
        {ok, NkPort1} -> {ok, NkPort1};
        {error, Opts1} -> send(Rest, Msg, Opts1)
    end;

send([{current, {Protocol, udp, Ip, Port}}|Rest], Msg, Opts) ->
    send([{Protocol, udp, Ip, Port}|Rest], Msg, Opts);

send([{current, Conn}|Rest], Msg, Opts) ->
    NkPorts = get_connected(Conn, Opts),
    send(NkPorts++Rest, Msg, Opts);

send([{Protocol, Transp, Ip, 0}|Rest], Msg, Opts) ->
    case get_defport(Protocol, Transp) of
        {ok, Port} ->
            send([{Protocol, Transp, Ip, Port}|Rest], Msg, Opts);
        error ->
            send(Rest, Msg, Opts#{last_error=>invalid_default_port})
    end;

send([{_, _, _, _}=Conn|Rest], Msg, #{force_new:=true}=Opts) ->
    RemoveOpts = [force_new, udp_to_tcp, last_error],
    ConnOpts = maps:without(RemoveOpts, Opts),
    lager:debug("Transport connecting to ~p (~p)", [Conn, ConnOpts]),
    case connect([Conn], ConnOpts) of
        {ok, NkPort} ->
            case do_send(Msg, [NkPort], Opts) of
                {ok, NkPort1} ->
                    {ok, NkPort1};
                retry_tcp ->
                    Conn1 = setelement(2, Conn, tcp), 
                    send([Conn1|Rest], Msg, Opts);
                {error, Opts1} ->
                    send(Rest, Msg, Opts1)
            end;
        {error, Error} ->
            lager:notice("Error connecting to ~p: ~p", [Conn, Error]),
            send(Rest, Msg, Opts#{last_error=>Error})
    end;

send([{_, _, _, _}=Conn|Rest]=Spec, Msg, #{group:=_}=Opts) ->
    NkPorts = get_connected(Conn, Opts),
    case do_send(Msg, NkPorts, Opts) of
        {ok, NkPort1} -> 
            lager:debug("Transport used previous connection to ~p (~p)", [Conn, Opts]),
            {ok, NkPort1};
        retry_tcp ->
            Conn1 = setelement(2, Conn, tcp), 
            lager:debug("Transport retrying with tcp", []),
            send([Conn1|Rest], Msg, Opts);
        {error, Opts1} -> 
            send(Spec, Msg, Opts1#{force_new=>true})
    end;

% If we dont specify a group, do not reuse connections
send([{_, _, _, _}|_]=Spec, Msg, Opts) ->
    send(Spec, Msg, Opts#{force_new=>true});

send([Term|Rest], Msg, Opts) ->
    lager:warning("Invalid send specification: ~p", [Term]),
    send(Rest, Msg, Opts#{last_error=>{invalid_send_specification, Term}});

send([], _Msg, #{last_error:=Error}) -> 
    {error, Error};

send([], _, _) ->
    {error, no_transports}.


%% @private
-spec do_send(term(), [#nkport{}], nkpacket:send_opts()) ->
    {ok, #nkport{}} | retry_tcp | {error, nkpacket:send_opts()}.

do_send(_Msg, [], Opts) ->
    {error, Opts};

do_send(Msg, [#nkport{}=NkPort|Rest], Opts) ->
    case encode(Msg, NkPort) of
        {ok, OutMsg} ->
            case nkpacket_connection:send(NkPort, OutMsg) of
                ok ->
                    {ok, NkPort};
                {error, udp_too_large} ->
                    case Opts of
                        #{udp_to_tcp:=true} ->
                            retry_tcp;
                        _ ->
                            lager:notice("Error sending msg: udp_too_large", []),
                            do_send(Msg, Rest, Opts#{last_error=>udp_too_large})
                    end;
                {error, Error} ->
                    lager:notice("Error sending msg to ~p: ~p", [NkPort, Error]),
                    do_send(Msg, Rest, Opts#{last_error=>Error})
            end;
        error ->
            {error, Opts#{last_error=>encode_error}}
    end.
 

%% @private
encode(Term, #nkport{protocol=Protocol}=NkPort) -> 
    case erlang:function_exported(Protocol, encode, 2) of
        true ->
            case Protocol:encode(Term, NkPort) of
                {ok, OutMsg} ->
                    {ok, OutMsg};
                continue ->
                    encode2(Term, NkPort);
                {error, Error} ->
                    lager:notice("Error unparsing msg: ~p", [Error]),
                    error

            end;
        false ->
            encode2(Term, NkPort)
    end.


%% @private
encode2(Term, #nkport{protocol=Protocol}=NkPort) -> 
    case erlang:function_exported(Protocol, conn_encode, 2) of
        true ->
            case nkpacket_connection:encode(NkPort, Term) of
                {ok, OutMsg} ->
                    {ok, OutMsg};
                {error, Error} ->
                    lager:notice("Error unparsing msg: ~p", [Error]),
                    error
            end;
        false ->
            {ok, Term}
    end.

        
%% @private Starts a new outbound connection.
-spec connect([nkpacket:raw_connection()], nkpacket:connect_opts()) ->
    {ok, nkpacket:nkport()} | {error, term()}.

connect([], _Opts) ->
    {error, no_transports};

connect([{Protocol, Transp, Ip, 0}|Rest], Opts) ->
    case get_defport(Protocol, Transp) of
        {ok, Port} -> 
            connect([{Protocol, Transp, Ip, Port}|Rest], Opts);
        error ->
            {error, invalid_default_port}
    end;

connect([Conn|Rest], Opts) ->
    Fun = fun() -> raw_connect(Conn, Opts) end,
    try nklib_proc:try_call(Fun, Conn, 100, ?CONN_TRIES) of
        {ok, NkPort} ->
            {ok, NkPort};
        {error, Error} when Rest==[] ->
            {error, Error};
        {error, _} ->
            connect(Rest, Opts)
    catch
        error:max_tries ->
            connect(Rest, Opts)
    end.


%% @private Starts a new connection to a remote server
%% Tries to find an associated listening transport, 
%% to use the listening address, port and meta from it
-spec raw_connect(nkpacket:raw_connection(), nkpacket:connect_opts()) ->
    {ok, nkpacket:nkport()} | {error, term()}.
         
raw_connect({Protocol, Transp, Ip, Port}, Opts) ->
    P1 = #nkport{
        transp = Transp, 
        remote_ip = Ip, 
        remote_port = Port, 
        protocol=Protocol
    },
    IpSize = size(Ip),
    Listening = nkpacket:get_listening(Protocol, Transp, Opts),
    P2 = case Opts of
        #{listen_ip:=ListenIp, listen_port:=ListenPort} ->
            case 
                [
                    Pid ||
                    {LIp, LPort, Pid} <- Listening,
                    LIp==ListenIp, size(LIp)==IpSize, LPort==ListenPort
                ]
            of
                [Pid|_] -> 
                    P1#nkport{listen_ip=ListenIp, listen_port=ListenPort, pid=Pid};
                [] ->
                    P1#nkport{listen_ip=ListenIp, listen_port=ListenPort}
            end;
        _ ->
            case
                [
                    {LIp, LPort, Pid} || 
                    {LIp, LPort, Pid} <- Listening, size(LIp)==IpSize
                ]
            of
                [{ListenIp, ListenPort, Pid}|_] -> 
                    P1#nkport{listen_ip=ListenIp, listen_port=ListenPort, pid=Pid};
                [] -> 
                    P1
            end
    end,
    lager:debug("Base port: ~p", [P2]),
    % If we found a listening transport, connection will monitor it
    nkpacket_connection:connect(P2).


-spec get_listener(nkpacket:nkport()) ->
    {ok, supervisor:child_spec()} | {error, term()}.

get_listener(#nkport{transp=udp}=NkPort) ->
    {ok, nkpacket_transport_udp:get_listener(NkPort)};

get_listener(#nkport{transp=Transp}=NkPort) when Transp==tcp; Transp==tls ->
    {ok, nkpacket_transport_tcp:get_listener(NkPort)};

get_listener(#nkport{transp=sctp}=NkPort) ->
    {ok, nkpacket_transport_sctp:get_listener(NkPort)};

get_listener(#nkport{transp=Transp}=NkPort) when Transp==ws; Transp==wss ->
    {ok, nkpacket_transport_ws:get_listener(NkPort)};

get_listener(#nkport{transp=Transp}=NkPort) when Transp==http; Transp==https ->
    {ok, nkpacket_transport_http:get_listener(NkPort)};

get_listener(_) ->
    {error, invalid_transport}.


%% @doc Gets the default port for a protocol
-spec get_defport(nkpacket:protocol(), nkpacket:transport()) ->
    {ok, inet:port_number()} | error.

get_defport(Protocol, Transp) ->
    case erlang:function_exported(Protocol, default_port, 1) of
        true ->
            case Protocol:default_port(Transp) of
                Port when is_integer(Port), Port > 0 -> 
                    {ok, Port};
                Other -> 
                    lager:warning("Error calling ~p:default_port(~p): ~p",
                                  [Protocol, Transp, Other]),
                    error
            end;
        false ->
            error
    end.


%% @private Tries to open a network port
%% If Port==0, it first tries the "default" port for this transport, if defined.
%% If port is in use if tries again after a while.
-spec open_port(nkpacket:nkport(), list()) ->
    {ok, port()} | {error, term()}.

open_port(NkPort, Opts) ->
    #nkport{
        transp = Transp,
        local_ip = Ip, 
        local_port = Port, 
        protocol = Protocol
    } = NkPort,
    {Module, Fun} = case Transp of
        udp -> {gen_udp, open};
        tcp -> {gen_tcp, listen};
        tls -> {ssl, listen};
        sctp -> {gen_sctp, open};
        ws -> {gen_tcp, listen};
        wss -> {ssl, listen};
        http -> {gen_tcp, listen};
        https -> {ssl, listen}
    end,
    DefPort = case get_defport(Protocol, Transp) of
        {ok, DefPort0} -> DefPort0;
        error -> undefined
    end,
    case Port of
        0 when is_integer(DefPort) ->
            lager:debug("Opening ~p:~p (default, ~p)", [Module, DefPort, Opts]),
            case Module:Fun(DefPort, Opts) of
                {ok, Socket} ->
                    {ok, Socket};
                {error, _} ->
                    open_port(Ip, 0, Module, Fun, Opts, ?OPEN_ITERS)
            end;
        _ ->
            open_port(Ip, Port, Module, Fun, Opts, ?OPEN_ITERS)
    end.


%% @private Checks if a port is available for UDP and TCP
-spec open_port(inet:ip_address(), inet:port_number(),
                module(), atom(), list(), pos_integer()) ->
    {ok, port()} | {error, term()}.

open_port(Ip, Port, Module, Fun, Opts, Iter) ->
    lager:debug("Opening ~p:~p (~p)", [Module, Port, Opts]),
    case Module:Fun(Port, Opts) of
        {ok, Socket} ->
            {ok, Socket};
        {error, eaddrinuse} when Iter > 0 ->
            lager:warning("~p port ~p is in use, waiting (~p)", 
                     [Module, Port, Iter]),
            timer:sleep(1000),
            open_port(Ip, Port, Module, Fun, Opts, Iter-1);
        {error, Error} ->
            {error, Error}
    end.






