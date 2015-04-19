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

%% @private Generic tranport connection process library functions
-module(nkpacket_connection_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([is_max/1, raw_send/2, raw_stop/1]).

-include_lib("nklib/include/nklib.hrl").
-include_lib("kernel/include/inet_sctp.hrl").
-include("nkpacket.hrl").

-define(MAX_UDP, 1500).


%% ===================================================================
%% Private
%% ===================================================================

%% @doc Checks if we already have the maximum number of connections
-spec is_max(nkpacket:domain()) ->
    boolean().

is_max(Domain) ->
    Max = nkpacket_config_cache:global_max_connections(),
    case nklib_counters:value(nkpacket_connections) of
        Current when Current > Max -> 
            true;
        _ -> 
            AppMax = nkpacket_config_cache:max_connections(Domain),
            case nklib_counters:value({nkpacket_connections, Domain}) of
                AppCurrent when AppCurrent > AppMax -> 
                    true;
                _ ->
                    false
            end
    end.


%% @doc Sends data directly to a transport
-spec raw_send(nkpacket:nkport(), nkpacket:outcoming()) ->
    ok | {error, term()}.
    
raw_send(#nkport{transp=udp}, Data) when byte_size(Data) > ?MAX_UDP ->
    {error, udp_too_large};    

raw_send(#nkport{transp=udp, socket=Socket, remote_ip=Ip, remote_port=Port}, Data) ->
    gen_udp:send(Socket, Ip, Port, Data);

raw_send(#nkport{transp=tcp, socket=Socket}, Data) ->
    gen_tcp:send(Socket, Data);

raw_send(#nkport{transp=tls, socket=Socket}, Data) ->
    ssl:send(Socket, Data);

raw_send(#nkport{transp=sctp, socket={Socket, AssocId}}, Data) ->
    gen_sctp:send(Socket, AssocId, 0, Data);

raw_send(#nkport{transp=ws, socket=Socket}, Data) when is_port(Socket) ->
    Bin = nkpacket_connection_ws:encode(get_ws_frame(Data)),
    gen_tcp:send(Socket, Bin);

raw_send(#nkport{transp=wss, socket={sslsocket, _, _}=Socket}, Data) ->
    Bin = nkpacket_connection_ws:encode(get_ws_frame(Data)),
    ssl:send(Socket, Bin);

raw_send(#nkport{transp=Transp, socket=Pid}, Data) when is_pid(Pid) ->
    Msg = if
        Transp==ws; Transp==wss -> get_ws_frame(Data);
        true -> Data
    end,
    case is_process_alive(Pid) of
        true -> 
            Pid ! {nkpacket_send, Msg},
            ok;
        false ->
            {error, no_process}
    end;

raw_send(_, _) ->
    {error, invalid_transport}.


%% @private
get_ws_frame(Data) when is_binary(Data) -> {binary, Data};
get_ws_frame(Data) when is_list(Data) -> {binary, list_to_binary(Data)};
get_ws_frame(Other) -> Other.


%% @doc Stops a transport
-spec raw_stop(nkpacket:nkport()) ->
    ok | {error, term()}.
    
raw_stop(#nkport{transp=udp}) ->
    ok;

raw_stop(#nkport{transp=tcp, socket=Socket}) ->
    gen_tcp:close(Socket);

raw_stop(#nkport{transp=tls, socket=Socket}) ->
    ssl:close(Socket);

raw_stop(#nkport{transp=sctp, socket={Socket, AssocId}}) ->
    gen_sctp:eof(Socket, #sctp_assoc_change{assoc_id=AssocId});

raw_stop(#nkport{transp=ws, socket=Socket}) when is_port(Socket) ->
    gen_tcp:close(Socket);

raw_stop(#nkport{transp=wss, socket={sslsocket, _, _}=Socket}) ->
    ssl:close(Socket);

raw_stop(#nkport{socket=Pid}) when is_pid(Pid) ->
    Pid ! nkpacket_stop,
    ok;

raw_stop(_) ->
    {error, invalid_transport}.

