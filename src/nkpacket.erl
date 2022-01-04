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

%% @doc Main management module.
%% TODO: 
%% - WS Client Compression
%% - Simplify HTTP/WS listeners not using Cowboy's process but only cowlib?


-module(nkpacket).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([register_protocol/2, register_protocol/3]).
-export([get_protocol/1, get_protocol/2]).
-export([start_listener/1, start_listener/2, get_listener/1, get_listener/2, stop_listeners/1]).
-export([connect/1, connect/2]).
-export([get_all/0, get_class_ids/1, get_classes/0]).
-export([stop_all/0, stop_all/1]).
-export([get_id_pids/1, send/2, send/3]).
-export([get_listening/2, get_listening/3, is_local/1, is_local/2, is_local_ip/1]).
-export([get_nkport/1, get_local/1, get_remote/1, get_remote_bin/1, get_local_bin/1,
         get_external_url/1, get_debug/1, get_opts/1]).
-export([get_class/1, get_id/1, get_user_state/1]).

-export_type([id/0, class/0, transport/0, protocol/0, nkport/0, nkconn/0]).
-export_type([listen_opts/0, connect_opts/0, send_opts/0, resolve_opts/0]).
-export_type([connect_spec/0, send_spec/0]).
-export_type([incoming/0, outcoming/0]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


%% ===================================================================
%% Types
%% ===================================================================

%% Each listener and connection will have an id
%% If none is used in opts, a random binary will be generated
%% You can later refer to the listener or connection by id, pid or nkport()
-type id() :: term().

%% Listeners and connections have an associated class.
%% When sending a message, if a previous connection to the same remote
%% and class exists, it will be reused.
%% When starting an outgoing connection, if a suitable listening transport 
%% is found with the same class, some values from listener's metadata will 
%% be copied to the new connection: user_state, idle_timeout, host, path, ws_proto,
%% refresh_fun, tcp_packet, tls_opts
-type class() :: term().

%% Recognized transport schemes
-type transport() :: udp | tcp | tls | sctp | ws | wss | http | https.

%% A protocol is a module implementing nkpacket_protocol behaviour
-type protocol() :: module().

%% An opened port (listener or connection)
-type nkport() :: #nkport{}.


%% Raw connection specification
-type nkconn() :: #nkconn{}.


%% Options for listeners
%% - external_url: If defined (for example http://host:port/path)
%%   will be included in nkport
%%   If not defined, for http/s transports, nkpacket will generate it
-type listen_opts() ::
    #{
        % Common options
        id => id(),                             % See above
        class => class(),                       % Class (see above)
        user_state => term(),                   % Initial user state
        protocol => protocol(),                 % If not supplied, scheme must be registered
        parse_syntax => map(),                  % Allows to update the syntax. See bellow
        monitor => atom() | pid(),              % Connection will monitor this
        idle_timeout => integer(),              % MSecs, default in config
        debug => boolean(),

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
        send_timeout => integer(),
        send_timeout_close => boolean(),
        tos => integer(),

        % WS/WSS/HTTP/HTTPS options
        host => string() | binary(),            % Listen only on this host
        path => string() | binary(),            % Listen on this path and subpaths
        get_headers => boolean() | [binary()],  % Get all headers or some
        external_url => binary(),               % See above
        http_inactivity_timeout => non_neg_integer(),    % msecs
        http_max_empty_lines => non_neg_integer(),
        http_max_header_name_length => non_neg_integer(),
        http_max_header_value_length => non_neg_integer(),
        http_max_headers => non_neg_integer(),
        http_max_keepalive => non_neg_integer(),
        http_max_method_length => non_neg_integer(),
        http_max_request_line_length => non_neg_integer(),
        http_request_timeout => timeout(),

        % WS/WSS
        ws_proto => string() | binary()         % Listen only on this protocol
        % ws_opts => map(),                     % See nkpacket_connection_ws
                                                % (i.e. #{compress=>true})
    }
    | tls_types().


%% NOTES
%% -----
%%
%% - Each listener must follow a protocol() (see nkpacket_protocol)
%%   If not supplied, it will be guessed from the scheme if it has been registered
%%
%% - if you use parse_syntax, that syntax will be added to nkpacket_syntax:syntax() when
%%   parsing these options (to add new options)


%% Options for connections
-type connect_opts() ::
    #{
        % Common options
        id => id(),                         % See above
        class => class(),                   % Class (see above)
        user_state => term(),               % Initial user state
        protocol => protocol(),             % If not supplied, scheme must be registered
        parse_syntax => map(),              % Allows to update the syntax. See above.
        monitor => atom() | pid(),          % Connection will monitor this
        connect_timeout => integer(),       % MSecs, default in config
        no_dns_cache => boolean(),          % Avoid DNS cache
        idle_timeout => integer(),          % MSecs, default in config
        refresh_fun => fun((nkport()) -> boolean()),   % Will be called on timeout
        base_nkport => boolean()| nkport(), % Select (or disables auto) base NkPort
        debug => boolean(),

        % TCP/TLS/WS/WSS options
        tcp_packet => 1 | 2 | 4 | raw,    
        send_timeout => integer(),
        send_timeout_close => boolean(),
        tos => integer(),

        % WS/WSS
        host => string() | binary(),        % Host header to use
        path => string() | binary(),        % Path to use
        ws_proto => string() | binary(),    % Proto to use
        headers => [{string()|binary(), string()|binary()}]
    }
    | tls_types().


-type tls_types() ::
    #{
        tls_verify => host | boolean(),
        tls_certfile => string(),
        tls_keyfile => string(),
        tls_cacertfile => string(),
        tls_password => string(),
        tls_depth => 0..16,
        tls_versions => [atom()]
    }.



