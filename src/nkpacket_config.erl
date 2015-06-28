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

%% @doc NkPACKET Config Server.
-module(nkpacket_config).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([register_protocol/2, register_protocol/3, load_domain/2]).
-export([get_local_ips/0]).
-export([get/1, get/2, get_domain/2, get_protocol/1, get_protocol/2]).
-export([put/2, del/1, increment/2]).

-export([start_link/0, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, 
         handle_info/2]).

-compile({no_auto_import, [get/1, put/2]}).

-include("nkpacket.hrl").


%% ===================================================================
%% Public
%% ===================================================================


%% doc Registers a new 'default' protocol
-spec register_protocol(nklib:scheme(), nkpacket:protocol()) ->
    ok.

register_protocol(Scheme, Protocol) when is_atom(Scheme), is_atom(Protocol) ->
    {module, _} = code:ensure_loaded(Protocol),
    put({protocol, Scheme}, Protocol).


%% doc Registers a new protocol for an specific domain
-spec register_protocol(nkpacket:domain(), nklib:scheme(), nkpacket:protocol()) ->
    ok.

register_protocol(Domain, Scheme, Protocol) when is_atom(Scheme), is_atom(Protocol) ->
    {module, _} = code:ensure_loaded(Protocol),
    put({protocol, Domain, Scheme}, Protocol).


%% @doc Loads a domain configuration
-spec load_domain(nkpacket:domain(), map()|list()) ->
    ok | {error, term()}.

load_domain(Domain, Opts) when is_map(Opts) ->
    load_domain(Domain, maps:to_list(Opts));

load_domain(Domain, Opts) when is_list(Opts) ->
    ValidDomainKeys = [K || {K, _} <- domain_default_config()],
    Opts1 = [case T of {K, V} -> {K, V}; K -> {K, true} end || T <- Opts],
    DomainKeys = [K || {K, _} <- Opts1],
    case DomainKeys -- ValidDomainKeys of
        [] ->
            ok;
        Rest ->
            lager:warning("Ignoring config keys ~p starting domain", [Rest])
    end,
    ValidOpts = nklib_util:extract(Opts1, ValidDomainKeys),
    DefaultDomainOpts = [{K, get(K)} || K <- ValidDomainKeys],
    Opts2 = nklib_util:defaults(ValidOpts, DefaultDomainOpts),
    case parse_config(Opts2, []) of
        {ok, Opts3} ->
            lists:foreach(fun({K,V}) -> put({K, Domain}, V) end, Opts3),
            ok;
        {error, Error} ->
            {error, Error}
    end.


%% @doc Get the list of local IPs
-spec get_local_ips() ->
    [inet:ip_addr()].

get_local_ips() ->
    get(local_ips).


%% ===================================================================
%% Internal
%% ===================================================================


