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

-module(http_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-compile(nowarn_export_all).
-include_lib("eunit/include/eunit.hrl").
-include_lib("nklib/include/nklib.hrl").
-include_lib("kernel/include/file.hrl").
-include("nkpacket.hrl").

http_test_() ->
  	{setup, spawn, 
    	fun() -> 
    		ok = nkpacket_app:start(),
    		?debugMsg("Starting HTTP test")
		end,
		fun(_) -> 
			ok
		end,
	    fun(_) ->
		    [
				fun() -> basic() end,
				fun() -> https() end,
				fun() -> static() end
			]
		end
  	}.


basic() ->
	Port = test_util:get_port(tcp),
	{Ref1, M1, Ref2, M2, Ref3, M3} = test_util:reset_3(),
 	
 	Url1 = "<http://all:"++integer_to_list(Port)++"/test1>",
	{ok, _, Http1} = nkpacket:start_listener(Url1, M1#{protocol=>test_protocol, class=>dom1}),

 	Url2 = "<http://all:"++integer_to_list(Port)++"/test2/>",
	{ok, _, Http2} = nkpacket:start_listener(Url2, M2#{protocol=>test_protocol, class=>dom2}),

 	Url3 = "<http://0.0.0.0:"++integer_to_list(Port)++">",
	{ok, _, Http3} = nkpacket:start_listener(Url3, M3#{
		protocol => test_protocol,
		class => dom3,
		host => "localhost",
		path => "/test3/a"
	}),
	timer:sleep(100),

	[Listen1] = nkpacket:get_class_ids(dom1),
	{ok, #nkport{
		class    = dom1,
		transp   = http,
		local_ip = {0,0,0,0}, local_port= Port,
		listen_ip= {0,0,0,0}, listen_port= Port,
		protocol = test_protocol, pid=Http1, socket= CowPid,
		opts     = #{path := <<"/test1">>}
	}} = nkpacket:get_nkport(Listen1),
	[Listen2] = nkpacket:get_class_ids(dom2),
	{ok, #nkport{
		class    = dom2,
		transp   = http,
		local_ip = {0,0,0,0}, local_port= Port,
		listen_ip= {0,0,0,0}, listen_port= Port,
		pid      = Http2, socket= CowPid,
		opts     = #{path := <<"/test2">>}
	}} = nkpacket:get_nkport(Listen2),
	[Listen3] = nkpacket:get_class_ids(dom3),
	{ok, #nkport{
		class    = dom3,
		transp   = http,
		local_ip = {0,0,0,0}, local_port= Port,
		listen_ip= {0,0,0,0}, listen_port= Port,
		pid      = Http3, socket= CowPid,
		opts     = #{
				host := <<"localhost">>,
				path := <<"/test3/a">>
			}
	}} = nkpacket:get_nkport(Listen3),

	Gun = open(Port, tcp),
	{ok, 404, H1} = get(Gun, "/", []),
	<<"NkPACKET">> = nklib_util:get_value(<<"server">>, H1),

	{ok, 200, _, <<"Hello World!">>} = get(Gun, "/test1", []),
	receive {Ref1, http_init, P1} -> P1 after 1000 -> error(?LINE) end,

	{ok, 200, _, <<"Hello World!">>} = get(Gun, "/test2", []),
	receive {Ref2, http_init, P3} -> P3 after 1000 -> error(?LINE) end,

	{ok, 404, _} = get(Gun, "/test3", []),
	{ok, 404, _} = get(Gun, "/test3/a/1", []),
	{ok, 404, _} = get(Gun, "/test3", [{<<"host">>, <<"localhost">>}]),
	{ok, 200, _, _} = get(Gun, "/test3/a/1", [{<<"host">>, <<"localhost">>}]),
	receive {Ref3, http_init, P5} -> P5 after 1000 -> error(?LINE) end,


	% If we close the transport, NkPacket blocks access, but only for the next
	% connection
	ok = nkpacket:stop_listeners(Http3),
	timer:sleep(100),
	Gun2 = open(Port, tcp),
	{ok, 404, H4} = get(Gun2, "/test3/a/1", [{<<"host">>, <<"localhost">>}]),
	<<"NkPACKET">> = nklib_util:get_value(<<"server">>, H4),

	ok = nkpacket:stop_listeners(Http1),
	ok = nkpacket:stop_listeners(Http2),
	ok.


