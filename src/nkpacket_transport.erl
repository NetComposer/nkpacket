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


%% To get debug info, the current process must hace 'nkpacket_debug=true'

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

get_connected(#nkconn{transp=Transp}=Conn) when Transp==ws; Transp==wss ->
    #nkconn{protocol=Protocol, ip=Ip, port=Port, opts=Opts} = Conn,
    Class = maps:get(class, Opts, none),
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

get_connected(#nkconn{protocol=Protocol, transp=Transp, ip=Ip, port=Port, opts=Opts}) ->
    Class = maps:get(class, Opts, none),
    [
        Pid ||
        {_Meta, Pid} <- nklib_proc:values({nkpacket_connection, Class, {Protocol, Transp, Ip, Port}})
    ].



%% @private
%% If option pre_send_fun is used, an updated message will be returned along the pid
-spec send([nkpacket:send_spec()], term()) ->
    {ok, pid()} | {ok, pid(), term()} | {error, term()}.

% Used when we don't want to reuse the same exact connection (stateless proxies)
send([#nkport{socket=undefined, opts=Opts} = NkPort|Rest], Msg) ->
    {ok, {Protocol, Transp, Ip, Port}} = nkpacket:get_remote(NkPort),
    Conn = #nkconn{protocol=Protocol, transp=Transp, ip=Ip, port=Port, opts=Opts},
    send([{current, Conn}|Rest], Msg);

send([#nkport{opts=Opts} = NkPort|Rest], Msg) ->
    case do_send([NkPort], Msg, Opts) of
        {ok, Pid2} ->
            {ok, Pid2};
        {ok, Pid2, Msg2} ->
            {ok, Pid2, Msg2};
        {error, Error} ->
            send(Rest++[{error, Error}], Msg)
    end;

send([Pid|Rest], Msg) when is_pid(Pid) ->
    % With pids, no udp_to_tcp is possible
    case do_send([Pid], Msg, #{}) of
        {ok, Pid2} ->
            {ok, Pid2};
        {ok, Pid2, Msg2} ->
            {ok, Pid2, Msg2};
        {error, Error} ->
            send(Rest++[{error, Error}], Msg)
    end;

send([{current, #nkconn{transp=udp}=Conn}|Rest], Msg) ->
    send([Conn|Rest], Msg);

send([{current, #nkconn{}=Conn}|Rest], Msg) ->
    Pids = get_connected(Conn),
    send(Pids++Rest, Msg);

send([#nkconn{protocol=Protocol, transp=Transp, port=0}=Conn|Rest], Msg) ->
    case get_defport(Protocol, Transp) of
        {ok, Port} ->
            send([Conn#nkconn{port=Port}|Rest], Msg);
        error ->
            send(Rest++[{error, invalid_default_port}], Msg)
    end;

send([{connect, #nkconn{transp=Transp, opts=Opts}=Conn}|Rest], Msg) ->
    case connect([Conn]) of
        {ok, NkPort} ->
            ?DEBUG("connected to ~p", [NkPort]),
            case do_send([NkPort], Msg, Opts) of
                {ok, Pid} ->
                    {ok, Pid};
                {ok, Pid, Msg2} ->
                    {ok, Pid, Msg2};
                retry_tcp when Transp==udp ->
                    send([Conn#nkconn{transp=tcp}|Rest], Msg);
                {error, Error} ->
                    send(Rest++[{error, Error}], Msg)
            end;
        {error, Error} ->
            ?LLOG(info, "error connecting to ~p: ~p", [Conn, Error]),
            send(Rest++[{error, Error}], Msg)
    end;

send([#nkconn{transp=Transp, opts=#{class:=_}=Opts}=Conn|Rest], Msg) ->
    Pids = case Opts of
        #{force_new:=true} ->
            [];
        _ ->
            get_connected(Conn)
    end,
    case do_send(Pids, Msg, Opts) of
        {ok, Pid} ->
            ?DEBUG("used previous connection to ~p (~p)", [Conn, Opts]),
            {ok, Pid};
        {ok, Pid, Msg2} ->
            ?DEBUG("used previous connection to ~p (~p)", [Conn, Opts]),
            {ok, Pid, Msg2};
        retry_tcp when Transp==udp ->
            ?DEBUG("retrying with tcp", []),
            send([Conn#nkconn{transp=tcp}|Rest], Msg);
        {error, Error} ->
            send([{connect, Conn}|Rest++[{error, Error}]], Msg)
    end;

% If we don't specify a class, do not reuse connections
send([#nkconn{}=Conn|Rest], Msg) ->
    lager:error("NKLOG CONNECT3"),
    send([{connect, Conn}|Rest], Msg);

send([{error, Error}|_], _Msg) ->
    {error, Error};

send([], _) ->
    {error, no_transports}.



%% @private
-spec do_send([#nkport{}|pid()], term(), nkpacket:send_opts()) ->
    {ok, pid()} | {ok, pid(), term()} | retry_tcp | no_transports | {error, term()}.

do_send([], _Msg, _Opts) ->
    {error, no_transports};

do_send([{error, Error}|_], _Msg, _Opts) ->
    {error, Error};

do_send([Port|Rest], Msg, Opts) ->
    case Opts of
        #{debug:=true} -> put(nkpacket_debug, true);
        _ -> ok
    end,
    case nkpacket_connection:send(Port, Msg) of
        ok when is_pid(Port) ->
            {ok, Port};
        ok ->
            {ok, Port#nkport.pid};
        {ok, Msg2} when is_pid(Port) ->
            {ok, Port, Msg2};
        {ok, Msg2} ->
            {ok, Port#nkport.pid, Msg2};
        {error, udp_too_large} ->
            case Opts of
                #{udp_to_tcp:=true} ->
                    retry_tcp;
                _ ->
                    ?LLOG(info, "error sending msg: udp_too_large", []),
                    do_send(Rest++[{error, udp_too_large}], Msg, Opts)
            end;
        {error, Error} ->
            ?LLOG(info, "error sending msg to ~p: ~p", [Port, Error]),
            do_send(Rest++[{error, Error}], Msg, Opts)
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
    case Opts of
        #{debug:=true} -> put(nkpacket_debug, true);
        _ -> ok
    end,
    BasePort1 = maps:get(base_nkport, Opts, true),
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
            ?DEBUG("base nkport: ~p", [BasePort2]),
            % Our listening host and meta must not be used for the new connection
            BaseMeta2 = maps:without([host, path], BaseMeta),
            Opts2 = maps:merge(BaseMeta2, Opts),
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
            case nkpacket_connection:connect(ConnPort) of
                {ok, ConnNkPort} ->
                    % The real used nkport can be different (with local tcp port f.e.)
                    {ok, ConnNkPort};
                {error, Error} ->
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