%% Options for sending
-type send_opts() ::
    connect_opts() |
    #{
        % Specific options
        force_new => boolean(),             % Forces a new connection
        udp_to_tcp => boolean(),            % Change to TCP for large packets
        udp_max_size => pos_integer()       % Used only for this sent request
    }.

-type user_state() :: term().


%% Options for resolving
-type resolve_opts() ::
    #{
        resolve_type =>
            listen |                    % Do not attempt SRV or NAPTR to resolve host
            connect |                   % Try SRV/NAPTR if port=0
            send                        % Allowed special send constructs
    }
    | listen_opts()
    | send_opts().


%% Connection specification
-type connect_spec() ::
    nklib:user_uri() | nklib:uri() | nkconn().


%% Sending remote specification options
-type send_spec() ::
    connect_spec() | {current, nkconn()} | {connect, nkconn()} | pid().


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


%% @doc Registers a new 'default' protocol (using 'none' domain)
%% Protocols are used only in resolve/2
%% If one is registered, you can use scheme://... and the corresponding protocol will be used
%% If you use register_protocol/3, with a class, 'class' option will be used when calling resolve/2
-spec register_protocol(nklib:scheme(), nkpacket:protocol()) ->
    ok.

register_protocol(Scheme, Protocol) when is_atom(Scheme), is_atom(Protocol) ->
    {module, _} = code:ensure_loaded(Protocol),
    nklib_config:put(nkpacket, {protocol, Scheme}, Protocol).


%% @doc Registers a new protocol for an specific class (using it as domain)
-spec register_protocol(class(), nklib:scheme(), protocol()) ->
    ok.

register_protocol(Class, Scheme, Protocol) when is_atom(Scheme), is_atom(Protocol) ->
    {module, _} = code:ensure_loaded(Protocol),
    nklib_config:put_domain(nkpacket, Class, {protocol, Scheme}, Protocol).


%% @doc
get_protocol(Scheme) -> 
    nkpacket_app:get({protocol, Scheme}).


%% @doc
get_protocol(Class, Scheme) -> 
    nkpacket_app:get_srv(Class, {protocol, Scheme}).


%% @doc Starts a new listening transport.
-spec start_listener(connect_spec()) ->
    {ok, id(), pid()} | {error, term()}.

