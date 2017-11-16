%% -------------------------------------------------------------------
%% Heavily based on gun_http.erl and gun_ws.erl
%% Copyright (c) 2016, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
%% -------------------------------------------------------------------

%% @doc WS Connection Library Functions
-module(nkpacket_connection_ws).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_handshake/1, init/1, handle/2, encode/1]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


-define(DEBUG(Txt, Args),
    case erlang:get(nkpacket_debug) of
        true -> ?LLOG(debug, Txt, Args);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args), 
        lager:Type("NkPACKET Conn "++Txt, Args)).


-record(payload, {
    type = undefined :: cow_ws:frame_type(),
    rsv = undefined :: cow_ws:rsv(),
    len = undefined :: non_neg_integer(),
    mask_key = undefined :: cow_ws:mask_key(),
    close_code = undefined :: undefined | cow_ws:close_code(),
    unmasked = <<>> :: binary(),
    unmasked_len = 0 :: non_neg_integer()
}).

-record(ws_state, {
    buffer = <<>> :: binary(),
    in = head :: head | #payload{} | close,
    frag_state = undefined :: cow_ws:frag_state(),
    frag_buffer = <<>> :: binary(),
    utf8_state = 0 :: cow_ws:utf8_state(),
    extensions = #{} :: cow_ws:extensions()
}).



%% ===================================================================
%% Handshake
%% ===================================================================

-spec start_handshake(#nkport{}) ->
    {ok, binary()|undefined, binary()} | {error, term()}.

start_handshake(NkPort) ->
    #nkport{
        transp = Transp, 
        socket = Socket
    } = NkPort,
    {ok, Req, Key} = get_handshake_req(NkPort),
    TranspMod = case Transp of
        ws -> ranch_tcp;
        wss -> ranch_ssl
    end,
    ?DEBUG("sending ws request: ~s", [print_headers(list_to_binary(Req))]),
    case TranspMod:send(Socket, Req) of
        ok ->
            case recv(TranspMod, Socket, <<>>) of
                {ok, Data} ->
                    ?DEBUG("received ws reply: ~s", [print_headers(Data)]),
                    case get_handshake_resp(Data, Key) of
                        {ok, WsProto, Rest} ->
                            {ok, WsProto, Rest};
                        close ->
                            {error, closed}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