%% @doc Equivalent to `get(Key, undefined)'.
-spec get(term()) -> 
    Value :: term().

get(Key) ->
    get(Key, undefined).


%% @doc Gets an config value.
-spec get(term(), term()) -> 
    Value :: term().

get(Key, Default) -> 
    case ets:lookup(?MODULE, Key) of
        [] -> Default;
        [{_, Value}] -> Value
    end.


%% @private
-spec get_domain(nkpacket:domain(), term()) -> 
    Value :: term().

get_domain(Domain, Key) ->
    case get({Key, Domain}) of
        undefined -> get(Key);
        Value -> Value
    end.


%% @private
-spec get_protocol(nklib:scheme()) -> 
    nkpacket:protocol() | undefined.

get_protocol(Scheme) ->
    get({protocol, Scheme}).


%% @private
-spec get_protocol(nkpacket:domain(), nklib:scheme()) ->
    nkpacket:protocol() | undefined.

get_protocol(Domain, Scheme) ->
    case get({protocol, Domain, Scheme}) of
        undefined -> get({protocol, Scheme});
        Protocol -> Protocol
    end.


%% @doc Sets a config value.
-spec put(term(), term()) -> 
    ok.

put(Key, Val) -> 
    true = ets:insert(?MODULE, {Key, Val}),
    ok.


%% @doc Deletes a config value.
-spec del(term()) -> 
    ok.

del(Key) -> 
    true = ets:delete(?MODULE, Key),
    ok.


%% @doc Atomically increments or decrements a counter
-spec increment(term(), integer()) ->
    integer().

increment(Key, Count) ->
    ets:update_counter(?MODULE, Key, Count).


%% @private Default config values
-spec default_config() ->
    nklib:optslist().

default_config() ->
    [
        {global_max_connections, 1024}
    ].


%% @private Default config values
-spec domain_default_config() ->
    nklib:optslist().

domain_default_config() ->
    [
        {dns_cache_ttl, 30000},                 % msecs
        {udp_timeout, 30000},                   % 
        {tcp_timeout, 180000},                  % 
        {sctp_timeout, 180000},                 % 
        {ws_timeout, 180000},                   % 
        {http_timeout, 180000},                 % 
        {connect_timeout, 30000},               %
        {max_connections, 1024}                 % Per transport and Domain
    ].





%% ===================================================================
%% gen_server
%% ===================================================================

-record(state, {
}).


%% @private
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
        

%% @private 
-spec init(term()) ->
    nklib_util:gen_server_init(#state{}).

init([]) ->
    ets:new(?MODULE, [named_table, public, {read_concurrency, true}]),
    put(local_ips, nkpacket_util:get_local_ips()),
    AppEnv = application:get_all_env(nkpacket),
    Env1 = nklib_util:defaults(AppEnv, default_config()),
    Env2 = nklib_util:defaults(Env1, domain_default_config()),
    case parse_config(Env2, []) of
        {ok, Opts} ->
            lists:foreach(fun({K,V}) -> put(K, V) end, Opts),
            register_protocol(http, nkpacket_protocol_http),
            register_protocol(https, nkpacket_protocol_http),
            {ok, #state{}};
        {error, Error} ->
            lager:error("Config error: ~p", [Error]),
            error(config_error)
    end.


%% @private
-spec handle_call(term(), nklib_util:gen_server_from(), #state{}) ->
    nklib_util:gen_server_call(#state{}).

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.

%% @private
-spec handle_cast(term(), #state{}) ->
    nklib_util:gen_server_cast(#state{}).

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    nklib_util:gen_server_info(#state{}).

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    nklib_util:gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    nklib_util:gen_server_terminate().

terminate(_Reason, _State) ->  
    ok.



%% ===================================================================
%% Private
%% ===================================================================


% %% @private Save cache for speed log access
% put_log_cache(Domain, CtxId) ->
%     erlang:put(nkpacket_domain, Domain),
%     erlang:put(nkpacket_ctx_id, CtxId),
%     erlang:put(nkpacket_app_name, Domain:name()),
%     erlang:put(nkpacket_log_level, Domain:config_log_level()).


%% @private
parse_config([], Opts) ->
    {ok, Opts};

parse_config([Term|Rest], Opts) ->
    Op = case Term of
        {global_max_connections, Max} ->
            case is_integer(Max) andalso Max>=1 andalso Max=<1000000 of
                true -> update;
                false -> error
            end;
        {included_applications, _} ->
            skip;

        % Domain specific options
        {dns_cache_ttl, T} ->
            case is_integer(T) andalso T>=0 of
                true -> update;
                false -> error
            end;
        {udp_timeout, T} when is_integer(T), T>=1 -> 
            update;
        {udp_timeout, _} -> 
            error;
        {tcp_timeout, T} when is_integer(T), T>=1 -> 
            update;
        {tcp_timeout, _} -> 
            error;
        {sctp_timeout, T} when is_integer(T), T>=1 -> 
            update;
        {sctp_timeout, _} -> 
            error;
        {ws_timeout, T} when is_integer(T), T>=1 ->  
            update;
        {ws_timeout, _} -> 
            error;
        {http_timeout, T} when is_integer(T), T>=1 ->  
            update;
        {http_timeout, _} -> 
            error;
        {connect_timeout, T} when is_integer(T), T>=1 ->  
            update;
        {connect_timeout, _} -> 
            error;
        {max_connections, Max} when is_integer(Max), Max>=1, Max=<1000000 -> 
            update;
        {max_connections, _} -> 
            error;
        {certfile, File} -> 
            {update, nklib_util:to_list(File)};
        {keyfile, File} ->
            {update, nklib_util:to_list(File)};
        {local_host, auto} -> 
            update;
        {local_host, Host} -> 
            {update, nklib_util:to_host(Host)};
        {local_host6, auto} -> 
            update;
        {local_host6, Host} ->
            case nklib_util:to_ip(Host) of
                {ok, HostIp6} -> 
                    % Ensure it is enclosed in `[]'
                    {update, nklib_util:to_host(HostIp6, true)};
                error -> 
                    {update, nklib_util:to_binary(Host)}
            end;
        _ ->
            lager:warning("Ignoring config option ~p", [Term]),
            skip
    end,
    case Op of
        update -> 
            parse_config(Rest, [{element(1, Term), element(2, Term)}|Opts]);
        {update, Value} -> 
            parse_config(Rest, [{element(1, Term), Value}|Opts]);
        skip -> 
            parse_config(Rest, Opts);
        error when is_tuple(Term) ->
            {error, {invalid, element(1, Term)}};
        error ->
            {error, {invalid, Term}}
    end.


