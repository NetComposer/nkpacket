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
%% TODO: 
%% - WS Client Compression
%% - Simplify HTTP/WS listeners not using Cowboy's process but only cowlib?


-module(nkpacket).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_listener/3, stop_listener/1, stop_all/0, stop_all/1]).
-export([get_listener/3]).
-export([send/3, send/4, connect/3]).
-export([get_all/0, get_all/1, get_listening/4, is_local/2, is_local_ip/1]).
-export([get_nkport/1, get_local/1, get_remote/1, get_pid/1, get_user/1]).
-export([resolve/2]).

-export_type([domain/0, transport/0, protocol/0, nkport/0]).
-export_type([listener_opts/0, connect_opts/0, send_opts/0]).
-export_type([connection/0, raw_connection/0, send_spec/0]).
-export_type([incoming/0, outcoming/0]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


%% ===================================================================
%% Types
%% ===================================================================

%% Internal name of each started Domain
-type domain() :: term().

%% Recognized transport schemes
-type transport() :: udp | tcp | tls | sctp | ws | wss | http | https.

%% A protocol is a module implementing nkpacket_protocol behaviour
-type protocol() :: module().

%% An opened port (listener or connection)
-type nkport() :: #nkport{}.


-type cowboy_opts() :: 
    [
        {max_empty_lines, non_neg_integer()} | 
        {max_header_name_length, non_neg_integer()} | 
        {max_header_value_length, non_neg_integer()} | 
        {max_headers, non_neg_integer()} | 
        {max_keepalive, non_neg_integer()} | 
        {max_request_line_length, non_neg_integer()} | 
        {onresponse, cowboy:onresponse_fun()}
    ].

-type web_proto() ::
    {static, 
        nkpacket_cowboy_static:opts()} |
    {dispatch, 
        #{
            routes => cowboy_router:routes()
        }} |
    {custom, 
        #{
            env => cowboy_middleware:env(),
            middlewares => [module()]
        }}.


%% Options for listeners
-type listener_opts() ::
    #{
        % Common options
        user => term(),                         % User metadata
        monitor => atom() | pid(),              % Connection will monitor this
        idle_timeout => integer(),              % MSecs, default in config
        refresh_fun => fun((nkport()) -> boolean()),    % Will be called on timeout
        
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
        tcp_max_connections => integer(),       % Default 1024
        tcp_listeners => integer(),             % Default 100

        % WS/WSS/HTTP/HTTPS options
        host => string() | binary(),            % Hosts to filter (comma separated)
        path => string() | binary(),            % Paths to filter (comma separated)
        cowboy_opts => cowboy_opts(),

        % WS/WSS
        ws_proto => string() | binary(),        % Websocket Subprotocol
        % ws_opts => map(),                     % See nkpacket_connection_ws
        %                                       % (i.e. #{compress=>true})
        % HTTP/HTTPS
        web_proto => web_proto()
    }.


%% Options for connections
-type connect_opts() ::
    #{
        % Common options
        user => term(),                     % User metadata
        monitor => atom() | pid(),          % Connection will monitor this
        connect_timeout => integer(),       % MSecs, default in config
        idle_timeout => integer(),          % MSecs, default in config
        refresh_fun => fun((nkport()) -> boolean()),    % Will be called on timeout
        listen_ip => inet:ip_address(),     % Used to populate nkport, forcing it instead
        listen_port => inet:port_number(),  % of finding suitable listening transport

        % TCP/TLS/WS/WSS options
        certfile => string(),           
        keyfile => string(),                 
        tcp_packet => 1 | 2 | 4 | raw,      

        % WS/WSS
        host => string() | binary(),
        path => string() | binary(),
        ws_proto => string() | binary()
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


%% Incoming data to be parsed
-type incoming() ::
    binary() |
    {text, binary()} | {binary, binary()} | pong | {pong, binary} |  %% For WS
    close.


%% Outcoming data ready to be sent
-type outcoming() ::
    iolist() | binary() |
    cow_ws:frame().                 % Only WS


%% ===================================================================
%% Public functions
%% ===================================================================

