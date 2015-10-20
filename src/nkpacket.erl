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

-export([start_listener/2, get_listener/2, stop_listener/1]).
-export([get_all/0, get_all/1, get_groups/0]).
-export([stop_all/0, stop_all/1]).
-export([send/2, send/3, connect/2]).
-export([get_listening/2, get_listening/3, is_local/1, is_local/2, is_local_ip/1]).
-export([pid/1, get_nkport/1, get_local/1, get_remote/1, get_user/1]).
-export([resolve/1, resolve/2, multi_resolve/1, multi_resolve/2]).

-export_type([group/0, transport/0, protocol/0, nkport/0]).
-export_type([listener_opts/0, connect_opts/0, send_opts/0]).
-export_type([connection/0, raw_connection/0, send_spec/0]).
-export_type([http_proto/0, incoming/0, outcoming/0, pre_send_fun/0]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


%% ===================================================================
%% Types
%% ===================================================================

%% Connection Group
%% Listeners and connections can have an associated group.
%% When sending a message, if a previous connection to the same remote
%% and group exists, it will be reused.
%% When starting an outgoing connection, if a suitable listening transport 
%% is found with the same group, some values from listener's metadata will 
%% be copied to the new connection: user, idle_timeout, host, path, ws_proto, 
%% refresh_fun, tcp_packet, tls_opts
-type group() :: term().

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

-type http_proto() ::
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

-type tls_opts() ::
    #{
        certfile => string(),                   % Path to CertFile
        keyfile => string(),                    % Path to KeyFile
        cacertfile => string(),                 % Path to CA CertFile
        password => string(),                   % Password for the certificate
        verify => boolean(),                    % Client must have valid certificate
        depth => 0..2                           % 0:Trusted CA, 1:Peer, CA, Trusted CA
    }.


%% Options for listeners
-type listener_opts() ::
    #{
        % Common options
        group => group(),                       % Connection group
        user => term(),                         % User metadata
        monitor => atom() | pid(),              % Connection will monitor this
        idle_timeout => integer(),              % MSecs, default in config
        refresh_fun => fun((nkport()) -> boolean()),    % Will be called on timeout
        valid_schemes => [nklib:scheme()],       % Fail if not valid protocol (for URIs)

        % UDP options
        udp_starts_tcp => boolean(),            % UDP starts TCP on the same port
        udp_no_connections => boolean(),        % Do not create connections
        udp_stun_reply => boolean(),            % Do STUNs replies
        udp_stun_t1 => integer(),               % msecs, default 500

        % SCTP Opts
        sctp_out_streams => integer(),          % Number of out streams
        sctp_in_streams => integer(),           % Max input streams

        % TCP/TLS/WS/WSS options
        tcp_packet => 1 | 2 | 4 | raw,          %
        tcp_max_connections => integer(),       % Default 1024
        tcp_listeners => integer(),             % Default 100
        tls_opts => tls_opts(),

        % WS/WSS/HTTP/HTTPS options
        host => string() | binary(),            % Listen only on this host
        path => string() | binary(),            % Listen on this path and subpaths
        cowboy_opts => cowboy_opts(),

        % WS/WSS
        ws_proto => string() | binary(),        % Listen only on this protocol
        % ws_opts => map(),                     % See nkpacket_connection_ws
        %                                       % (i.e. #{compress=>true})
        % HTTP/HTTPS
        http_proto => http_proto()
    }.


%% Options for connections
-type connect_opts() ::
    #{
        % Common options
        group => group(),                   % Connection group
        user => term(),                     % User metadata
        monitor => atom() | pid(),          % Connection will monitor this
        connect_timeout => integer(),       % MSecs, default in config
        no_dns_cache => boolean(),          % Avoid DNS cache
        idle_timeout => integer(),          % MSecs, default in config
        refresh_fun => fun((nkport()) -> boolean()),   % Will be called on timeout
        listen_port => none | mandatory | nkport(),  % Select (or disables auto) base NkPort
        valid_schemes => [nklib:scheme()],  % Fail if not valid protocol (for URIs)

        % TCP/TLS/WS/WSS options
        tcp_packet => 1 | 2 | 4 | raw,    
        tls_opts => tls_opts(),  

        % WS/WSS
        host => string() | binary(),        % Host header to use
        path => string() | binary(),        % Path to use
        ws_proto => string() | binary()     % Proto to use
    }.


