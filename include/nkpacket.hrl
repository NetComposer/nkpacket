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

-define(VERSION, "0.1.0").

-define(
    DO_LOG(Level, Domain, Text, Opts),
        lager:Level([{domain, Domain}], "~p "++Text, [Domain|Opts])).

-define(DO_DEBUG(_Domain, _Level, _Text, _List),
    % case is_function(nkpacket_config_cache:debug_fun(Domain), 4) of
    %     false -> ok;
    %     true -> (nkpacket_config_cache:debug_fun(Domain))(Domain, Level, Text, List)
    % end).
    ok).


-define(debug(Domain, Text, List), 
    ?DO_DEBUG(Domain, debug, Text, List),
    case nkpacket_config_cache:log_level(Domain) >= 8 of
        true -> ?DO_LOG(debug, Domain, Text, List);
        false -> ok
    end).

-define(info(Domain, Text, List), 
    ?DO_DEBUG(Domain, info, Text, List),
    case nkpacket_config_cache:log_level(Domain) >= 7 of
        true -> ?DO_LOG(info, Domain, Text, List);
        false -> ok
    end).

-define(notice(Domain, Text, List), 
    ?DO_DEBUG(Domain, notice, Text, List),
    case nkpacket_config_cache:log_level(Domain) >= 6 of
        true -> ?DO_LOG(notice, Domain, Text, List);
        false -> ok
    end).

-define(warning(Domain, Text, List), 
    ?DO_DEBUG(Domain, warning, Text, List),
    case nkpacket_config_cache:log_level(Domain) >= 5 of
        true -> ?DO_LOG(warning, Domain, Text, List);
        false -> ok
    end).

-define(error(Domain, Text, List), 
    ?DO_DEBUG(Domain, error, Text, List),
    case nkpacket_config_cache:log_level(Domain) >= 4 of
        true -> ?DO_LOG(error, Domain, Text, List);
        false -> ok
    end).



%% ===================================================================
%% Records
%% ===================================================================




-record(nkport, {
    domain :: nkpacket:domain(),
    transp :: nkpacket:transport(),
    local_ip :: inet:ip_address(),
    local_port :: inet:port_number(),
    remote_ip :: inet:ip_address(),
    remote_port :: inet:port_number(),
    listen_ip :: inet:ip_address(),
    listen_port :: inet:port_number(),
    protocol :: nkpacket:protocol(),
    pid :: pid(),
    socket :: nkpacket_transport:socket(),
    meta = #{}
}).



-endif.

