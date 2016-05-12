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

%% @private NkSIP Config Cache
%%
%%
%% This module is hot compiled in run-time, after NkPACKET application has started.
%% It maintains a number of functions to cache some parts of the configuration.
%%
%% See nkpacket_config

-module(nkpacket_config_cache).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile([export_all]).


local_ips() -> [].
udp_timeout() -> 0.
tcp_timeout() -> 0.
sctp_timeout() -> 0.
ws_timeout() -> 0.
http_timeout() -> 0.
max_connections() -> 0.
dns_cache_ttl() -> 0.
connect_timeout() -> 0.
sctp_in_streams() -> 0.
sctp_out_streams() -> 0.