%% Options for sending
-type send_opts() ::
    connect_opts() |
    #{
        % Specific options
        force_new => boolean(),             % Forces a new connection
        udp_to_tcp => boolean(),            % Change to TCP for large packets
        pre_send_fun => pre_send_fun()
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
    user_connection() | {current, raw_connection()} | {connect, raw_connection()} |
    pid() | nkport().


%% Incoming data to be parsed
-type incoming() ::
    binary() |
    {text, binary()} | {binary, binary()} | pong | {pong, binary} |  %% For WS
    close.


%% Outcoming data ready to be sent
-type outcoming() ::
    iolist() | binary() |
    cow_ws:frame().                 % Only WS


%% See send
-type pre_send_fun() ::
    fun((term(), nkport()) -> term()).


%% ===================================================================
%% Public functions
%% ===================================================================

%% @doc Starts a new listening transport.
-spec start_listener(user_connection(), listener_opts()) ->
    {ok, pid()} | {error, term()}.

start_listener(UserConn, Opts) ->
    case get_listener(UserConn, Opts) of
        {ok, Spec} ->
            nkpacket_sup:add_listener(Spec);
        {error, Error} ->
            {error, Error}
    end.


%% @doc Gets a listening supervisor specification
-spec get_listener(user_connection(), listener_opts()) ->
    {ok, supervisor:child_spec()} | {error, term()}.

get_listener({Protocol, Transp, Ip, Port}, Opts) when is_map(Opts) ->
    case nkpacket_util:parse_opts(Opts) of
        {ok, Opts1} ->
            Opts2 = case Transp==http orelse Transp==https of
                true ->
                    WebProto = nkpacket_util:make_web_proto(Opts1),
                    Opts1#{http_proto=>WebProto};
                _ ->
                    Opts1
            end,
            NkPort = #nkport{
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

get_listener(Uri, Opts) when is_map(Opts) ->
    case resolve(Uri, Opts) of
        {ok, [Conn], Opts1} ->
            get_listener(Conn, Opts1);
        {ok, _, _} ->
            {error, invalid_uri};
        {error, Error} ->
            {error, Error}
    end.



%% @doc Stops a locally started listener (only for standard supervisor)
-spec stop_listener(nkport()|pid()) ->
    ok | {error, term()}.

stop_listener(Pid) when is_pid(Pid) ->
    case [Id || {Id, P} <- nkpacket_sup:get_listeners(), P==Pid] of
        [Id] ->
            nkpacket_sup:del_listener(Id);
        _ ->
            {error, unknown_listener}
    end;

