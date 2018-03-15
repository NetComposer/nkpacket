%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc Default implementation for HTTP1 clients
%% Expects parameter notify_pid in user's state
%% Will send messages {nkpacket_httpc_protocol, Ref, Term},
%% Term :: {head, Status, Headers} | {body, Body} | {chunk, Chunk}

-module(nkpacket_httpc_protocol).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
% -behaviour(nkpacket_protocol).

-export([sample/0]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_parse/3, conn_encode/3, conn_timeout/2]).

-include("nkpacket.hrl").
-include_lib("nklib/include/nklib.hrl").



-define(DEBUG(Txt, Args, NkPort),
    case erlang:get(nkpacket_debug) of
        true -> ?LLOG(debug, Txt, Args, NkPort);
        _ -> ok
    end).


-define(LLOG(Type, Txt, Args, NkPort),
    lager:Type("NkPACKET Conn HTTP ~p (~p) "++Txt,
        [NkPort#nkport.protocol, NkPort#nkport.transp|Args])).


%% ===================================================================
%% Protocol callbacks
%% ===================================================================


%%sample() ->
%%    Opts = #{
%%        monitor => self(),
%%        user_state => {notify_pid, self()},
%%        connect_timeout => 1000,
%%        idle_timeout => 60000,
%%        debug => true
%%    },
%%    {ok, P} = nkpacket:connect(<<"https://google.com">>, Opts),
%%    Ref = make_ref(),
%%    Msg = {http, Ref, <<"GET">>, <<"/">>, [], <<>>},
%%    {ok, _} = nkpacket:send(P, Msg),
%%    receive
%%        {nkpacket_httpc_protocol, Ref, {head, 302, _Hds}} -> ok
%%        after 5000 -> error(?LINE)
%%     end,
%%    receive
%%        {nkpacket_httpc_protocol, Ref, {body, <<"<HTML", _/binary>>}} -> ok
%%        after 5000 -> error(?LINE)
%%    end.


sample() ->
    Opts = #{
        monitor => self(),
        user_state => #{
            refresh_request => {get, <<"/">>, [{<<"host">>, <<"127.0.0.1:9000">>}], <<>>}
        },
        connect_timeout => 1000,
        idle_timeout => 5000,
        debug => true
    },
    {ok, P} = nkpacket:connect(<<"http://127.0.0.1:9000">>, Opts),
    Ref = make_ref(),
    Msg = {http, self(), Ref, <<"GET">>, <<"/">>, [{<<"host">>, <<"127.0.0.1:9000">>}], <<>>},
    {ok, _} = nkpacket:send(P, Msg).



%% ===================================================================
%% Protocol callbacks
%% ===================================================================


%% @private
-spec transports(nklib:scheme()) ->
	[nkpacket:transport()].

transports(_) -> [https, http].


default_port(http) -> 80;
default_port(https) -> 443.

-type refresh_req() ::
    {Method::binary(), Path::binary(), Hds::[{binary(), binary()}], Body::binary()}.

-record(state, {
    host :: binary(),
    refresh_req :: refresh_req() | undefined,
    headers :: [{binary(), binary()}],
    buff = <<>> :: binary(),
    streams2 = [] :: [{reference(), pid()}],
    next = head :: head | {body, non_neg_integer()} | chunked | stream
}).


