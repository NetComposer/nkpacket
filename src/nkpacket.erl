%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Carlos Gonzalez Florido.  All Rights Reserved.
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
-export([start_listener/2, get_listener/2, stop_listener/1]).
-export([get_all/0, get_all/1, get_class/0, get_class/1]).
-export([stop_all/0, stop_all/1]).
-export([send/2, send/3, connect/2]).
-export([get_listening/2, get_listening/3, is_local/1, is_local/2, is_local_ip/1]).
-export([pid/1, get_nkport/1, get_local/1, get_remote/1, get_remote_bin/1, get_local_bin/1]).
-export([get_meta/1, get_user/1]).
-export([resolve/1, resolve/2, multi_resolve/1, multi_resolve/2, parse_urls/3]).

-export_type([listen_id/0, class/0, transport/0, protocol/0, nkport/0, netspec/0]).
-export_type([listen_opts/0, connect_opts/0, send_opts/0, resolve_opts/0]).
-export_type([connection/0, send_spec/0]).
-export_type([http_proto/0, incoming/0, outcoming/0, pre_send_fun/0]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


%% ===================================================================
%% Types
%% ===================================================================

%% Each listening transport has an unique id, generated from transp, ip, port and path
-type listen_id() :: atom().

%% Listeners and connections have an associated class.
%% When sending a message, if a previous connection to the same remote
%% and class exists, it will be reused.
%% When starting an outgoing connection, if a suitable listening transport 
%% is found with the same class, some values from listener's metadata will 
%% be copied to the new connection: user, idle_timeout, host, path, ws_proto, 
%% refresh_fun, tcp_packet, tls_opts
-type class() :: term().

%% Recognized transport schemes
-type transport() :: udp | tcp | tls | sctp | ws | wss | http | https.

%% A protocol is a module implementing nkpacket_protocol behaviour
-type protocol() :: module().

%% An opened port (listener or connection)
-type nkport() :: #nkport{}.

%% 
-type netspec() :: {protocol(), transport(), inet:ip_address(), inet:port_number()}.


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

%% Options for listeners
-type listen_opts() ::
    #{
        % Common options
        class => class(),                       % Class (see above)
        user => term(),                         % User metadata
        parse_syntax => map(),                  % Allows to update the syntax. See bellow
        monitor => atom() | pid(),              % Connection will monitor this
        idle_timeout => integer(),              % MSecs, default in config
        refresh_fun => fun((nkport()) -> boolean()),    % Will be called on timeout
        valid_schemes => [nklib:scheme()],       % Fail if not valid protocol (for URIs)
        implicit_scheme => nklib:scheme(),      % Allow using ws://...
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
        ?TLS_TYPES,

        % WS/WSS/HTTP/HTTPS options
        host => string() | binary(),            % Listen only on this host
        path => string() | binary(),            % Listen on this path and subpaths
        get_headers => boolean() | [binary()],  % Get all headers or some
        cowboy_opts => cowboy_opts(),

        % WS/WSS
        ws_proto => string() | binary(),        % Listen only on this protocol
        % ws_opts => map(),                     % See nkpacket_connection_ws
                                                % (i.e. #{compress=>true})
        % HTTP/HTTPS
        http_proto => http_proto()
    }.

%% NOTES
%% - if you use parse_syntax, that syntax will be added to nkpacket_syntax:syntax() when
%%   parsing these options (to add new options)





%% Options for connections
-type connect_opts() ::
    #{
        % Common options
        class => class(),                   % Class (see above)
        user => term(),                     % User metadata
        parse_syntax => map(),              % Allows to update the syntax. See above.
        monitor => atom() | pid(),          % Connection will monitor this
        connect_timeout => integer(),       % MSecs, default in config
        no_dns_cache => boolean(),          % Avoid DNS cache
        idle_timeout => integer(),          % MSecs, default in config
        refresh_fun => fun((nkport()) -> boolean()),   % Will be called on timeout
        base_nkport => boolean()| nkport(), % Select (or disables auto) base NkPort
        valid_schemes => [nklib:scheme()],  % Fail if not valid protocol (for URIs)
        implicit_scheme => nklib:scheme(),  % Allow using ws://...
        debug => boolean(),

        % TCP/TLS/WS/WSS options
        tcp_packet => 1 | 2 | 4 | raw,    
        ?TLS_TYPES,

        % WS/WSS
        host => string() | binary(),        % Host header to use
        path => string() | binary(),        % Path to use
        ws_proto => string() | binary(),    % Proto to use
        headers => [{string()|binary(), string()|binary()}]
    }.


%% Options for sending
-type send_opts() ::
    connect_opts() |
    #{
        % Specific options
        force_new => boolean(),             % Forces a new connection
        udp_to_tcp => boolean(),            % Change to TCP for large packets
        udp_max_size => pos_integer(),      % Used only for this sent request
        pre_send_fun => pre_send_fun()
    }.