stop_listener(#nkport{pid=Pid}) ->
    stop_listener(Pid).


%% @doc Gets all registered transports in all Groups.
-spec get_all() -> 
    [pid()].

get_all() ->
    [Pid || {_Group, Pid} <- nklib_proc:values(nkpacket_listeners)].


%% @doc Gets all registered transports for a Group.
-spec get_all(group()) -> 
    [pid()].

get_all(Group) ->
    [Pid || {G, Pid} <- nklib_proc:values(nkpacket_listeners), G==Group].


%% @doc Gets all groups having registered listeners
-spec get_groups() -> 
    map().

get_groups() ->
    lists:foldl(
        fun({Group, Pid}, Acc) ->
            maps:put(Group, [Pid|maps:get(Group, Acc, [])], Acc) 
        end,
        #{},
        nklib_proc:values(nkpacket_listeners)).


%% @doc Stops all locally started listeners (only for standard supervisor)
stop_all() ->
    lists:foreach(
        fun(Pid) -> stop_listener(Pid) end,
        get_all()).


%% @doc Stops all locally started listeners for a Group (only for standard supervisor)
stop_all(Group) ->
    lists:foreach(
        fun(Pid) -> stop_listener(Pid) end,
        get_all(Group)).



%% @doc Gets the current pid() of a listener or connection
-spec get_nkport(pid()) ->
    {ok, nkport()} | error.

get_nkport(#nkport{}=NkPort) ->
    {ok, NkPort};
get_nkport(Pid) when is_pid(Pid) ->
    apply_nkport(Pid, fun get_nkport/1).


%% @doc Gets the current port number of a listener or connection
-spec get_local(pid()|nkport()) ->
    {ok, {transport(), inet:ip_address(), inet:port_number()}} | error.

get_local(#nkport{transp=Transp, local_ip=Ip, local_port=Port}) ->
    {ok, {Transp, Ip, Port}};
get_local(Pid) when is_pid(Pid) ->
    apply_nkport(Pid, fun get_local/1).


%% @doc Gets the current remote peer address and port
-spec get_remote(pid()|nkport()) ->
    {ok, {transport(), inet:ip_address(), inet:port_number()}} | error.

get_remote(#nkport{transp=Transp, remote_ip=Ip, remote_port=Port}) ->
    {ok, {Transp, Ip, Port}};
get_remote(Pid) when is_pid(Pid) ->
    apply_nkport(Pid, fun get_remote/1).


%% @doc Gets the user metadata of a listener or connection
-spec get_user(pid()|nkport()) ->
    {ok, term()} | error.

get_user(#nkport{meta=Meta}) ->
    {ok, maps:get(user, Meta, undefined)};
get_user(Pid) when is_pid(Pid) ->
    apply_nkport(Pid, fun get_user/1).


%% @doc Gets the current pid() of a listener or connection
-spec pid(pid()|nkport()) ->
    pid().

pid(Pid) when is_pid(Pid) ->
    Pid;
pid(#nkport{pid=Pid}) ->
    Pid.


%% @doc Sends a message to a connection.
-spec send(send_spec() | [send_spec()], term()) ->
    {ok, pid()} | {error, term()}.

send(SendSpec, Msg) ->
    send(SendSpec, Msg, #{}).


%% @doc Sends a message to a connection
%% If a group is included, it will try to reuse any existing connection of the same group
%% (except if force_new option is set)
-spec send(send_spec() | [send_spec()], term(), send_opts()) ->
    {ok, pid()} | {error, term()}.

send(SendSpec, Msg, Opts) when is_list(SendSpec), not is_integer(hd(SendSpec)) ->
    case nkpacket_util:parse_opts(Opts) of
        {ok, Opts1} ->
            case nkpacket_transport:send(SendSpec, Msg, Opts1) of
                {ok, {Pid, _Msg1}} -> {ok, Pid};
                {error, Error} -> {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end;

send(SendSpec, Msg, Opts) ->
    send([SendSpec], Msg, Opts).


%% @doc Forces a new outbound connection.
-spec connect(user_connection() | [connection()], connect_opts()) ->
    {ok, pid()} | {error, term()}.

connect({_, _, _, _}=Conn, Opts) when is_map(Opts) ->
    connect([Conn], Opts);

connect(Conns, Opts) when is_list(Conns), not is_integer(hd(Conns)), is_map(Opts) ->
    case nkpacket_util:parse_opts(Opts) of
        {ok, Opts1} ->
            nkpacket_transport:connect(Conns, Opts1);
        {error, Error} ->
            {error, Error}
    end;

connect(Uri, Opts) when is_map(Opts) ->
    case resolve(Uri, Opts) of
        {ok, Conns, Opts1} ->
            connect(Conns, Opts1);
        {error, Error} ->
            {error, Error}
    end.


%% @private Finds a listening transport of Proto.
-spec get_listening(protocol(), transport()) -> 
    [nkport()].

get_listening(Protocol, Transp) ->
    get_listening(Protocol, Transp, #{}).


%% @private Finds a listening transport of Proto.
-spec get_listening(protocol(), transport(), #{group=>group()}) -> 
    [nkport()].

get_listening(Protocol, Transp, Opts) ->
    Group = maps:get(group, Opts, none),
    [
        NkPort || 
        {NkPort, _Pid} 
            <- nklib_proc:values({nkpacket_listen, Group, Protocol, Transp})
    ].


%% @doc Checks if an `uri()' refers to a local started transport.
%% For ws/wss, it does not check the path
-spec is_local(nklib:uri()) -> 
    boolean().

is_local(Uri) ->
    is_local(Uri, #{}).


%% @doc Checks if an `uri()' refers to a local started transport.
%% For ws/wss, it does not check the path
-spec is_local(nklib:uri(), #{group=>group(), no_dns_cache=>boolean()}) -> 
    boolean().

is_local(#uri{}=Uri, Opts) ->
    case resolve(Uri, Opts) of
        {ok, [{Protocol, Transp, _Ip, _Port}|_]=Conns, _Opts1} ->
            Listen = [
                {Transp, Ip, Port} ||
                #nkport{local_ip=Ip, local_port=Port}
                    <- get_listening(Protocol, Transp, Opts)
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
-spec resolve(nklib:user_uri()) -> 
    {ok, [raw_connection()], map()} |
    {error, term()}.

resolve(Uri) ->
    resolve(Uri, #{}).


%% @private
-spec resolve(nklib:user_uri(), map()) -> 
    {ok, [raw_connection()], map()} |
    {error, term()}.

resolve(#uri{scheme=Scheme}=Uri, Opts) ->
    #uri{domain=Host, path=Path, ext_opts=UriOpts, ext_headers=Headers} = Uri,
    UriOpts1 = [{nklib_parse:unquote(K), nklib_parse:unquote(V)} || {K, V} <- UriOpts],
    UriOpts2 = case Host of
        <<"0.0.0.0">> -> UriOpts1;
        <<"0:0:0:0:0:0:0:0">> -> UriOpts1;
        <<"::0">> -> UriOpts1;
        <<"all">> -> UriOpts1;
        _ -> [{host, Host}|UriOpts1]            % Host to listen on for WS/HTTP
    end,
    UriOpts3 = case Path of
        <<>> -> UriOpts2;
        _ -> [{path, Path}|UriOpts2]            % Path to listen on for WS/HTTP
    end,
    UriOpts4 = case Headers of 
        [] -> UriOpts3;
        _ -> [{user, Headers}|UriOpts3]
    end,
    try
        case nkpacket_util:parse_opts(UriOpts4 ++ maps:to_list(Opts)) of
            {ok, Opts1} -> 
                case Opts1 of
                    #{valid_schemes:=ValidSchemes} ->
                        case lists:member(Scheme, ValidSchemes) of
                            true -> ok;
                            false -> throw({invalid_scheme, Scheme})
                        end;
                    _ ->
                        ok
                end,
                Protocol = case Opts1 of
                    #{group:=Group} -> 
                        nkpacket_config:get_protocol(Group, Scheme);
                    _ -> 
                        nkpacket_config:get_protocol(Scheme)
                end,
                case nkpacket_dns:resolve(Uri, Opts1#{protocol=>Protocol}) of
                    {ok, Addrs} ->
                        Conns = [ 
                            {Protocol, Transp, Addr, Port} 
                            || {Transp, Addr, Port} <- Addrs
                        ],
                        {ok, Conns, Opts1};
                    {error, Error} ->
                        {error, Error}
                end;
            {error, Error} -> 
                {error, Error}
        end
    catch
        throw:Throw -> {error, Throw}
    end;

resolve(Uri, Opts) ->
    case nklib_parse:uris(Uri) of
        [Parsed] ->
            resolve(Parsed, Opts);
        _ ->
            {error, {invalid_uri, Uri}}
    end.


%% @private
-spec multi_resolve(nklib:user_uri()|[nklib:user_uri()]) -> 
    {ok, [{[raw_connection()], map()}]} |
    {error, term()}.

multi_resolve(Uri) ->
    multi_resolve(Uri, #{}).


%% @private
-spec multi_resolve(nklib:user_uri()|[nklib:user_uri()], map()) -> 
    {ok, [raw_connection()], map()} |
    {error, term()}.
   
multi_resolve([], _Opts) ->
    {ok, []};

multi_resolve(List, Opts) when is_list(List), not is_integer(hd(List)) ->
    multi_resolve(List, Opts, []);

multi_resolve(Other, Opts) ->
    multi_resolve([Other], Opts).


%% @private
multi_resolve([], _Opts, Acc) ->
    {ok, lists:reverse(Acc)};

multi_resolve([#uri{}=Uri|Rest], Opts, Acc) ->
    case resolve(Uri, Opts) of
        {ok, Conns, Opts1} ->
            multi_resolve(Rest, Opts, [{Conns, Opts1}|Acc]);
        {error, Error} ->
            {error, Error}
    end;

multi_resolve([Uri|Rest], Opts, Acc) ->
    case nklib_parse:uris(Uri) of
        error ->
            {error, {invalid_uri, Uri}};
        Parsed ->
            multi_resolve(Parsed++Rest, Opts, Acc)
    end.


%% @private
-spec apply_nkport(pid(), fun((nkport()) -> {ok, term()}))  ->
    term() | error.

apply_nkport(Pid, Fun) when is_pid(Pid) ->
    case catch gen_server:call(Pid, {nkpacket_apply_nkport, Fun}, 180000) of
        {'EXIT', _} -> error;
        Other -> Other
    end.

