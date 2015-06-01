%% -------------------------------------------------------------------
%%
%% Based on cowboy_static.erl
%%
%% -------------------------------------------------------------------

-module(nkpacket_cowboy_static).

-export([init/2]).
-export([malformed_request/2, forbidden/2, content_types_provided/2, 
		 resource_exists/2, last_modified/2, generate_etag/2, get_file/2]).
-export_type([opts/0]).

-type opts() ::
	#{
		path => string() | binary(),
		index_file => string() | binary(),
		etag => true | false | {module(), function()},
		mimetypes => web | all | {module(), function()}
	}.

-include_lib("kernel/include/file.hrl").

-type state() :: {opts(), #file_info{}} | {error, atom()}.


-compile(export_all).

%% ===================================================================
%% Callbacks
%% ===================================================================

%% @doc Module initialization
-spec init(cowboy_req:req(), opts()) -> 
	{cowboy_rest, cowboy_req:req(), state()}.

init(Req, #{path:=DirPath}=Opts) ->
	Req1 = cowboy_req:set_resp_header(<<"server">>, <<"NkPACKET">>, Req),
	PathInfo = cowboy_req:path_info(Req),
	FilePath = nklib_parse:fullpath(filename:join([DirPath|PathInfo])),
	DirPathSize = byte_size(DirPath),
	%% Check we don't go outside DirPath
	case FilePath of
		<<DirPath:DirPathSize/binary, _/binary>> ->
			init_file(Req1, Opts, FilePath);
		_ ->
			lager:warning("Client trying to access ~s", [FilePath]),
			{cowboy_rest, Req1, {error, malformed}}
	end.


%% @private
-spec init_file(cowboy_req:req(), opts(), binary()) -> 
	{cowboy_rest, cowboy_req:req(), state()}.

init_file(Req, Opts, FilePath) ->
	lager:debug("Static web server looking for ~s", [FilePath]),
	case file:read_file_info(FilePath, [{time, universal}]) of
		{ok, #file_info{type=directory}} ->
			case maps:get(index_file, Opts, undefined) of
				undefined -> 
					{cowboy_rest, Req, {error, forbidden}};
				Index ->
					FilePath1 = filename:join(FilePath, Index),
					init_file(Req, Opts#{index_file:=undefined}, FilePath1)
			end;
		{ok, Info} ->
			{cowboy_rest, Req, {Opts#{path:=FilePath}, Info}};
		{error, enoent} ->
			{cowboy_rest, Req, {error, not_found}};
		_ ->
			{cowboy_rest, Req, {error, forbidden}}
	end.


%% @private
-spec malformed_request(cowboy_req:req(), state()) ->
	{boolean(), cowboy_req:req(), state()}.

malformed_request(Req, {error, malformed}=State) ->
	{true, Req, State};
malformed_request(Req, State) ->
	{false, Req, State}.


%% @private
-spec forbidden(cowboy_req:req(), state()) ->
	{boolean(), cowboy_req:req(), state()}.

forbidden(Req, {error, forbidden}=State) ->
	{true, Req, State};
forbidden(Req, {_, #file_info{access=Access}}=State) when Access==write; Access==none ->
	{true, Req, State};
forbidden(Req, State) ->
	{false, Req, State}.


%% @private Detect the mimetype of the file.
-spec content_types_provided(cowboy_req:req(), state()) ->
	{[{binary(), get_file}], cowboy_req:req(), state()}.
	
content_types_provided(Req, {#{path:=Path}=Opts, _Info}=State) ->
	case maps:get(mimetypes, Opts, all) of
		all ->
			{[{cow_mimetypes:all(Path), get_file}], Req, State};
		web ->
			{[{cow_mimetypes:web(Path), get_file}], Req, State};
		{Module, Function} ->
			{[{Module:Function(Path), get_file}], Req, State}
	end;
content_types_provided(Req, {error, _}=State) ->
	{[{{<<"text">>,<<"plain">>,[]}, get_file}], Req, State}.


%% @private Assume the resource doesn't exist if it's not a regular file.
-spec resource_exists(cowboy_req:req(), state()) ->
	{boolean(), cowboy_req:req(), state()}.

resource_exists(Req, {error, not_found}=State) ->
	{false, Req, State};
resource_exists(Req, {_, #file_info{type=regular}}=State) ->
	{true, Req, State};
resource_exists(Req, State) ->
	{false, Req, State}.


%% @private Generate an etag for the file.
-spec generate_etag(cowboy_req:req(), state()) ->
	{{strong | weak, binary()}, cowboy_req:req(), state()}.

generate_etag(Req, {Opts, Info}=State) ->
	case maps:get(etag, Opts, true) of
		true ->
			#file_info{size=Size, mtime=Mtime} = Info,
			{generate_default_etag(Size, Mtime), Req, State};
		false ->
			{undefined, Req, State};
		{Module, Function} ->
			#{path:=Path} = Opts,
			#file_info{size=Size, mtime=Mtime} = Info,
			{Module:Function(Path, Size, Mtime), Req, State}
	end.


%% @private
generate_default_etag(Size, Mtime) ->
	{strong, integer_to_binary(erlang:phash2({Size, Mtime}, 16#ffffffff))}.


%% @doc Return the time of last modification of the file.
-spec last_modified(cowboy_req:req(), state()) ->
	{calendar:datetime(), cowboy_req:req(), state()}.

last_modified(Req, {_Opts, #file_info{mtime=Modified}}=State) ->
	{Modified, Req, State}.


%% @doc Stream the file.
-spec get_file(cowboy_req:req(), state()) ->
	{{stream, non_neg_integer(), fun()}, cowboy_req:req(), state()}.

get_file(Req, {#{path:=Path}, #file_info{size=Size}}=State) ->
	Sendfile = fun(Socket, Transport) ->
		case Transport:sendfile(Socket, Path) of
			{ok, _} -> ok;
			{error, closed} -> ok;
			{error, etimedout} -> ok
		end
	end,
	{{stream, Size, Sendfile}, Req, State}.



%% ===================================================================
%% Internal
%% ===================================================================





