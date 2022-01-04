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

%% @doc NkPACKET Transport control module
-module(nkpacket_transport).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([connect/1, send/2, get_connected/1]).
-export([get_listener/1, open_port/2, get_defport/2]).
-export_type([socket/0]).

-compile({no_auto_import,[get/1]}).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


-type socket() :: 
    port() | ssl:sslsocket() | {port(), integer()} | pid().

-define(CONN_TRIES, 100).
-define(OPEN_ITERS, 5).


%% To get debug info, the current process must have 'nkpacket_debug=true'

-define(DEBUG(Txt, Args),
    case erlang:get(nkpacket_debug) of
        true -> ?LLOG(debug, Txt, Args);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args), lager:Type("NkPACKET "++Txt, Args)).


%% ===================================================================
%% Public
%% ===================================================================


%% @private Finds a connected transport
-spec get_connected(nkpacket:nkconn()) ->
    [pid()].

get_connected(#nkconn{transp=Transp}) when Transp==http; Transp==https ->
    [];

get_connected(#nkconn{transp=Transp, opts=#{class:=Class}}=Conn) when Transp==ws; Transp==wss ->
    #nkconn{protocol=Protocol, ip=Ip, port=Port, opts=Opts} = Conn,
    Host = maps:get(host, Opts, any),
    Path = maps:get(path, Opts, any),
    WsProto = maps:get(ws_proto, Opts, any),
    nklib_util:filtermap(
        fun({Meta, Pid}) ->
            HostOK = Host==any orelse
                     case maps:get(host, Meta, any) of
                         any -> true;
                         Host -> true;
                         _ -> false
                     end,
            PathOK = Path==any orelse
                     case maps:get(path, Meta, any) of
                         any -> true;
                         Path -> true;
                         _ -> false
                     end,
            ProtoOK = WsProto==any orelse
                      case maps:get(ws_proto, Meta, any) of
                          any -> true;
                          WsProto -> true;
                          _ -> false
                      end,
            case HostOK andalso PathOK andalso ProtoOK of
                true -> {true, Pid};
                false -> false
            end
        end,
        nklib_proc:values({nkpacket_connection, Class, {Protocol, Transp, Ip, Port}}));

get_connected(#nkconn{protocol=Protocol, transp=Transp, ip=Ip, port=Port, opts=#{class:=Class}}) ->
    List = [
        Pid ||
        {_Meta, Pid} <- nklib_proc:values({nkpacket_connection, Class, {Protocol, Transp, Ip, Port}})
    ],
%%    lager:error("NKLOG FOUND CONNS ~p: ~p", [{nkpacket_connection, Class, {Protocol, Transp, Ip, Port}}, List]),
    List;

get_connected(#nkconn{}) ->
    [].




%% @private
%% If Msg is a function/1, it will be called as Msg(NkPort) and the resulting message
%% will be returned
-spec send([nkpacket:send_spec()], term()) ->
    {ok, pid()} | {ok, pid(), term()} | {error, term()}.

send([], _) ->
    ?LLOG(notice, "send error: no_transports", []),
    {error, no_transports};

send([#nkconn{protocol=Protocol, transp=Transp, port=0}=Conn|MoreConns], Msg) ->
    case get_defport(Protocol, Transp) of
        {ok, Port} ->
            send([Conn#nkconn{port=Port}|MoreConns], Msg);
        error ->
            send(MoreConns++[{error, invalid_default_port}], Msg)
    end;

send([#nkconn{opts=#{force_new:=true}}=Conn|MoreConns], Msg) ->
    send([{connect, Conn}|MoreConns], Msg);

send([#nkconn{}=Conn|MoreConns], Msg) ->
    Pids = get_connected(Conn),
    ?DEBUG("sending to nkconn ~p: (connected pids: ~p)", [lager:pr(Conn, ?MODULE), Pids]),
    %% Try connected pids, if nothing works try to connect to this conn before jumping
    %% to next one
    do_send(Pids, Conn, Msg, [{connect, Conn}|MoreConns]);

send([{current, #nkconn{transp=udp}=Conn}|MoreConns], Msg) ->
    ?DEBUG("sending to {current, ~p} (udp)", [lager:pr(Conn, ?MODULE)]),
    send([Conn|MoreConns], Msg);

send([{current, #nkconn{}=Conn}|MoreConns], Msg) ->
    Pids = get_connected(Conn),
    ?DEBUG("sending to {current, ~p} (connected pids: ~p)", [lager:pr(Conn, ?MODULE), Pids]),
    do_send(Pids, Conn, Msg, MoreConns);

send([{connect, #nkconn{}=Conn}|MoreConns], Msg) ->
    ?DEBUG("sending to {connect, ~p}", [lager:pr(Conn, ?MODULE)]),
    case connect([Conn]) of
        {ok, #nkport{}=NkPort} ->
            do_send([NkPort], Conn, Msg, MoreConns);
        {error, Error} ->
            send(MoreConns++[{error, Error}], Msg)
    end;

% Used when we don't want to reuse the same exact connection (stateless proxies)
send([#nkport{socket=undefined, class=Class, opts=Opts}=NkPort|MoreConns], Msg) ->
    ?DEBUG("sending to nkport (socket undefined) ~p", [lager:pr(NkPort, ?MODULE)]),
    {ok, {Protocol, Transp, Ip, Port}} = nkpacket:get_remote(NkPort),
    Conn = #nkconn{protocol=Protocol, transp=Transp, ip=Ip, port=Port, opts=Opts#{class=>Class}},
    send([{current, Conn}|MoreConns], Msg);

send([#nkport{}=NkPort|MoreConns], Msg) ->
    ?DEBUG("sending to nkport ~p", [lager:pr(NkPort, ?MODULE)]),
    do_send([NkPort], undefined, Msg, MoreConns);

send([Pid|MoreConns], Msg) when is_pid(Pid) ->
    ?DEBUG("sending to pid ~p", [Pid]),
    do_send([Pid], undefined, Msg, MoreConns);

send([{error, Error}|_], _Msg) ->
    ?DEBUG("send error reached: ~p", [Error]),
    {error, Error}.

%% @private
do_send([], _Conn, Msg, MoreConns) ->
    send(MoreConns, Msg);

do_send([{error, Error}|_], _Conn, Msg, MoreConns) ->
    send(MoreConns++[{error, Error}], Msg);

do_send([Pid|Rest], Conn, Msg, MoreConns) when is_pid(Pid) ->
    ?DEBUG("sending to connected pid ~p (~p)", [Pid, lager:pr(Conn, ?MODULE)]),
    case nkpacket_connection:send(Pid, Msg) of
        ok ->
            {ok, Pid};
        {ok, Msg2} ->
            {ok, Pid, Msg2};
        {error, udp_too_large} ->
            % For this error, skip all other pids
            case is_record(Conn, nkconn) andalso Conn#nkconn.opts of
                #{udp_to_tcp:=true} ->
                    ?DEBUG("retrying with tcp", []),
                    send([Conn#nkconn{transp=tcp}|MoreConns], Msg);
                _ ->
                    send(MoreConns++[{error, udp_too_large}], Msg)
            end;
        {error, Error} ->
            do_send(Rest++[{error, Error}], Conn, Msg, MoreConns)
    end;

do_send([#nkport{protocol=sctp, pid=Pid}|Rest], Conn, Msg, MoreConns) ->
    % SCTP does not seem to work with direct socket access
    ?DEBUG("sctp switching to pid", []),
    do_send([Pid|Rest], Conn, Msg, MoreConns);

do_send([#nkport{pid=Pid}=NkPort|Rest], Conn, Msg, MoreConns) ->
    ?DEBUG("sending to connected ~p (~p)", [lager:pr(NkPort, ?MODULE), lager:pr(Conn, ?MODULE)]),
    case nkpacket_connection:send(NkPort, Msg) of
        ok ->
            {ok, Pid};
        {ok, Msg2} ->
            {ok, Pid, Msg2};
        {error, udp_too_large} ->
            case is_record(Conn, nkconn) andalso Conn#nkconn.opts of
                #{udp_to_tcp:=true} ->
                    ?DEBUG("retrying with tcp", []),
                    send([Conn#nkconn{transp=tcp}|MoreConns], Msg);
                _ ->
                    send(MoreConns++[{error, udp_too_large}], Msg)
            end;
        {error, Error} ->
            do_send(Rest++[{error, Error}], Conn, Msg, MoreConns)
    end.


%% @private Starts a new outbound connection.
-spec connect([nkpacket:netspec()]) ->
    {ok, #nkport{}} | {error, term()}.

connect([]) ->
    {error, no_transports};

connect([#nkconn{protocol=Protocol, transp=Transp, port=0} = Conn|Rest]) ->
    case get_defport(Protocol, Transp) of
        {ok, Port} -> 
            connect([Conn#nkconn{port=Port}|Rest]);
        error ->
            {error, invalid_default_port}
    end;

connect([#nkconn{} = Conn|Rest]) ->
    ?DEBUG("connecting to ~p", [lager:pr(Conn, ?MODULE)]),
    Fun = fun() -> do_connect(Conn) end,
    try nklib_proc:try_call(Fun, Conn, 100, ?CONN_TRIES) of
        {ok, NkPort} ->
            {ok, NkPort};
        {error, Error} when Rest==[] ->
            {error, Error};
        {error, _} ->
            connect(Rest)
    catch
        error:max_tries ->
            connect(Rest)
    end.


%% @private Starts a new connection to a remote server
%% Tries to find an associated listening transport, 
%% to use the listening address, port and meta from it
-spec do_connect(nkpacket:nkconn()) ->
    {ok, pid()} | {error, term()}.
         
do_connect(#nkconn{protocol=Protocol, transp=Transp, ip=Ip, port=Port, opts=Opts}) ->
    BasePort1 = maps:get(base_nkport, Opts, false),
    BasePort2 = case BasePort1 of
        #nkport{} ->
            BasePort1;
        true ->
            case nkpacket:get_listening(Protocol, Transp, Opts#{ip=>Ip}) of
                [NkPort|_] ->
                    NkPort;
                [] ->
                    #nkport{}
            end;
        false ->
            #nkport{}
    end,
    #nkport{listen_ip=ListenIp, opts=BaseMeta} = BasePort2,
    case ListenIp of
        undefined when BasePort1 ->

            {error, no_listening_transport};
        _ ->
            ?DEBUG("base nkport: ~p", [lager:pr(BasePort2, ?MODULE)]),
            % Our listening host and meta must not be used for the new connection
            BaseMeta2 = maps:without([host, path], BaseMeta),
            Opts2 = maps:merge(Opts, BaseMeta2),
            ConnPort = BasePort2#nkport{
                id = maps:get(id, Opts),
                class = maps:get(class, Opts, none),
                transp = Transp,
                protocol = Protocol,
                remote_ip = Ip,
                remote_port = Port,
                opts = maps:without([id, class, user_state], Opts2),
                user_state = maps:get(user_state, Opts2, undefined)
            },
            % If we found a listening transport, connection will monitor it
            ?DEBUG("connecting to ~p", [lager:pr(ConnPort, ?MODULE)]),
            case nkpacket_connection:connect(ConnPort) of
                {ok, ConnNkPort} ->
                    % The real used nkport can be different (with local tcp port f.e.)
                    ?DEBUG("connected to ~p", [lager:pr(ConnNkPort, ?MODULE)]),
                    {ok, ConnNkPort};
                {error, Error} ->
                    ?LLOG(debug, "error connecting to ~p: ~p", [lager:pr(ConnPort, ?MODULE), Error]),
                    {error, Error}
            end
    end.


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
                    ?LLOG(warning, "error calling ~p:default_port(~p): ~p",
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
        listen_ip = Ip, 
        listen_port = Port, 
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
            ?DEBUG("opening ~p:~p (default, ~p)", [Module, DefPort, Opts]),
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
    ?DEBUG("opening ~p:~p (~p)", [Module, Port, Opts]),
    case Module:Fun(Port, Opts) of
        {ok, Socket} ->
            {ok, Socket};
        {error, eaddrinuse} when Iter > 0 ->
            ?LLOG(info, "~p port ~p is in use, waiting (~p)", 
                         [Module, Port, Iter]),
            timer:sleep(1000),
            open_port(Ip, Port, Module, Fun, Opts, Iter-1);
        {error, Error} ->
            {error, Error}
    end.






