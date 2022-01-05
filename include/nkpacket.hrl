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

-ifndef(NKPACKET_HRL_).
-define(NKPACKET_HRL_, 1).

%% ===================================================================
%% Defines
%% ===================================================================

-define(CONN_LISTEN_OPTS, 
    [group, user, idle_timeout, host, path, ws_proto, refresh_fun, debug, external_url, tos]).

-define(CONN_CLIENT_OPTS, [monitor|?CONN_LISTEN_OPTS]).


-define(
    DO_LOG(Level, Domain, Text, Opts),
        lager:Level([{domain, Domain}], "~p "++Text, [Domain|Opts])).

-define(debug(Domain, Text, List), 
    ?DO_LOG(debug, Domain, Text, List)).

-define(info(Domain, Text, List), 
    ?DO_LOG(info, Domain, Text, List)).

-define(notice(Domain, Text, List), 
    ?DO_LOG(notice, Domain, Text, List)).

-define(warning(Domain, Text, List), 
    ?DO_LOG(warning, Domain, Text, List)).

-define(error(Domain, Text, List), 
    ?DO_LOG(error, Domain, Text, List)).



%%-define(PACKET_TYPES,
%%    packet_idle_timeout => integer()
%%    packet_connect_timeout => integer(),
%%    packet_sctp_out_streams => integer(),
%%    packet_sctp_in_streams => integer,
%%    packet_no_dns_cache => integer(),
%%).


%% ===================================================================
%% Records
%% ===================================================================

%% Meta can contain most values from listener_opts and connect_opts

-record(nkport, {
    id :: nkpacket:id() | undefined,
    class :: nkpacket:class() | undefined,
    protocol :: nkpacket:protocol() | undefined,
    transp :: nkpacket:transport() | undefined,
    local_ip :: inet:ip_address() | undefined,
    local_port :: inet:port_number() | undefined,
    remote_ip :: inet:ip_address() | undefined,
    remote_port :: inet:port_number() | undefined,
    listen_ip :: inet:ip_address() | undefined,
    listen_port :: inet:port_number() | undefined,
    pid :: pid() | undefined,
    socket :: nkpacket_transport:socket() | undefined,
    opts = #{} :: nkpacket:listen_opts() | nkpacket:send_opts(),
    user_state = undefined :: nkpacket:user_state()
}).


-record(nkconn, {
    protocol :: nkpacket:protocol(),
    transp :: nkpacket:transport(),
    ip = {0,0,0,0} :: inet:ip_address(),
    port = 0 :: inet:port_number(),
    opts = #{} :: nkpacket:listen_opts() | nkpacket:send_opts()
}).


-record(cowboy_filter, {
    pid :: pid(),
    module :: module(),
    transp :: http | https | ws | wss,
    host = any :: any | binary(),
    paths = [] :: [binary()],
    ws_proto = any :: binary() | any,
    meta :: #{get_headers => [binary()], compress => boolean(), idle_timeout=>pos_integer()},
    mon :: reference() | undefined
}).


-endif.

