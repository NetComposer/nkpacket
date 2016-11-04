%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc NkPACKET Syntax
-module(nkpacket_syntax).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([app_syntax/0, app_defaults/0]).
-export([syntax/0, uri_syntax/0, tls_syntax/0, tls_defaults/0]).

-include("nkpacket.hrl").

%% ===================================================================
%% Public
%% ===================================================================


app_syntax() ->
    #{
        max_connections => {integer, 1, 1000000},
        dns_cache_ttl => {integer, 0, none},
        udp_timeout => nat_integer,                 % Overrided by idle_timeout
        tcp_timeout => nat_integer,                 % "
        sctp_timeout => nat_integer,                % "
        ws_timeout => nat_integer,                  % "
        http_timeout => nat_integer,                % "
        connect_timeout => nat_integer,
        sctp_out_streams => nat_integer,
        sctp_in_streams => nat_integer,
        main_ip => [ip4, {enum, [auto]}],
        main_ip6 => [ip6, {enum, [auto]}],
        ext_ip => [ip4, {enum, [auto]}],
        ext_ip6 => [ip6, {enum, [auto]}],
        ?TLS_SYNTAX
    }.



app_defaults() ->
    #{
        max_connections =>  1024,
        dns_cache_ttl => 30000,                 % msecs
        udp_timeout => 30000,                   % 
        tcp_timeout => 180000,                  % 
        sctp_timeout => 180000,                 % 
        ws_timeout => 180000,                   % 
        http_timeout => 180000,                 % 
        connect_timeout => 30000,               %
        sctp_out_streams => 10,
        sctp_in_streams => 10,
        main_ip => auto,
        main_ip6 => auto,
        ext_ip => auto,
        ext_ip6 => auto
    }.


syntax() ->
    #{
        class => any,
        monitor => proc,
        idle_timeout => pos_integer,
        connect_timeout => nat_integer,
        sctp_out_streams => nat_integer,
        sctp_in_streams => nat_integer,
        no_dns_cache => boolean,
        refresh_fun => {function, 1},
        valid_schemes => {list, atom},
        udp_starts_tcp => boolean,
        udp_to_tcp => boolean,
        udp_max_size => nat_integer,            % Only used for sending packets
        udp_no_connections => boolean,
        udp_stun_reply => boolean,
        udp_stun_t1 => nat_integer,
        tcp_packet => [{enum, [raw]}, {integer, [1, 2, 4]}],
        tcp_max_connections => nat_integer,
        tcp_listeners => nat_integer,
        host => host,
        path => path,
        get_headers => [boolean, {list, binary}],
        cowboy_opts => list,
        ws_proto => lower,
        http_proto => fun spec_http_proto/3,
        force_new => boolean,
        pre_send_fun => {function, 2},
        resolve_type => {enum, [listen, connect]},
        base_nkport => [boolean, {record, nkport}],
        ?TLS_SYNTAX,
        user => any,
        parse_syntax => ignore
    }.


uri_syntax() ->
    #{
        idle_timeout => pos_integer,
        connect_timeout => nat_integer,
        sctp_out_streams => nat_integer,
        sctp_in_streams => nat_integer,
        no_dns_cache => boolean,
        tcp_listeners => nat_integer,
        host => host,
        path => path,
        ws_proto => lower,
        tls_certfile => string,
        tls_keyfile => string,
        tls_cacertfile => string,
        tls_password => string,
        tls_verify => boolean,
        tls_depth => {integer, 0, 16}
    }.


tls_syntax() ->
    #{
        ?TLS_SYNTAX
    }.


tls_defaults() ->
    Base = case code:priv_dir(nkpacket) of
        PrivDir when is_list(PrivDir) ->
            #{
                certfile => filename:join(PrivDir, "cert.pem"),
                keyfile => filename:join(PrivDir, "key.pem")
            };
        _ ->
            #{}
    end,
    %% Avoid SSLv3
    Base#{versions => ['tlsv1.2', 'tlsv1.1', 'tlsv1']}.
    


%% @private
spec_http_proto(_, {static, #{path:=_}}, _) -> ok;
spec_http_proto(_, {dispatch, #{routes:=_}}, _) -> ok;
spec_http_proto(_, {custom, #{env:=_, middlewares:=_}}, _) -> ok;
spec_http_proto(_, _, _) -> error.


