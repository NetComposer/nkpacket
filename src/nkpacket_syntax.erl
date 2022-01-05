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

%% @doc NkPACKET Syntax
-module(nkpacket_syntax).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([app_syntax/0]).
-export([syntax/0, safe_syntax/0, tls_syntax/0, tls_syntax/1, extract_tls/1,
         packet_syntax/0, resolve_syntax/1]).
-export([spec_http_proto/3, spec_headers/1]).

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
        tos => pos_integer,
        main_ip => [ip4, {atom, [auto]}],
        main_ip6 => [ip6, {atom, [auto]}],
        ext_ip => [ip4, {atom, [auto]}],
        ext_ip6 => [ip6, {atom, [auto]}],
        '__defaults' => #{
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
            tos => 0,
            main_ip => auto,
            main_ip6 => auto,
            ext_ip => auto,
            ext_ip6 => auto
        }
    }.


syntax() ->
    Base = #{
        id => any,
        class => any,
        monitor => proc,
        protocol => module,
        idle_timeout => pos_integer,
        connect_timeout => nat_integer,
        sctp_out_streams => nat_integer,
        sctp_in_streams => nat_integer,
        no_dns_cache => boolean,
        refresh_fun => {function, 1},
        udp_starts_tcp => boolean,
        udp_to_tcp => boolean,
        udp_max_size => nat_integer,            % Only used for sending packets
        udp_no_connections => boolean,
        udp_stun_reply => boolean,
        udp_stun_t1 => nat_integer,
        tcp_packet => [{atom, [raw]}, {integer, [1, 2, 4]}],
        send_timeout => integer,
        send_timeout_close => boolean,
        tcp_max_connections => nat_integer,
        tcp_listeners => nat_integer,
        user => binary,
        password => binary,
        host => host,
        path => binary,     % Changed from 'path' to allow ending '/'
        get_headers => [boolean, {list, binary}],
        external_url => binary,
        http_inactivity_timeout => pos_integer,    % msecs
        http_max_empty_lines => pos_integer,
        http_max_header_name_length => pos_integer,
        http_max_header_value_length => pos_integer,
        http_max_headers => pos_integer,
        http_max_keepalive => pos_integer,
        http_max_method_length => pos_integer,
        http_max_request_line_length => pos_integer,
        http_request_timeout => pos_integer,
        ws_proto => lower,
        headers => fun ?MODULE:spec_headers/1,
        http_proto => fun ?MODULE:spec_http_proto/3,
        force_new => boolean,
        resolve_type => {atom, [listen, connect, send]},
        base_nkport => [boolean, {record, nkport}],
        user_state => any,
        tos => pos_integer,
        debug => boolean
    },
    add_tls_syntax(Base).


safe_syntax() ->
    Opts = [
        id,
        idle_timeout,
        connect_timeout,
        no_dns_cache,
        udp_max_size,
        tcp_packet,
        send_timeout,
        send_timeout_close,
        tcp_listeners,
        host,
        path,
        user,
        password,
        get_headers,
        external_url,
        ws_proto,
        headers,                % Not sure
        tos,
        debug,
        http_inactivity_timeout,
        http_max_empty_lines,
        http_max_header_name_length,
        http_max_header_value_length,
        http_max_headers,
        http_max_keepalive,
        http_max_method_length,
        http_max_request_line_length,
        http_request_timeout
    ] ++ maps:keys(tls_syntax()),
    Syntax = syntax(),
    maps:with(Opts, Syntax).


tls_syntax() ->
    tls_syntax(#{}).


%% Config for letsencrypt:
%% tls_keyfile => "/etc/letsencrypt/archive/.../privkey.pem",
%% tls_cacertfile => "/etc/letsencrypt/archive/.../chain.pem",
%% tls_certfile => "/etc/letsencrypt/archive/.../cert.pem"

tls_syntax(Base) ->
    Base#{
        tls_verify => {atom, [host, true, false]},
        tls_certfile => string,
        tls_keyfile => string,
        tls_cacertfile => string,
        tls_password => string,
        tls_depth => {integer, 0, 16},
        tls_versions => {list, atom}
    }.


add_tls_syntax(Syntax) ->
    tls_syntax(Syntax).


extract_tls(Map) when is_map(Map) ->
    Keys = lists:filter(
        fun(Key) ->
            case nklib_util:to_list(Key) of
                "tls_" ++ _ -> true;
                _ -> false
            end
        end,
        maps:keys(Map)),
    maps:with(Keys, Map).


packet_syntax() ->
    #{
        packet_idle_timeout => pos_integer,
        packet_connect_timeout => nat_integer,
        packet_sctp_out_streams => nat_integer,
        packet_sctp_in_streams => nat_integer,
        packet_no_dns_cache => boolean
    }.


resolve_syntax(Protocol) ->
    {mfa, nkpacket_resolve, check_syntax, [Protocol]}.



%% @private
spec_http_proto(_, {static, #{path:=_}}, _) -> ok;
spec_http_proto(_, {dispatch, #{routes:=_}}, _) -> ok;
spec_http_proto(_, {custom, #{env:=_, middlewares:=_}}, _) -> ok;
spec_http_proto(_, _, _) -> error.


%% @private
spec_headers(List) when is_list(List) ->
    spec_headers(List, []);
spec_headers(_) ->
    error.


%% @private
spec_headers([], Acc) ->
    {ok, Acc};
spec_headers([{K, V}|Rest], Acc) ->
    spec_headers(Rest, [{to_bin(K), to_bin(V)}|Acc]);
spec_headers(_, _Acc) ->
    error.



%% @private
to_bin(K) -> nklib_util:to_binary(K).