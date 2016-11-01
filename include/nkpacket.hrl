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

-ifndef(NKPACKET_HRL_).
-define(NKPACKET_HRL_, 1).

%% ===================================================================
%% Defines
%% ===================================================================

-define(CONN_LISTEN_OPTS, 
    [group, user, idle_timeout, host, path, ws_proto, refresh_fun]).

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


-define(TLS_SYNTAX,
    tls_certfile => string,
    tls_keyfile => string,
    tls_cacertfile => string,
    tls_password => string,
    tls_verify => boolean,
    tls_depth => {integer, 0, 16},
    tls_versions => {list, atom}
).

-define(TLS_TYPES,
    tls_certfile => string(),
    tls_keyfile => string(),
    tls_cacertfile => string(),
    tls_password => string(),
    tls_verify => boolean(),
    tls_depth => 0..16,
    tls_versions => [atom()]
).


%% ===================================================================
%% Records
%% ===================================================================

%% Meta can contain most values from listener_opts and connect_opts

-record(nkport, {
    class :: nkpacket:class(),
    protocol :: nkpacket:protocol(),
    transp :: nkpacket:transport(),
    local_ip :: inet:ip_address(),
    local_port :: inet:port_number(),
    remote_ip :: inet:ip_address(),
    remote_port :: inet:port_number(),
    listen_ip :: inet:ip_address(),
    listen_port :: inet:port_number(),
    pid :: pid(),
    socket :: nkpacket_transport:socket(),
    meta = #{} :: map()
}).


-endif.