https() ->
	Port = test_util:get_port(tcp),
	{Ref1, M1} = test_util:reset_1(),
 	Url1 = "<https://all:"++integer_to_list(Port)++"/test1>",
	{ok, _, Http1} = nkpacket:start_listener(Url1, M1#{class=>dom4, protocol=>test_protocol}),

	Gun = open(Port, ssl),
	{ok, 200, _, <<"Hello World!">>} = get(Gun, "/test1", []),
	 receive {Ref1, http_init, P1} -> P1 after 1000 -> error(?LINE) end,
	{ok, 404, H1} = get(Gun, "/test2", []),
	<<"NkPACKET">> = nklib_util:get_value(<<"server">>, H1),
	ok = nkpacket:stop_listeners(Http1).


static() ->
	% nkpacket:stop_all(static),
	% timer:sleep(100),
	Port = 8123, %test_util:get_port(tcp),

 	Url1 = "http://all:"++integer_to_list(Port)++"/",
	{ok, _, S1} = nkpacket:start_listener(Url1, #{class=>dom5, protocol=>test_protocol}),

 	Url2 = "http://all:"++integer_to_list(Port)++"/1/2/",
	{ok, _, S2} = nkpacket:start_listener(Url2, #{class=>dom5, protocol=>test_protocol}),



	Gun = open(Port, tcp),

	Path = filename:join(code:priv_dir(nkpacket), "www"),
	{ok, 301, Hds1} = get(Gun, "/", []),
	<<"http://127.0.0.1:8123/index.html">> = nklib_util:get_value(<<"location">>, Hds1),
	{ok, 200, H1, <<"<!DOC", _/binary>>} = get(Gun, "/index.html", []),
	% Cowboy now only returns connection when necessary
	[
		% {<<"connection">>, <<"keep-alive">>},
		{<<"accept-ranges">>,<<"bytes">>},
		{<<"content-length">>, <<"211">>},
		{<<"content-type">>,<<"text/html">>},
		{<<"date">>, _},
		{<<"etag">>, Etag},
		{<<"last-modified">>, Date},
		{<<"server">>, <<"NkPACKET">>}
	] = lists:sort(H1),
	File1 = filename:join(Path, "index.html"),
	{ok, #file_info{mtime=Mtime, size=Size}} = file:read_file_info(File1, [{time, universal}]),
	Etag = <<$", (integer_to_binary(erlang:phash2({Size, Mtime}, 16#ffffffff)))/binary, $">>,
	Date = cowboy_clock:rfc1123(Mtime),

	%{ok, 400, _} = get(Gun, "../..", []),

	{ok, 403, _} = get(Gun, "/1/2/", []),
	{ok, 200, _, <<"<!DOC", _/binary>>} = get(Gun, "/1/2/index.html", []),
	{ok, 404, _} = get(Gun, "/1/2/index.htm", []),
	{ok, 200, H3, <<"file1.txt">>} = get(Gun, "/dir1/file1.txt", []),
	{ok, 200, H3, <<"file1.txt">>} = get(Gun, "/dir1/././file1.txt", []),
	lager:warning("Next warning about unathorized access is expected"),
	{ok, 400, _} = get(Gun, "/dir1/../../file1.txt", []),
	{ok, 200, H3, <<"file1.txt">>} = get(Gun, "/dir1/../dir1/file1.txt", []),
	[
		%{<<"connection">>, <<"keep-alive">>},
		{<<"accept-ranges">>,<<"bytes">>},
		{<<"content-length">>, <<"9">>},
		{<<"content-type">>, <<"application/octet-stream">>},
		{<<"date">>, _},
		{<<"etag">>, _},
		{<<"last-modified">>, _},
		{<<"server">>,<<"NkPACKET">>}
	] = lists:sort(H3),
	{ok, 200, H3, <<"file1.txt">>} = get(Gun, "/1/2/dir1/file1.txt", []),
%

	ok = nkpacket:stop_listeners(S1),

	timer:sleep(100),

	Gun2 = open(Port, tcp),
	{ok, 404, _} = get(Gun2, "/dir1/file1.txt", []),
	{ok, 200, _, <<"file1.txt">>} = get(Gun2, "/1/2/dir1/file1.txt", []),

	Url3 = "http://all:"++integer_to_list(Port)++"/1/2/",
	{ok, _, S3} = nkpacket:start_listener(Url3,
							#{class=>dom5, protocol=>test_protocol, path=>"/a/", host=>"localhost"}),
	{ok, 404, _} = get(Gun2, "/a/index.html", []),
	{ok, 200, _, _} = get(Gun2, "/a/index.html", [{<<"host">>, <<"localhost">>}]),
	{ok, 404, _} = get(Gun2, "/c/index.html", [{<<"host">>, <<"localhost">>}]),

	% Gun3 = open(Port, tcp),
	% {ok, 200, _, _} = get(Gun3, "/a/index.html", []),
	% {ok, 404, _} = get(Gun3, "/c/index.html", []),

	ok = nkpacket:stop_listeners(S2),
	ok = nkpacket:stop_listeners(S3),
	ok.



%%%%%%%% Util

open(Port, Transp) ->
	{ok, Gun} = gun:open("127.0.0.1", Port, #{transport=>Transp, retry=>0}),
	Gun.


get(Pid, Path, Hds) ->
	% Add [{<<"connection">>, <<"close">>}] to check Keep Alive
	Ref = gun:get(Pid, Path, Hds),
	receive
		{gun_response, _, Ref, fin, Code, RHds} -> 
			{ok, Code, RHds};
		{gun_response, _, Ref, nofin, Code, RHds} -> 
			receive 
				{gun_data, _, Ref, fin, Data} -> 
					{ok, Code, RHds, Data}
			after 1000 ->
				timeout
			end;
		{gun_error, _, Ref, Error} ->
			{error, Error}
	after 1000 ->
		{error, timeout}
	end.