start_listener(Conn) ->
    start_listener(Conn, #{}).


%% @doc Starts a new listening transport.
-spec start_listener(connect_spec(), listen_opts()) ->
    {ok, id(), pid()} | {error, term()}.

start_listener(Conn, Opts) ->
    case get_listener(Conn, Opts) of
        {ok, Id, Spec} ->
            nkpacket_sup:add_listener(Id, Spec);
        {error, Error} ->
            {error, Error}

    end.


%% @doc
-spec get_listener(connect_spec()) ->
    {ok, id(), supervisor:child_spec()} | {error, term()}.

get_listener(Conn) ->
    get_listener(Conn, #{}).


%% @doc Gets a listening supervisor specification
-spec get_listener(connect_spec(), listen_opts()) ->
    {ok, id(), supervisor:child_spec()} | {error, term()}.

get_listener(Conn, Opts) ->
    case nkpacket_resolve:resolve(Conn, Opts) of
        {ok, [#nkconn{protocol=Protocol, transp=Transp, ip=Ip, port=Port, opts=#{id:=Id}=Opts2}]} ->
            NkPort = #nkport{
                id = maps:get(id, Opts2),
                class = maps:get(class, Opts2, none),
                protocol = Protocol,
                transp = Transp,
                listen_ip = Ip,
                listen_port = Port,
                opts = maps:without([id, class, user_state], Opts2),
                user_state = maps:get(user_state, Opts2, undefined)
            },
            case nkpacket_transport:get_listener(NkPort) of
                {ok, Listener} ->
                    {ok, Id, Listener};
                {error, Error} ->
                    {error, Error}
            end;
        {ok, []} ->
            {error, no_listener};
        {ok, _} ->
            {error, multiple_listeners};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Stops a locally started listener (only for standard supervisor)
-spec stop_listeners(id()|pid()|nkport()) ->
    ok.

stop_listeners(Id) ->
    lists:foreach(
        fun(Pid) -> nklib_util:call(Pid, nkpacket_stop, 30000) end,
        get_id_pids(Id)).


%% @doc Sends a message to a connection.
-spec send(send_spec() | [send_spec()], term()) ->
    {ok, pid()} | {error, term()}.

send(SendSpec, Msg) ->
    send(SendSpec, Msg, #{}).


%% @doc Sends a message to a connection
%% If a class is included, it will try to reuse any existing connection of the same class
%% (except if force_new option is set)
%% If Msg is a function, it will be called as Msg(NkPort) and the resulting message
%% will be returned
-spec send(send_spec() | [send_spec()], term(), send_opts()) ->
    {ok, pid()} | {ok, pid(), term()} | {error, term()}.

send(SendSpec, Msg, Opts) ->
    case nkpacket_resolve:resolve(SendSpec, Opts#{resolve_type=>send}) of
        {ok, Conns} ->
            case Opts of
                #{debug:=true} ->
                    put(nkpacket_debug, true);
                _ ->
                    ok
            end,
            nkpacket_transport:send(Conns, Msg);
        {error, Error} ->
            {error, Error}
    end.


%% @doc Forces a new outbound connection.
-spec connect(connect_spec()|[connect_spec()]) ->
    {ok, pid()} | {error, term()}.

connect(Any) ->
    connect(Any, #{}).


%% @doc Forces a new outbound connection.
-spec connect(connect_spec()|[connect_spec()], connect_opts()) ->
    {ok, #nkport{}} | {error, term()}.

connect(Conn, Opts) ->
    case nkpacket_resolve:resolve(Conn, Opts) of
        {ok, SendSpecs} ->
            nkpacket_transport:connect(SendSpecs);
        {error, Error} ->
            {error, Error}
    end.


%% @doc Gets the current pids for a listener or connection
-spec get_id_pids(id()|nkport()|pid()) ->
    [pid()].

get_id_pids(#nkport{pid=Pid}) ->
    [Pid];

get_id_pids(Pid) when is_pid(Pid) ->
    [Pid];

get_id_pids(Id) ->
    [Pid || {_Class, Pid} <- nklib_proc:values({nkpacket_id, Id})].



%% @doc Gets all registered transports
-spec get_all() -> 
    [{id(), class(), pid()}].

get_all() ->
    [{Id, Class, Pid} || {{Id, Class}, Pid} <- nklib_proc:values(nkpacket_listeners)].


%% @doc Gets all registered transports for a class.
-spec get_class_ids(class()) ->
    [pid()].

get_class_ids(Class) ->
    [Id || {Id, C, _Pid} <- get_all(), C==Class].


%% @doc Gets all classes having registered listeners
-spec get_classes() ->
    #{class() => [id()]}.

get_classes() ->
    lists:foldl(
        fun({Id, Class, _Pid}, Acc) ->
            maps:put(Class, [Id|maps:get(Class, Acc, [])], Acc) 
        end,
        #{},
        get_all()).



%% @doc Stops all locally started listeners (only for standard supervisor)
stop_all() ->
    lists:foreach(
        fun({_Id, _Class, Pid}) -> stop_listeners(Pid) end,
        get_all()).


%% @doc Stops all locally started listeners for a class (only for standard supervisor)
stop_all(Class) ->
    lists:foreach(
        fun(Pid) -> stop_listeners(Pid) end,
        get_class_ids(Class)).



%% @doc Gets the current nkport of a listener or connection
-spec get_nkport(id()|pid()|nkport()) ->
    {ok, nkport()} | {error, term()}.

get_nkport(#nkport{}=NkPort) ->
    {ok, NkPort};
get_nkport(Id) ->
    apply_nkport(Id, fun get_nkport/1).


%% @doc Gets the current port number of a listener or connection
-spec get_local(id()|pid()|nkport()) ->
    {ok, {protocol(), transport(), inet:ip_address(), inet:port_number()}} |
    {error, term()}.

get_local(#nkport{protocol=Proto, transp=Transp, local_ip=Ip, local_port=Port}) ->
    {ok, {Proto, Transp, Ip, Port}};
get_local(Id) ->
    apply_nkport(Id, fun get_local/1).


%% @doc Gets the current remote peer address and port
-spec get_remote(id()|pid()|nkport()) ->
    {ok, {protocol(), transport(), inet:ip_address(), inet:port_number()}} |
    {error, term()}.

get_remote(#nkport{protocol=Proto, transp=Transp, remote_ip=Ip, remote_port=Port}) ->
    {ok, {Proto, Transp, Ip, Port}};

get_remote(Id) ->
    apply_nkport(Id, fun get_remote/1).


%% @doc Gets the current remote peer address and port
-spec get_remote_bin(id()|pid()|nkport()) ->
    {ok, binary()} | error.

get_remote_bin(Term) ->
    case get_remote(Term) of
        {ok, {_Proto, Transp, Ip, Port}} ->
            {ok, nkpacket_util:conn_string(Transp, Ip, Port)};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Gets the current local peer address and port
-spec get_local_bin(id()|pid()|nkport()) ->
    {ok, binary()} | error.

get_local_bin(Term) ->
    case get_local(Term) of
        {ok, {_Proto, Transp, Ip, Port}} ->
            {ok, nkpacket_util:conn_string(Transp, Ip, Port)};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec get_class(id()|pid()|nkport()) ->
    {ok, class()} | {error, term()}.

get_class(#nkport{class=Class}) ->
    {ok, Class};
get_class(Id) ->
    apply_nkport(Id, fun get_class/1).


%% @doc
-spec get_id(id()|pid()|nkport()) ->
    {ok, class(), id()} | error.

get_id(#nkport{id=Id, class=Class}) ->
    {ok, Class, Id};
get_id(Id) ->
    apply_nkport(Id, fun get_id/1).


%% @doc
-spec get_opts(id()|pid()|nkport()) ->
    {ok, Opts :: nkpacket:listen_opts() | nkpacket:send_opts()} | {error, term()}.

get_opts(#nkport{opts=Opts}) ->
    {ok, Opts};
get_opts(Id) ->
    apply_nkport(Id, fun get_opts/1).


%% @doc
-spec get_user_state(id()|pid()|nkport()) ->
    {ok, user_state()} | {error, term()}.

get_user_state(#nkport{user_state=UserState}) ->
    {ok, UserState};
get_user_state(Id) ->
    apply_nkport(Id, fun get_user_state/1).


%% @doc
-spec get_external_url(nkport()) ->
    {ok, binary()|undefined} | {error, term()}.

get_external_url(#nkport{opts=Opts}) ->
    {ok, maps:get(external_url, Opts, undefined)};
get_external_url(Id) ->
    apply_nkport(Id, fun get_external_url/1).

%% @doc
-spec get_debug(id()|pid()|nkport()) ->
    {ok, boolean()} | error.

get_debug(#nkport{opts=Opts}) ->
    {ok, maps:get(debug, Opts, false)};
get_debug(Id) ->
    apply_nkport(Id, fun get_debug/1).


%% @private Finds a listening transport of Proto.
-spec get_listening(protocol(), transport()) -> 
    [nkport()].

get_listening(Protocol, Transp) ->
    get_listening(Protocol, Transp, #{}).


%% @private Finds a listening transport of Proto.
-spec get_listening(protocol(), transport(), #{class=>class(), ip=>4|6|tuple()}) -> 
    [nkport()].

get_listening(Protocol, Transp, Opts) ->
    Class = maps:get(class, Opts, none),
    Tag = case maps:get(ip, Opts, 4) of
        4 -> nkpacket_listen4;
        6 -> nkpacket_listen6;
        Ip when is_tuple(Ip), size(Ip)==4 -> nkpacket_listen4;
        Ip when is_tuple(Ip), size(Ip)==8 -> nkpacket_listen6
    end,
    [
        NkPort || 
        {NkPort, _Pid} 
            <- nklib_proc:values({Tag, Class, Protocol, Transp})
    ].


%% @doc Checks if an `uri()' refers to a local started transport.
%% For ws/wss, it does not check the path
-spec is_local(nklib:uri()) -> 
    boolean().

is_local(Uri) ->
    is_local(Uri, #{}).


%% @doc Checks if an `uri()' refers to a local started transport.
%% For ws/wss, it does not check the path
-spec is_local(nklib:uri(), #{class=>class(), no_dns_cache=>boolean()}) -> 
    boolean().

is_local(#uri{}=Uri, Opts) ->
    case nkpacket_resolve:resolve(Uri, Opts) of
        {ok, [#nkconn{protocol=Protocol, transp=Transp, ip=Ip}|_]=Conns} ->
            List = get_listening(Protocol, Transp, Opts#{ip=>Ip}),
            Listen = [
                {Transp, LIp, LPort} ||
                    #nkport{local_ip=LIp, local_port=LPort} <- List
            ],
            LocalIps = nkpacket_config:local_ips(),
            is_local(Listen, Conns, LocalIps);
        _ ->
            false
    end.


%% @private
is_local(Listen, [#nkconn{protocol=Protocol, transp=Transp, port=0}=Conn|Rest], LocalIps) ->
    case nkpacket_transport:get_defport(Protocol, Transp) of
        {ok, Port} ->
            is_local(Listen, [Conn#nkconn{port=Port}|Rest], LocalIps);
        error ->
            is_local(Listen, Rest, LocalIps)
    end;
    
is_local(Listen, [#nkconn{transp=Transp, ip=Ip, port=Port}|Rest], LocalIps) ->
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
    lists:member(Ip, nkpacket_config:local_ips()).


%% @private
-spec apply_nkport(id()|pid(), fun((nkport()) -> {ok, term()}))  ->
    term() | {error, term()}.

apply_nkport(Id, Fun) ->
    case get_id_pids(Id) of
        [] ->
            {error, id_not_found};
        [Pid] ->
            case catch gen_server:call(Pid, {nkpacket_apply_nkport, Fun}, 180000) of
                {'EXIT', _} -> {error, process_down};
                Other -> Other
            end;
        _ ->
            {error, multiple_pids}
    end.