%% @doc Starts a new listening transport.
-spec start_listener(domain(), user_connection(), listener_opts()) ->
    {ok, pid()} | {error, term()}.

start_listener(Domain, UserConn, Opts) ->
    case get_listener(Domain, UserConn, Opts) of
        {ok, Spec} ->
            nkpacket_sup:add_listener(Spec);
        {error, Error} ->
            {error, Error}
    end.


%% @doc Gets a listening supervisor specification
-spec get_listener(domain(), user_connection(), listener_opts()) ->
    {ok, supervisor:child_spec()} | {error, term()}.

get_listener(Domain, {Protocol, Transp, Ip, Port}, Opts) when is_map(Opts) ->
    case nkpacket_util:parse_opts(Opts) of
        {ok, Opts1} ->
            Opts2 = case Transp==http orelse Transp==https of
                true ->
                    WebProto = make_web_proto(Opts1),
                    Opts1#{web_proto=>WebProto};
                _ ->
                    Opts1
            end,
            NkPort = #nkport{
                domain = Domain,
                transp = Transp,
                local_ip = Ip,
                local_port = Port,
                protocol = Protocol,
                meta = Opts2
            },
            nkpacket_transport:get_listener(NkPort);
        {error, Error} ->
            {error, Error}
    end;

get_listener(Domain, Uri, Opts) when is_map(Opts) ->
    case resolve(Domain, Uri) of
        {ok, [Conn], UriOpts} ->
            get_listener(Domain, Conn, maps:merge(UriOpts, Opts));
        {ok, _, _} ->
            {error, invalid_uri};
        {error, Error} ->
            {error, Error}
    end.



%% @doc Stops a locally started listener (only for standard supervisor)
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


