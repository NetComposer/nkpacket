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

%% @doc Main management module.
-module(nkpacket).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_listener/3, stop_listener/1, stop_all/0, stop_all/1, get_port/1]).
-export([send/3, send/4, connect/3]).
-export([get_all/0, get_all/1, get_listening/4, is_local/2, is_local_ip/1]).
-export([resolve/3]).

-export_type([domain/0, transport/0, protocol/0, nkport/0]).
-export_type([listener_opts/0, connect_opts/0, send_opts/0, raw_msg/0]).
-export_type([connection/0, raw_connection/0, send_spec/0]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").



%% ===================================================================
%% Types
%% ===================================================================

%% Internal name of each started Domain
-type domain() :: nklib:domain_id().

%% Recognized transport schemes
-type transport() :: udp | tcp | tls | sctp | ws | wss | http | https.

%% A protocol is a module implementing nkpacket_protocol behaviour
-type protocol() :: module().

%% An opened port (listener or connection)
-type nkport() :: #nkport{}.

%% Options for listeners
-type listener_opts() ::
    #{
        % Common options
        supervisor => atom() | pid(),           % Supervisor to use
        idle_timeout => integer(),              % Idle connection timeout (180.000)
        
        % UDP options
        udp_starts_tcp => boolean(),            % UDP starts TCP on the same port
        udp_no_connections => boolean(),        % Do not create connections
        udp_stun_reply => boolean(),            % Do STUNs replies
        udp_stun_t1 => integer(),               % msecs, default 500

        % SCTP Opts
        sctp_out_streams => integer(),          % Number of out streams
        sctp_in_streams => integer(),           % Max input streams

        % TCP/TLS/WS/WSS options
        certfile => string(),                   % 
        keyfile => string(),                    %
        tcp_packet => 1 | 2 | 4 | raw,          %
        tcp_max_connections => integer(),       % Per listener
        tcp_listeners => integer(),             % Defalt 100

        % WS/WSS/HTTP/HTTPS options
        host => string() | binary(),            % Hosts to filter (comma separated)
        path => string() | binary(),            % Paths to filter (comma separated)
        cowboy_opts => cowboy_protocol:opts(),

        % WS/WSS
        ws_proto => string() | binary(),        % Websocket Subprotocol
        ws_opts => map(),

        % HTTP/HTTPS
        cowboy_dispatch => cowboy_router:dispatch_rules()
    }.


%% Options for connections
-type connect_opts() ::
    #{
        % Common options
        connect_timeout => integer(),       % msecs, default 30.000
        supervisor => atom() | pid(),       % Supervisor to use
        idle_timeout => integer(),          % msecs, default 180.000
        
        listen_ip => inet:ip_address(),     % Used to populate nkport, instead of
        listen_port => inet:port_number(),  % finding suitable listening transport
        
        % TCP/TLS/WS/WSS options
        certfile => string(),           
        keyfile => string(),                 
        tcp_packet => 1 | 2 | 4 | raw,      

        % WS/WSS
        host => string() | binary(),
        path => string() | binary(),
        ws_proto => string() | binary(),
        ws_opts => map()
    }.


%% Options for sending
-type send_opts() ::
    connect_opts() |
    #{
        % Specific options
        force_new => boolean(),             % Forces new connection
        udp_to_tcp => boolean()             % Change to TCP for large packets
    }.


%% Connection specification
-type user_connection() :: 
    nklib:user_uri() | connection().

%% Connection specification
-type connection() :: 
    nklib:uri() | raw_connection().


-type raw_connection() :: 
    {protocol(), transport(), inet:ip_address(), inet:port_number()}.


%% Sending remote specification options
-type send_spec() :: 
    user_connection() | {current, raw_connection()} | nkport().


%% Reply
-type raw_msg() ::
    iolist() | binary() |
    cow_ws:frame().                 % Only WS


%% ===================================================================
%% Public functions
%% ===================================================================

%% @doc Starts a new listening transport.
%% If Port==0, NkPacket will try first the protocol's default
-spec start_listener(domain(), user_connection(), listener_opts()) ->
    {ok, pid()} | {error, term()}.