%% Options for resolving
-type resolve_opts() ::
    #{
        resolve_type => listen | connect
    }                                      % used to process options
    | listen_opts()
    | send_opts().


%% Connection specification
-type user_connection() :: 
    nklib:user_uri() | connection().


%% Connection specification
-type connection() :: 
    nklib:uri() | netspec().


%% Sending remote specification options
-type send_spec() :: 
    user_connection() | {current, netspec()} | {connect, netspec()} |
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
-spec start_listener(user_connection(), listen_opts()) ->
    {ok, listen_id()} | {error, term()}.

start_listener(UserConn, Opts) ->
    case get_listener(UserConn, Opts) of
        {ok, Spec} ->
            case nkpacket_sup:add_listener(Spec) of
                {ok, Pid} -> 
                    {registered_name, Id} = process_info(Pid, registered_name),
                    {ok, Id};
                {error, Error} -> 
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @doc Gets a listening supervisor specification
-spec get_listener(user_connection(), listen_opts()) ->
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
            % We cannot yet generate id, port can be 0
            NkPort = #nkport{
                class = maps:get(class, Opts, none),
                protocol = Protocol,
                transp = Transp,
                listen_ip = Ip,
                listen_port = Port,
                meta = Opts2
            },
            nkpacket_transport:get_listener(NkPort);
        {error, Error} ->
            {error, Error}
    end;