%% @doc Stops all locally started listeners (only for standard supervisor)
stop_all() ->
    lists:foreach(
        fun(#nkport{pid=Pid}) -> stop_listener(Pid) end,
        get_all()).


%% @doc Stops all locally started listeners for a Domain (only for standard supervisor)
stop_all(Domain) ->
    lists:foreach(
        fun(#nkport{pid=Pid}) -> stop_listener(Pid) end,
        get_all(Domain)).


%% @doc Gets the current pid() of a listener or connection
-spec get_nkport(pid()) ->
    {ok, nkport()} | error.

get_nkport(Pid) when is_pid(Pid) ->
    case catch gen_server:call(Pid, get_nkport, ?CALL_TIMEOUT) of
        {ok, NkPort} -> {ok, NkPort};
        _ -> error
    end.


%% @doc Gets the current port number of a listener or connection
-spec get_local(pid()|nkport()) ->
    {ok, {transport(), inet:ip_address(), inet:port_number()}} | error.

get_local(#nkport{transp=Transp, local_ip=Ip, local_port=Port}) ->
    {ok, {Transp, Ip, Port}};
get_local(Pid) when is_pid(Pid) ->
    case catch gen_server:call(Pid, get_local, ?CALL_TIMEOUT) of
        {ok, Info} -> {ok, Info};
        _ -> error
    end.


%% @doc Gets the current remote peer address and port
-spec get_remote(pid()|nkport()) ->
    {ok, {transport(), inet:address(), inet:port_number()}} | error.

get_remote(#nkport{transp=Transp, remote_ip=Ip, remote_port=Port}) ->
    {ok, {Transp, Ip, Port}};
get_remote(Pid) when is_pid(Pid) ->
    case catch gen_server:call(Pid, get_remote, ?CALL_TIMEOUT) of
        {ok, Info} -> {ok, Info};
        _ -> error
    end.


%% @doc Gets the current pid() of a listener or connection
-spec get_pid(nkport()) ->
    pid().

get_pid(#nkport{pid=Pid}) ->
    Pid.


%% @doc Gets the user metadata of a listener or connection
-spec get_user(pid()|nkport()) ->
    {ok, term()} | error.

get_user(#nkport{meta=#{user:=User}}) ->
    {ok, User};
get_user(#nkport{}) ->
    {ok, undefined};
get_user(Pid) when is_pid(Pid) ->
    case catch gen_server:call(Pid, get_user, ?CALL_TIMEOUT) of
        {ok, User} -> {ok, User};
        _ -> error
    end.


%% @doc Sends a message to a connection
-spec send(domain(), send_spec() | [send_spec()], term()) ->
    {ok, nkport()} | {error, term()}.

send(Domain, SendSpec, Msg) ->
    send(Domain, SendSpec, Msg, #{}).


%% @doc Sends a message to a connection
-spec send(domain(), send_spec() | [send_spec()], term(), send_opts()) ->
    {ok, nkport()} | {error, term()}.

send(Domain, SendSpec, Msg, Opts) when is_list(SendSpec), not is_integer(hd(SendSpec)) ->
    case nkpacket_util:parse_opts(Opts) of
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
    case nkpacket_util:parse_opts(Opts) of
        {ok, Opts1} ->
            nkpacket_transport:connect(Domain, Conns, Opts1);
        {error, Error} ->
            {error, Error}
    end;

connect(Domain, Uri, Opts) when is_map(Opts) ->
    case resolve(Domain, Uri) of
        {ok, Conns, UriOpts} ->
            connect(Domain, Conns, maps:merge(UriOpts, Opts));
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
    Fun = fun({#nkport{listen_ip=LIp}=T, _}) -> 
        case Class of
            ipv4 when size(LIp)==4 -> {true, T};
            ipv6 when size(LIp)==8 -> {true, T};
            _ -> false
        end
    end,
    nklib_util:filtermap(
        Fun, 
        nklib_proc:values({nkpacket_listen, Domain, Protocol, Transp})).



%% @doc Checks if an `uri()' refers to a local started transport.
%% For ws/wss, it does not check the path
-spec is_local(domain(), nklib:uri()) -> 
    boolean().

is_local(Domain, #uri{}=Uri) ->
    case nkpacket_dns:resolve(Domain, Uri) of
        {ok, [{Protocol, Transp, _Ip, _Port}|_]=Conns} ->
            Listen = [
                {Transp, Ip, Port} ||
                {#nkport{local_ip=Ip, local_port=Port}, _Pid} 
                <- nklib_proc:values({nkpacket_listen, Domain, Protocol, Transp})
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
%% Internal
%% ===================================================================


%% @private
-spec resolve(domain(), nklib:user_uri()) -> 
    {ok, [raw_connection()], map()} |
    {error, term()}.


resolve(Domain, #uri{path=Path, ext_opts=Opts, ext_headers=Headers}=Uri) ->
    Opts1 = maps:from_list(Opts),
    Opts2 = case Path of
        <<>> -> Opts1;
        _ -> Opts1#{path=>Path}
    end,
    Opts3 = case Headers of 
        [] -> Opts2;
        _ -> Opts2#{user=>Headers}
    end,
    case nkpacket_dns:resolve(Domain, Uri) of
        {ok, Conns} ->
            {ok, Conns, Opts3};
        {error, Error} ->
            {error, Error}
    end;

resolve(Domain, Uri) ->
    case nklib_parse:uris(Uri) of
        [PUri] -> resolve(Domain, PUri);
        _ -> {error, invalid_uri}
    end.


%% @private
-spec make_web_proto(listener_opts()) ->
    web_proto().

make_web_proto(#{web_proto:={static, #{path:=_}=Static}}=Opts) ->
    PathList = maps:get(path_list, Opts, [<<>>]),
    Routes1 = [
        [
            {<<Path/binary, "/[...]">>, nkpacket_cowboy_static, Static}
        ]
        || Path <- PathList
    ],
    Routes2 = lists:flatten(Routes1),
    % lager:warning("Routes2: ~p", [Routes2]),
    {custom, 
        #{
            env => [{dispatch, cowboy_router:compile([{'_', Routes2}])}],
            middlewares => [cowboy_router, cowboy_handler]
        }};

make_web_proto(#{web_proto:={dispatch, #{routes:=Routes}}}) ->
    {custom, 
        #{
            env => [{dispatch, cowboy_router:compile(Routes)}],
            middlewares => [cowboy_router, cowboy_handler]
        }};

make_web_proto(#{web_proto:={custom, #{env:=Env, middlewares:=Mods}}=Proto})
    when is_list(Env), is_list(Mods) ->
    Proto.