start_listener(Domain, {_, _, _, _}=Conn, Opts) when is_map(Opts) ->
    case get_listener(Domain, Conn, Opts) of
        {ok, Spec} ->
            nkpacket_sup:add_transport(Spec, Opts);
        {error, Error} ->
            {error, Error}
    end;

start_listener(Domain, Uri, Opts) when is_map(Opts) ->
    case resolve(listen, Domain, Uri) of
        {ok, [Conn], UriOpts} ->
            Opts1 = maps:merge(UriOpts, Opts),
            start_listener(Domain, Conn, Opts1);
        {ok, _, _}=O ->
            {error, invalid_uri, O};
        {error, Error} ->
            {error, Error}
    end.



%% @private Gets a listening supervisor specification
%% The 'path' option is generated from the uri, if not already present
-spec get_listener(domain(), user_connection(), listener_opts()) ->
    {ok, supervisor:child_spec()} | {error, term()}.

get_listener(Domain, {Protocol, Transp, Ip, Port}, Opts) when is_map(Opts) ->
    case parse_opts(listen, Opts) of
        {ok, Opts1} ->
            NkPort = #nkport{
                domain = Domain,
                transp = Transp,
                local_ip = Ip,
                local_port = Port,
                protocol = Protocol,
                meta = Opts1
            },
            nkpacket_transport:get_listener(NkPort);
        {error, Error} ->
            {error, Error}
    end.


%% @doc Stops a locally started listener
-spec stop_listener(nkport()|pid()) ->
    ok | {error, term()}.

stop_listener(Pid) when is_pid(Pid) ->
    case [Id || {Id, P} <- nkpacket_sup:get_transports(), P==Pid] of
        [Id] ->
            nkpacket_sup:del_transport(Id);
        _ ->
            {error, unknown_listener}
    end;