%% @private
-spec conn_init(nkpacket:nkport()) ->
	{ok, #state{}}.

conn_init(NkPort) ->
	#nkport{remote_ip=Ip, remote_port=Port, opts=Opts} = NkPort,
    {ok, UserState} = nkpacket:get_user_state(NkPort),
	?DEBUG("protocol init", [], NkPort),
    RefreshReq = case maps:find(refresh_request, UserState) of
        {ok, {Method1, Path1, Hds1, Body1}} ->
            {http, refresh, none, nklib_util:to_upper(Method1), Path1, Hds1, Body1};
        error ->
            undefined
    end,
    Host = case maps:find(host, Opts) of
        {ok, Host0} ->
            <<Host0/binary, $:, (nklib_util:to_binary(Port))/binary>>;
        error ->
            <<(nklib_util:to_host(Ip))/binary, $:, (nklib_util:to_binary(Port))/binary>>
    end,
    Hds = [{to_bin(K), to_bin(V)} || {K, V} <- maps:get(headers, UserState, [])],
	State =
        #state{
        host = Host,
        refresh_req = RefreshReq,
        headers = Hds
    },
    {ok, State}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
	{ok, #state{}} | {stop, normal, #state{}}.

conn_parse(close, _NkPort, State) ->
	{ok, State};

conn_parse(Data, NkPort, State) ->
    handle(Data, NkPort, State).


%% @private
-spec conn_encode(term(), nkpacket:nkport(), #state{}) ->
	{ok, nkpacket:raw_msg(), #state{}} | {error, term(), #state{}} |
	{stop, Reason::term()}.

conn_encode({http, Ref, Pid, Method, Path, Hds, Body}, _NkPort, State) ->
	request(Ref, Pid, Method, Path, Hds, Body, State);

conn_encode({data, Ref, Data}, _NkPort, State) ->
	data(Ref, Data, State).

%% @doc This function is called when the idle_timer timeout fires
%% If not implemented, will stop the connection
%% If ok is returned, timer is restarted
-spec conn_timeout(nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_timeout(_NkPort, #state{refresh_req=undefined}=State) ->
    {stop, normal, State};

conn_timeout(_NkPort, #state{refresh_req=Refresh}=State) ->
    ?DEBUG("sending refresh", [], _NkPort),
    nkpacket_connection:send_async(self(), Refresh),
    {ok, State}.


%% ===================================================================
%% HTTP handle
%% ===================================================================

%% @private
-spec request(term(), pid()|none, binary(), binary(), list(), iolist(), #state{}) ->
	{ok, iolist(), #state{}}.

request(Ref, Pid, Method, Path, Hds, Body, State) ->
    #state{host=Host, headers=BaseHeaders, streams2=Streams} = State,
    Method2 = nklib_util:to_upper(Method),
    Path2 = to_bin(Path),
    Hds1 = [{to_bin(H), to_bin(V)} || {H, V} <- Hds] ++ BaseHeaders,
	Hds2 = [{<<"Host">>, Host}|Hds1],
    {Hds3, Body2} = case is_map(Body) orelse is_list(Body) of
		true ->
			{
				[{<<"Content-Type">>, <<"application/json">>}|Hds2],
				nklib_json:encode(Body)
			};
		false ->
			{Hds2, Body}
	end,
	BodySize = nklib_util:to_binary(iolist_size(Body2)),
	Hds4 = [{<<"Content-Length">>, BodySize}|Hds3],
	State2 = State#state{streams2 = Streams ++ [{Ref, Pid}]},
	RawMsg = cow_http:request(Method2, Path2, 'HTTP/1.1', Hds4),
	{ok, [RawMsg, Body2], State2}.


%% @private
-spec data(term(), iolist(), #state{}) ->
	{ok, iolist(), #state{}} | {error, invalid_ref, #state{}}.

data(_Ref, _Data, #state{streams2=[]}=State) ->
	{error, invalid_ref, State};

data(Ref, Data, #state{streams2=Streams}=State) ->
	case lists:last(Streams) of
		{Ref, _} ->
			{ok, Data, State};
		_ ->
			{error, invalid_ref, State}
	end.


-spec handle(binary(), #nkport{}, #state{}) ->
	{ok, #state{}} | {stop, term(), #state{}}.

handle(<<>>, _NkPort, State) ->
	{ok, State};

handle(_, _NkPort, #state{streams2=[]}=State) ->
	{stop, normal, State};

handle(Data, NkPort, #state{next=head, buff=Buff}=State) ->
	Data1 = << Buff/binary, Data/binary >>,
	case binary:match(Data1, <<"\r\n\r\n">>) of
		nomatch ->
			{ok, State#state{buff=Data1}};
		{_, _} ->
			handle_head(Data1, NkPort, State#state{buff = <<>>})
	end;

handle(Data, NkPort, #state{next={body, Length}}=State) ->
    ?DEBUG("parsing body: ~s", [Data], NkPort),
	#state{buff=Buff, streams2=[{Ref, Pid}|_]} = State,
	Data1 = << Buff/binary, Data/binary>>,
	case byte_size(Data1) of
		Length ->
			notify(Ref, Pid, {body, Data1}),
			{ok, do_next(State)};
		Size when Size < Length ->
			{ok, State#state{buff=Data1}};
		_ ->
			{Data2, Rest} = erlang:split_binary(Data1, Length),
			notify(Ref, Pid, {body, Data2}),
			handle(Rest, NkPort, do_next(State))
	end;

handle(Data, NkPort, #state{next=chunked}=State) ->
    ?DEBUG("parsing chunked: ~s", [Data], NkPort),
	#state{buff=Buff, streams2=[{Ref, Pid}|_]} = State,
	Data1 = << Buff/binary, Data/binary>>,
	case parse_chunked(Data1) of
		{data, <<>>, Rest} ->
			notify(Ref, Pid, {body, <<>>}),
			handle(Rest, NkPort, do_next(State));
		{data, Chunk, Rest} ->
			notify(Ref, Pid, {chunk, Chunk}),
			handle(Rest, NkPort, State#state{buff = <<>>});
		more ->
			{ok, State#state{buff=Data1}}
	end;

handle(Data, _NkPort, #state{next=stream, streams2=[{Ref, Pid}|_]}=State) ->
    ?DEBUG("parsing chunked: ~s", [Data], _NkPort),
	notify(Ref, Pid, {chunk, Data}),
	{ok, State}.


%% @private
-spec handle_head(binary(), #nkport{}, #state{}) ->
	{ok, #state{}}.

handle_head(Data, NkPort, #state{streams2=[{Ref, Pid}|_]}=State) ->
	{_Version, Status, _Msg, Rest} = cow_http:parse_status_line(Data),
    ?DEBUG("received head: ~s ~p ~s", [_Version, Status, _Msg], NkPort),
	{Hds, Rest2} = cow_http:parse_headers(Rest),
    ?DEBUG("received headeers: ~p", [Hds], NkPort),
	notify(Ref, Pid, {head, Status, Hds}),
	Remaining = case lists:keyfind(<<"content-length">>, 1, Hds) of
		{_, <<"0">>} ->
			0;
		{_, Length} ->
			cow_http_hd:parse_content_length(Length);
		false when Status==204; Status==304 ->
			0;
		false ->
			case lists:keyfind(<<"transfer-encoding">>, 1, Hds) of
				false ->
					stream;
				{_, TE} ->
					case cow_http_hd:parse_transfer_encoding(TE) of
						[<<"chunked">>] -> chunked;
						[<<"identity">>] -> 0
					end
			end
	end,
    ?DEBUG("remaining: ~p", [Remaining], NkPort),
	State1 = case Remaining of
		0 ->
			notify(Ref, Pid, {body, <<>>}),
			do_next(State);
		chunked ->
			State#state{next=chunked};
		stream ->
			State#state{next=stream};
		_ ->
			State#state{next={body, Remaining}}
	end,
	handle(Rest2, NkPort, State1).



%% @private
-spec parse_chunked(binary()) ->
	{ok, binary(), binary()} | more.

parse_chunked(S) ->
	case find_chunked_length(S, []) of
		{ok, Length, Data} ->
			FullLength = Length + 2,
			case byte_size(Data) of
				FullLength ->
					<<Data1:Length/binary, "\r\n">> = Data,
					{data, Data1, <<>>};
				Size when Size < FullLength ->
					more;
				_ ->
					{Data1, Rest} = erlang:split_binary(Data, FullLength),
					<<Data2:Length/binary, "\r\n">> = Data1,
					{data, Data2, Rest}
			end;
		more ->
			more
	end.


%% @private
-spec find_chunked_length(binary(), string()) ->
	{ok, integer(), binary()} | more.

find_chunked_length(<<C, "\r\n", Rest/binary>>, Acc) ->
	{V, _} = lists:foldl(
		fun(Ch, {Sum, Mult}) ->
			if
				Ch >= $0, Ch =< $9 -> {Sum + (Ch-$0)*Mult, 16*Mult};
				Ch >= $a, Ch =< $f -> {Sum + (Ch-$a+10)*Mult, 16*Mult};
				Ch >= $A, Ch =< $F -> {Sum + (Ch-$A+10)*Mult, 16*Mult}
			end
		end,
		{0, 1},
		[C|Acc]),
	{ok, V, Rest};

find_chunked_length(<<C, Rest/binary>>, Acc) ->
	find_chunked_length(Rest, [C|Acc]);

find_chunked_length(<<>>, _Acc) ->
	more.


%% @private
notify(Ref, Pid, Term) when is_pid(Pid) ->
    Pid ! {nkpacket_httpc_protocol, Ref, Term};

notify(_Ref, _Pid, _Term) ->
    ok.


%% @private
do_next(#state{streams2=[_|Rest]}=State) ->
	State#state{next=head, buff= <<>>, streams2=Rest}.


%% @private
to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) -> nklib_util:to_binary(Term).






