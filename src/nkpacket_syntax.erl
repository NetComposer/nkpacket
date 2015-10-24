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

%% @doc NkPACKET Syntax
-module(nkpacket_syntax).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([global_syntax/0, global_defaults/0]).
-export([syntax/0]).


%% ===================================================================
%% Public
%% ===================================================================


global_syntax() ->
    #{
        max_connections => {integer, 1, 1000000},
        dns_cache_ttl => {integer, 0, none},
        udp_timeout => nat_integer,
        tcp_timeout => nat_integer,
        sctp_timeout => nat_integer,
        ws_timeout => nat_integer,
        http_timeout => nat_integer,
        connect_timeout => nat_integer,
        local_host => [{enum, [auto]}, host],
        local_host6 => [{enum, [auto]}, host6],
        tls_opts => 
            #{
                certfile => string,
                keyfile => string,
                cacertfile => string,
                password => string,
                verify => boolean,
                depth => {integer, 0, 16}
            }
    }.



global_defaults() ->
    #{
        max_connections =>  1024,
        dns_cache_ttl => 30000,                 % msecs
        udp_timeout => 30000,                   % 
        tcp_timeout => 180000,                  % 
        sctp_timeout => 180000,                 % 
        ws_timeout => 180000,                   % 
        http_timeout => 180000,                 % 
        connect_timeout => 30000,               %
        local_host => auto,
        local_host6 => auto
    }.


syntax() ->
    #{
        srv_id => any,
        user => any,
        monitor => proc,
        no_dns_cache => boolean,
        idle_timeout => pos_integer,
        refresh_fun => {function, 1},
        valid_schemes => {list, atom},
        udp_starts_tcp => boolean,
        udp_no_connections => boolean,
        udp_stun_reply => boolean,
        udp_stun_t1 => nat_integer,
        sctp_out_streams => nat_integer,
        sctp_in_streams => nat_integer,
        tcp_packet => [{enum, [raw]}, {integer, [1, 2, 4]}],
        tcp_max_connections => nat_integer,
        tcp_listeners => nat_integer,
        tls_opts => tls_syntax(),
        host => host,
        path => path,
        cowboy_opts => list,
        ws_proto => lower,
        http_proto => fun spec_http_proto/3,
        connect_timeout => nat_integer,
        listen_port => [boolean, {record, nkport}],
        force_new => boolean,
        udp_to_tcp => boolean,
        pre_send_fun => {function, 2},
        resolve_type => {enum, [listen, connect]},

        tls_certfile => {update, map, tls_opts, certfile, string},
        tls_keyfile => {update, map, tls_opts, keyfile, string},
        tls_cacertfile => {update, map, tls_opts, cacertfile, string},
        tls_password => {update, map, tls_opts, password, string},
        tls_verify => {update, map, tls_opts, verify, boolean},
        tls_depth => {update, map, tls_opts, depth, {integer, 0, 16}},

        password => binary      % Not used by nkpacket, for users


    }.


tls_syntax() -> 
    #{
        certfile => string,
        keyfile => string,
        cacertfile => string,
        password => string,
        verify => boolean,
        depth => {integer, 0, 16}
    }.


%% @private
spec_http_proto(_, {static, #{path:=_}}, _) -> ok;
spec_http_proto(_, {dispatch, #{routes:=_}}, _) -> ok;
spec_http_proto(_, {custom, #{env:=_, middlewares:=_}}, _) -> ok;
spec_http_proto(_, _, _) -> error.