stop_listener(#nkport{pid=Pid}) ->
    stop_listener(Pid).


%% @doc Stops all locally started listeners
stop_all() ->
    lists:foreach(
        fun(#nkport{pid=Pid}) -> stop_listener(Pid) end,
        get_all()).


%% @doc Stops all locally started listeners for a Domain
stop_all(Domain) ->
    lists:foreach(
        fun(#nkport{pid=Pid}) -> stop_listener(Pid) end,
        get_all(Domain)).


%% @doc Gets the current port of a listener process
-spec get_port(pid()) ->
    inet:port_number().

get_port(Pid) ->
    gen_server:call(Pid, get_port).


%% @doc Sends a message to a connection
-spec send(domain(), send_spec() | [send_spec()], term()) ->
    {ok, nkport()} | {error, term()}.

send(Domain, SendSpec, Msg) ->
    send(Domain, SendSpec, Msg, #{}).


%% @doc Sends a message to a connection
-spec send(domain(), send_spec() | [send_spec()], term(), send_opts()) ->
    {ok, nkport()} | {error, term()}.

send(Domain, SendSpec, Msg, Opts) when is_list(SendSpec), not is_integer(hd(SendSpec)) ->
    case parse_opts(send, Opts) of
        {ok, Opts1} ->
            nkpacket_transport:send(Domain, SendSpec, Msg, Opts1);
        {error, Error} ->
            {error, Error}
    end;

send(Domain, SendSpec, Msg, Opts) ->
    send(Domain, [SendSpec], Msg, Opts).


%% @doc Forces a new outbound connection.
-spec connect(domain(), user_connection() | [connection()], connect_opts()) ->
    {ok, nkport()} | {error, term()}.

connect(Domain, {_, _, _, _}=Conn, Opts) when is_map(Opts) ->
    connect(Domain, [Conn], Opts);

connect(Domain, Conns, Opts) when is_list(Conns), not is_integer(hd(Conns)), 
                                  is_map(Opts) ->
    case parse_opts(connect, Opts) of
        {ok, Opts1} ->
            nkpacket_transport:connect(Domain, Conns, Opts1);
        {error, Error} ->
            {error, Error}
    end;

connect(Domain, Uri, Opts) when is_map(Opts) ->
    case resolve(connect, Domain, Uri) of
        {ok, Conns, UriOpts} ->
            Opts1 = maps:merge(UriOpts, Opts),
            connect(Domain, Conns, Opts1);
        {error, Error} ->
            {error, Error}
    end.



%% @doc Gets all registered transports in all Domains.
-spec get_all() -> 
    [nkport()].

get_all() ->
    lists:sort([NkPort || {NkPort, _Pid} <- nklib_proc:values(nkpacket_transports)]).


%% @doc Gets all registered transports for a Domain.
-spec get_all(domain()) -> 
    [nkport()].

get_all(Domain) ->
    [NkPort || #nkport{domain=D}=NkPort <- get_all(), D==Domain].


%% @private Finds a listening transport of Proto.
-spec get_listening(domain(), protocol(), transport(), ipv4|ipv6) -> 
    [nkport()].

get_listening(Domain, Protocol, Transp, Class) ->
    Fun = fun({#nkport{transp=TTransp, listen_ip=LIp}=T, _}) -> 
        case TTransp==Transp of
            true ->
                case Class of
                    ipv4 when size(LIp)==4 -> {true, T};
                    ipv6 when size(LIp)==8 -> {true, T};
                    _ -> false
                end;
            false ->
                false
        end
    end,
    nklib_util:filtermap(Fun, nklib_proc:values({nkpacket_listen, Domain, Protocol})).



%% @doc Checks if an `uri()' refers to a local started transport.
%% For ws/wss, it does not check the path
-spec is_local(domain(), nklib:uri()) -> 
    boolean().

is_local(Domain, #uri{}=Uri) ->
    case nkpacket_dns:resolve(Domain, Uri) of
        {ok, [{Protocol, _Transp, _Ip, _Port}|_]=Conns} ->
            Listen = [
                {Transp, Ip, Port} ||
                {#nkport{transp=Transp, local_ip=Ip, local_port=Port}, _Pid} 
                <- nklib_proc:values({nkpacket_listen, Domain, Protocol})
            ],
            LocalIps = nkpacket_config_cache:local_ips(),
            is_local(Listen, Conns, LocalIps);
        _ ->
            false
    end.


%% @private
is_local(Listen, [{Protocol, Transp, Ip, 0}|Rest], LocalIps) -> 
    case nkpacket_transport:get_defport(Protocol, Transp) of
        {ok, Port} ->
            is_local(Listen, [{Protocol, Transp, Ip, Port}|Rest], LocalIps);
        error ->
            is_local(Listen, Rest, LocalIps)
    end;
    
is_local(Listen, [{_Protocol, Transp, Ip, Port}|Rest], LocalIps) -> 
    case lists:member(Ip, LocalIps) of
        true ->
            case lists:member({Transp, Ip, Port}, Listen) of
                true ->
                    true;
                false ->
                    case 
                        is_tuple(Ip) andalso size(Ip)==4 andalso
                        lists:member({Transp, {0,0,0,0}, Port}, Listen) 
                    of
                        true -> 
                            true;
                        false -> 
                            case 
                                is_tuple(Ip) andalso size(Ip)==8 andalso
                                lists:member({Transp, {0,0,0,0,0,0,0,0}, Port}, 
                                                Listen) 
                            of
                                true -> true;
                                false -> is_local(Listen, Rest, LocalIps)
                            end
                    end
            end;
        false ->
            is_local(Listen, Rest, LocalIps)
    end;

is_local(_, [], _) ->
    false.


%% @doc Checks if an IP is local to this node.
-spec is_local_ip(inet:ip_address()) -> 
    boolean().

is_local_ip({0,0,0,0}) ->
    true;
is_local_ip({0,0,0,0,0,0,0,0}) ->
    true;
is_local_ip(Ip) ->
    lists:member(Ip, nkpacket_config_cache:local_ips()).




%% ===================================================================
%% Config Parsers
%% ===================================================================


%% @private
-spec resolve(listen|connect|send, domain(), nklib:user_uri()) -> 
    {ok, [raw_connection()], map()} |
    {error, term()}.


resolve(Type, Domain, #uri{path=Path, opts=Opts, headers=Headers}=Uri) ->
    Opts1 = case Path of
        <<>> -> Opts;
        _ -> [{path, Path}|Opts]
    end,
    case parse_opts(Type, Opts1) of
        {ok, Opts2} ->
            Opts3 = case Headers of 
                [] -> Opts2;
                _ -> Opts2#{uri_headers=>Headers}
            end,
            case nkpacket_dns:resolve(Domain, Uri) of
                {ok, Conns} ->
                    {ok, Conns, Opts3};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end;

resolve(Type, Domain, Uri) ->
    case nklib_parse:uris(Uri) of
        [PUri] -> resolve(Type, Domain, PUri);
        _ -> {error, invalid_uri}
    end.


%% @private
parse_opts(Type, Map) when is_map(Map) ->
    parse_opts(Type, maps:to_list(Map), #{});

parse_opts(Type, List) when is_list(List) ->
    parse_opts(Type, List, #{}).


%% @private
parse_opts(_Type,[], Acc) -> 
    {ok, Acc};

parse_opts(Type, [{Key, Val}|Rest], Acc) -> 
    Key1 = if
        is_atom(Key) -> 
            Key;
        is_list(Key) ->
            case catch list_to_existing_atom(Key) of
                Atom when is_atom(Atom) -> Atom;
                _ -> Key
            end;
        is_binary(Key) ->
            case catch binary_to_existing_atom(Key, latin1) of
                Atom when is_atom(Atom) -> Atom;
                _ -> Key
            end;
        true ->
            error
    end,
    Res = case Key1 of
        transport ->
            ignore;
        error ->
            error;

        idle_timeout ->
            parse_integer(Val);
        udp_starts_tcp when Type==listen ->
            parse_boolean(Val);
        udp_no_connections when Type==listen ->
            parse_boolean(Val);
        udp_stun_reply when Type==listen ->
            parse_boolean(Val);
        udp_stun_t1 when Type==listen ->
            parse_integer(Val);
        sctp_out_streams when Type==listen ->
            parse_integer(Val);
        sctp_in_streams when Type==listen ->
            parse_integer(Val);
        certfile ->
            {ok, nklib_util:to_list(Val)};
        keyfile ->
            {ok, nklib_util:to_list(Val)};
        tcp_packet ->
            case nklib_util:to_integer(Val) of
                Int when Int==1; Int==2; Int==4 -> 
                    {ok, Int};
                _ -> 
                    case nklib_util:to_lower(Val) of 
                        <<"raw">> -> {ok, raw}; 
                        _-> error 
                    end
            end;        
        tcp_max_connections when Type==listen ->
            parse_integer(Val);
        tcp_listeners when Type==listen ->
            parse_integer(Val);
        host ->
            parse_text(Val);
        path ->
            parse_text(Val);
        connect_timeout when Type==connect; Type==send ->
            parse_integer(Val);
        listen_ip ->
            unknown;
        listen_port ->
            unknown;
        ws_proto ->
            {ok, nklib_util:to_lower(Val)};
        ws_options ->
            case is_map(Val) of true -> {ok, Val}; false -> error end;
        cowboy_opts ->
            parse_list(Val);
        cowboy_dispatch ->
            parse_list(Val);

        _ ->
            unknown
    end,
    case Res of
        {ok, Val1} -> 
            parse_opts(Type, Rest, maps:put(Key1, Val1, Acc));
        ignore ->
            parse_opts(Type, Rest, Acc);
        unknown ->
            parse_opts(Type, Rest, maps:put(Key, Val, Acc));
        error ->
            {error, {invalid_option, Key}}
    end;

parse_opts(Type, [Term|Rest], Acc) -> 
    parse_opts(Type, [{Term, true}|Rest], Acc).


%% @private
parse_integer(Value) ->
    case nklib_util:to_integer(Value) of
        Int when is_integer(Int), Int > 0 -> {ok, Int};
        _ -> error
    end.


%% @private
parse_boolean(Value) ->
    case nklib_util:to_boolean(Value) of
        Bool when is_boolean(Bool) -> {ok, Bool};
        _ -> error
    end.


%% @private
parse_list(Value) when is_list(Value) -> 
    {ok, Value};
parse_list(_) ->
    error.

%% @private
parse_text(Term) ->
    case nklib_parse:unquote(Term) of
        error -> error;
        Bin -> {ok, Bin}
    end.

    