get_handshake_req(#nkport{remote_ip=Ip, remote_port=Port, opts=Meta}) ->
    Host = case maps:get(host, Meta, undefined) of
        undefined -> nklib_util:to_host(Ip);
        Host0 -> Host0
    end,
    Path = maps:get(path, Meta),
    Key = cow_ws:key(),
    Headers2 = [
        {<<"Host">>, [Host, $:, integer_to_binary(Port)]},
        {<<"Connection">>, <<"Upgrade">>},
        {<<"Upgrade">>, <<"websocket">>},
        {<<"Sec-WebSocket-Version">>, <<"13">>},
        {<<"Sec-WebSocket-Key">>, Key}
    ],
    Headers3 = case maps:get(ws_proto, Meta, undefined) of
        undefined -> 
            Headers2;
        WsProto -> 
            [
                {<<"sec-websocket-protocol">>, nklib_util:to_binary(WsProto)}
                | Headers2
            ]
    end,
    Headers4 = Headers3 ++ maps:get(headers, Meta, []),
    Req = cow_http:request(<<"GET">>, Path, 'HTTP/1.1', Headers4),
    {ok, Req, Key}.
    

%% @private
get_handshake_resp(Data, Key) ->
    {_Version, _Status, _, Rest} = cow_http:parse_status_line(Data),
    {Headers, Rest2} = cow_http:parse_headers(Rest),
    WsProto = case lists:keyfind(<<"sec-websocket-protocol">>, 1, Headers) of
        false -> undefined;
        {_, WsProto0} -> WsProto0
    end,
    case lists:keyfind(<<"sec-websocket-accept">>, 1, Headers) of
        false ->
            close;
        {_, Accept} ->
            case cow_ws:encode_key(Key) of
                Accept ->
                    {ok, WsProto, Rest2};
                _ -> 
                    close
            end
    end.


%% ===================================================================
%% Incoming
%% ===================================================================

%% @private
-spec init(cow_ws:extensions()) ->
    #ws_state{}.

init(Exts) ->
    #ws_state{extensions=Exts}.


%% @private
-spec handle(binary(), #ws_state{}) ->
    {ok, #ws_state{}} |
    {data, cow_ws:frame(), Rest::binary(), #ws_state{}} |
    {reply, cow_ws:frame(), Rest::binary(), #ws_state{}} |
    close.

%% Do not handle anything if we received a close frame.
handle(_, State=#ws_state{in=close}) ->
    {ok, State};

%% Shortcut for common case when Data is empty after processing a frame.
handle(<<>>, State=#ws_state{in=head}) ->
    {ok, State};

handle(Data, #ws_state{in=head}=State) ->
    #ws_state{buffer=Buffer, frag_state=FragState, extensions=Exts} = State,
    Data2 = << Buffer/binary, Data/binary >>,
    case cow_ws:parse_header(Data2, Exts, FragState) of
        {Type, FragState2, Rsv, Len, MaskKey, Rest} ->
            In = #payload{type=Type, rsv=Rsv, len=Len, mask_key=MaskKey},
            State1 = State#ws_state{buffer= <<>>, in=In, frag_state=FragState2},
            handle(Rest, State1);
        more ->
            {ok, State#ws_state{buffer=Data2}};
        error ->
            close({error, badframe}, State)
    end;

handle(Data, State) ->
    #ws_state{
        in = In,
        frag_state = FragState, 
        utf8_state = Utf8State, 
        extensions = Exts
    } = State,
    #payload{
        type = Type, 
        rsv = Rsv, 
        len = Len, 
        mask_key = MaskKey,
        close_code = CloseCode, 
        unmasked = Unmasked, 
        unmasked_len = UnmaskedLen
    } = In,
    case 
        cow_ws:parse_payload(Data, MaskKey, Utf8State, UnmaskedLen, Type, 
                             Len, FragState, Exts, Rsv) 
    of
        {ok, CloseCode2, Payload, Utf8State2, Rest} ->
            State1 = State#ws_state{in=head, utf8_state=Utf8State2},
            Data1 = << Unmasked/binary, Payload/binary >>,
            dispatch(Rest, State1, Type, Data1, CloseCode2);
        {ok, Payload, Utf8State2, Rest} ->
            State1 = State#ws_state{in=head, utf8_state=Utf8State2},
            Data1 = << Unmasked/binary, Payload/binary >>,
            dispatch(Rest, State1, Type, Data1, CloseCode);
        {more, CloseCode2, Payload, Utf8State2} ->
            In1 = In#payload{
                close_code = CloseCode2, 
                unmasked = << Unmasked/binary, Payload/binary >>,
                len = Len - byte_size(Data), 
                unmasked_len =2 + byte_size(Data)
            }, 
            {ok, State#ws_state{in=In1, utf8_state=Utf8State2}};
        {more, Payload, Utf8State2} ->
            In1 = In#payload{
                unmasked= << Unmasked/binary, Payload/binary >>,
                len = Len - byte_size(Data), 
                unmasked_len = UnmaskedLen + byte_size(Data)
            },
            {ok, State#ws_state{in=In1, utf8_state=Utf8State2}};
        {error, _Reason} = Error ->
            close(Error, State)
    end.


%% @private
dispatch(Rest, State, Type0, Payload0, CloseCode0) ->
    #ws_state{frag_state=FragState, frag_buffer=SoFar} = State,
    case cow_ws:make_frame(Type0, Payload0, CloseCode0, FragState) of
        {fragment, nofin, _, Payload} ->
            Frag1 = << SoFar/binary, Payload/binary >>,
            handle(Rest, State#ws_state{frag_buffer=Frag1});
        {fragment, fin, Type, Payload} ->
            Data1 = << SoFar/binary, Payload/binary >>,
            State1 = State#ws_state{frag_state=undefined, frag_buffer= <<>>},
            {data, {Type, Data1}, Rest, State1};
        ping ->
            {reply, pong, Rest, State};
        {ping, Payload} ->
            {reply, {pong, Payload}, Rest, State};
        pong ->
            {data, pong, Rest, State};
        {pong, Payload} ->
            {data, {pong, Payload}, Rest, State};
        close ->
            close;
        {close, _, _} ->
            close;
        Frame ->
            {data, Frame, Rest, State}
    end.


%% @private
-spec close({error, badframe|badencoding}, #ws_state{}) ->
    {reply, cow_ws:frame(), binary(), #ws_state{}}.

close(Reason, State) ->
    case Reason of
        % stop ->
        %     {reply, {close, 1000, <<>>}, <<>>, State};
        % timeout ->
        %     {reply, {close, 1000, <<>>}, <<>>, State};
        {error, badframe} ->
            {reply, {close, 1002, <<>>}, <<>>, State};
        {error, badencoding} ->
            {reply, {close, 1007, <<>>}, <<>>, State}
    end.


%% ===================================================================
%% Send
%% ===================================================================

%% @private
-spec encode(cow_ws:frame()) ->
    binary().

encode(Frame) ->
    cow_ws:masked_frame(Frame, #{}).




%% ===================================================================
%% Util
%% ===================================================================


%% @private
recv(Mod, Socket, Buff) ->
    case Mod:recv(Socket, 0, 5000) of
        {ok, Data} ->
            Data1 = <<Buff/binary, Data/binary>>,
            case binary:match(Data, <<"\r\n\r\n">>) of
                nomatch -> 
                    recv(Mod, Socket, Data1);
                _ ->
                    {ok, Data1}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% private 
print_headers(Binary) ->
    Lines = [
        [<<"        ">>, Line, <<"\n">>]
        || Line <- binary:split(Binary, <<"\r\n">>, [global])
    ],
    list_to_binary(io_lib:format("\r\n\r\n~s\r\n", [list_to_binary(Lines)])).