get_listener(Uri, Opts) when is_map(Opts) ->
    case resolve(Uri, Opts#{resolve_type=>listen}) of
        {ok, [Conn], Opts1} ->
            get_listener(Conn, Opts1);
        {ok, _, _} ->
            {error, invalid_uri};
        {error, Error} ->
            {error, Error}
    end.



%% @doc Stops a locally started listener (only for standard supervisor)
-spec stop_listener(nkport()|listen_id()|pid()) ->
    ok | {error, term()}.

stop_listener(Id) when is_pid(Id); is_atom(Id) ->
    nklib_util:call(Id, nkpacket_stop, 30000);
    
stop_listener(#nkport{pid=Pid}) ->
    stop_listener(Pid).


%% @doc Gets all registered transports
-spec get_all() -> 
    [listen_id()].

get_all() ->
    [Id || {{Id, _Class}, _Pid} <- nklib_proc:values(nkpacket_listeners)].


%% @doc Gets all registered transports for a class.
-spec get_all(class()) -> 
    [pid()].

get_all(Class) ->
    [Id || {{Id, C}, _Pid} <- nklib_proc:values(nkpacket_listeners), C==Class].


%% @doc Gets all classes having registered listeners
-spec get_class() -> 
    #{class() => [listen_id()]}.

get_class() ->
    lists:foldl(
        fun({{Id, Class}, _Pid}, Acc) ->
            maps:put(Class, [Id|maps:get(Class, Acc, [])], Acc) 
        end,
        #{},
        nklib_proc:values(nkpacket_listeners)).


%% @doc Gets all classes having registered listeners
-spec get_class(class()) -> 
    [listen_id()].

get_class(Class) ->
    All = get_class(),
    maps:get(Class, All, []).


%% @doc Stops all locally started listeners (only for standard supervisor)
stop_all() ->
    lists:foreach(
        fun(Pid) -> stop_listener(Pid) end,
        get_all()).


%% @doc Stops all locally started listeners for a class (only for standard supervisor)
stop_all(Class) ->
    lists:foreach(
        fun(Pid) -> stop_listener(Pid) end,
        get_all(Class)).



%% @doc Gets the current nkport of a listener or connection
-spec get_nkport(listen_id()|pid()) ->
    {ok, nkport()} | error.

get_nkport(#nkport{}=NkPort) ->
    {ok, NkPort};
get_nkport(Id) when is_pid(Id); is_atom(Id) ->
    apply_nkport(Id, fun get_nkport/1).


%% @doc Gets the current port number of a listener or connection
-spec get_local(listen_id()|pid()|nkport()) ->
    {ok, netspec()} | error.

get_local(#nkport{protocol=Proto, transp=Transp, local_ip=Ip, local_port=Port}) ->
    {ok, {Proto, Transp, Ip, Port}};
get_local(Id) when is_pid(Id); is_atom(Id) ->
    apply_nkport(Id, fun get_local/1).


%% @doc Gets the current remote peer address and port
-spec get_remote(listen_id()|pid()|nkport()) ->
    {ok, netspec()} | error.

get_remote(#nkport{protocol=Proto, transp=Transp, remote_ip=Ip, remote_port=Port}) ->
    {ok, {Proto, Transp, Ip, Port}};
get_remote(Id) when is_pid(Id); is_atom(Id) ->
    apply_nkport(Id, fun get_remote/1).


%% @doc Gets the current remote peer address and port
-spec get_remote_bin(listen_id()|pid()|nkport()) ->
    {ok, binary()} | error.

get_remote_bin(Term) ->
    case get_remote(Term) of
        {ok, {_Proto, Transp, Ip, Port}} ->
            {ok, 
                <<
                    (nklib_util:to_binary(Transp))/binary, ":",
                    (nklib_util:to_host(Ip))/binary, ":",
                    (nklib_util:to_binary(Port))/binary
                >>};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Gets the current local peer address and port
-spec get_local_bin(listen_id()|pid()|nkport()) ->
    {ok, binary()} | error.

get_local_bin(Term) ->
    case get_local(Term) of
        {ok, {_Proto, Transp, Ip, Port}} ->
            {ok,
                <<
                    (nklib_util:to_binary(Transp))/binary, ":",
                    (nklib_util:to_host(Ip))/binary, ":",
                    (nklib_util:to_binary(Port))/binary
                >>};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Gets the user metadata of a listener or connection
-spec get_meta(listen_id()|pid()|nkport()) ->
    {ok, map()} | error.

get_meta(#nkport{meta=Meta}) ->
    {ok, Meta};
get_meta(Id) when is_pid(Id); is_atom(Id) ->
    apply_nkport(Id, fun get_meta/1).


%% @doc Gets the user metadata of a listener or connection
-spec get_user(listen_id()|pid()|nkport()) ->
    {ok, term(), term()} | error.

get_user(#nkport{class=Class, meta=Meta}) ->
    {ok, Class, maps:get(user, Meta, undefined)};
get_user(Id) when is_pid(Id); is_atom(Id) ->
    apply_nkport(Id, fun get_user/1).


%% @doc Gets the current pid() of a listener or connection
-spec pid(listen_id()|pid()|nkport()) ->
    pid().

pid(Id) when is_atom(Id) ->
    pid(whereis(Id));
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
%% If a class is included, it will try to reuse any existing connection of the same class
%% (except if force_new option is set)
-spec send(send_spec() | [send_spec()], term(), send_opts()) ->
    {ok, pid()} | {error, term()}.

send(SendSpec, Msg, Opts) when is_list(SendSpec), not is_integer(hd(SendSpec)) ->
    case nkpacket_util:parse_opts(Opts) of
        {ok, Opts1} ->
            case Opts1 of
                #{debug:=true} -> put(nkpacket_debug, true);
                _ -> ok
            end,
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
    {ok, nkport()} | {error, term()}.

connect({_, _, _, _}=Conn, Opts) when is_map(Opts) ->
    connect([Conn], Opts);

connect(Conns, Opts) when is_list(Conns), not is_integer(hd(Conns)), is_map(Opts) ->
    case nkpacket_util:parse_opts(Opts) of
        {ok, Opts1} ->
            case Opts1 of
                #{debug:=true} -> put(nkpacket_debug, true);
                _ -> ok
            end,
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
    case resolve(Uri, Opts) of
        {ok, [{Protocol, Transp, Ip, _Port}|_]=Conns, _Opts1} ->
            List = get_listening(Protocol, Transp, Opts#{ip=>Ip}),
            Listen = [
                {Transp, LIp, LPort} ||
                    #nkport{local_ip=LIp, local_port=LPort} <- List
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
    {ok, [netspec()], map()} |
    {error, term()}.

resolve(Uri) ->
    resolve(Uri, #{}).


%% @private
-spec resolve(nklib:user_uri(), resolve_opts()) -> 
    {ok, [netspec()], map()} |
    {error, term()}.

resolve(#uri{}=Uri, Opts) ->
    Uri2 = resolve_scheme(Uri, Opts),
    #uri{
        scheme = Scheme,
        user = User,
        pass = Pass,
        domain = Host, 
        path = Path, 
        ext_opts = UriOpts, 
        ext_headers = Headers
    } = Uri2,
    UriOpts1 = [{nklib_parse:unquote(K), nklib_parse:unquote(V)} || {K, V} <- UriOpts],
    UriOpts2 = case Host of
        <<"0.0.0.0">> -> UriOpts1;
        <<"0:0:0:0:0:0:0:0">> -> UriOpts1;
        <<"::0">> -> UriOpts1;
        <<"all">> -> UriOpts1;
        _ -> [{host, Host}|UriOpts1]            % Host to listen on for WS/HTTP
    end,
    UriOpts3 = case User of
        <<>> ->
            UriOpts2;
        _ ->
            case Pass of
                <<>> -> [{user, User}|UriOpts2];
                _ -> [{user, User}, {password, Pass}|UriOpts2]
            end
    end,
    UriOpts4 = case Path of
        <<>> -> UriOpts3;
        _ -> [{path, Path}|UriOpts3]            % Path to listen on for WS/HTTP
    end,
    UriOpts5 = case Headers of
        [] -> UriOpts4;
        _ -> [{user, Headers}|UriOpts4]
    end,
    try
        UriOpts6 = case nkpacket_util:parse_uri_opts(UriOpts5, Opts) of
            {ok, ParsedUriOpts} -> ParsedUriOpts;
            {error, Error1} -> throw(Error1) 
        end,
        Opts1 = case nkpacket_util:parse_opts(Opts) of
            {ok, CoreOpts} -> maps:merge(UriOpts6, CoreOpts);
            {error, Error2} -> throw(Error2) 
        end,
        Opts2 = case Opts1 of
            #{valid_schemes:=ValidSchemes} ->
                case lists:member(Scheme, ValidSchemes) of
                    true -> maps:remove(valid_schemes, Opts1);
                    false -> throw({invalid_scheme, Scheme})
                end;
            _ ->
                Opts1
        end,
        Protocol = case Opts2 of
            #{class:=Class} -> 
                nkpacket:get_protocol(Class, Scheme);
            _ -> 
                nkpacket:get_protocol(Scheme)
        end,
        case nkpacket_dns:resolve(Uri2, Opts2#{protocol=>Protocol}) of
            {ok, Addrs} ->
                Conns = [ 
                    {Protocol, Transp, Addr, Port} 
                    || {Transp, Addr, Port} <- Addrs
                ],
                {ok, Conns, maps:remove(resolve_type, Opts2)};
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
resolve_scheme(#uri{scheme=Sc, opts=UriOpts}=Uri, Opts) ->
    case maps:find(implicit_scheme, Opts) of
        {ok, Sc} ->
            Uri;
        {ok, Forced} when Sc==tcp; Sc==tls; Sc==ws; Sc==wss; Sc==http; Sc==https ->
            Uri#uri{scheme=Forced, opts=[{<<"transport">>, Sc}|UriOpts]};
        {ok, Other} ->
            throw({invalid_scheme, Other});
        error ->
            Uri
    end.


%% @private
-spec multi_resolve(nklib:user_uri()|[nklib:user_uri()]) -> 
    {ok, [{[netspec()], map()}]} |
    {error, term()}.

multi_resolve(Uri) ->
    multi_resolve(Uri, #{}).


%% @private
-spec multi_resolve(nklib:user_uri()|[nklib:user_uri()], resolve_opts()) -> 
    {ok, [{[netspec()], map()}]} |
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
-spec apply_nkport(listen_id()|pid(), fun((nkport()) -> {ok, term()}))  ->
    term() | error.

apply_nkport(Id, Fun) when is_pid(Id); is_atom(Id) ->
    case catch gen_server:call(Id, {nkpacket_apply_nkport, Fun}, 180000) of
        {'EXIT', _} -> error;
        Other -> Other
    end.


%% @doc Parses an url that can use a Proto+Transports or uses Transport as Scheme
-spec parse_urls(atom(), [atom()], term()) ->
    {ok, [{[netspec()], map()}]} |
    {error, term()}.

parse_urls(Proto, Transports, Url) ->
    case nklib_parse:uris(Url) of
        error ->
            {error, invalid_url};
        List ->
            case do_parse_urls(Proto, Transports, List, []) of
                error ->
                    {error, invalid_url};
                List2 ->
                    multi_resolve(List2, #{resolve_type=>listen})
            end
    end.



%% @private
do_parse_urls(_Proto, _Transports, [], Acc) ->
    lists:reverse(Acc);

do_parse_urls(Proto, Transports, [#uri{scheme=Proto, opts=Opts, ext_opts=ExtOpts}=Uri|Rest], Acc) ->
    Transp1 = case nklib_util:get_value(<<"transport">>, Opts) of
        undefined ->
            nklib_util:get_value(<<"transport">>, ExtOpts);
        T1 ->
            T1
    end,
    Transp2 = (catch nklib_util:to_existing_atom(Transp1)),
    case Transp2==undefined orelse lists:member(Transp2, Transports) of
        true ->
            do_parse_urls(Proto, Transports, Rest, [Uri|Acc]);
        false ->
            error
    end;

do_parse_urls(Proto, Transports, [#uri{scheme=Sc, ext_opts=Opts}=Uri|Rest], Acc) ->
    case lists:member(Sc, Transports) of
        true ->
            Uri2 = Uri#uri{scheme=Proto, opts=[{<<"transport">>, Sc}|Opts]},
            do_parse_urls(Proto, Transports, Rest, [Uri2|Acc]);
        false ->
            error
    end.



