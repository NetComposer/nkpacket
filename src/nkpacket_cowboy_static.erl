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

-type state() :: {file, #file_info{}, opts()} | {error, atom()}.


-define(LOG(Txt, List), lager:notice("Webserver "++Txt, List)).


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
	%% Check we don't go outside DirPath
	DirPathSize = byte_size(DirPath),
	case FilePath of
		<<DirPath:DirPathSize/binary, _/binary>> ->
			IsDir = binary:last(cowboy_req:url(Req)) == $/,
			init_file(Req1, Opts, FilePath, IsDir);
		_ ->
			lager:warning("Webserver trying to access forbidden ~s", [FilePath]),
			{cowboy_rest, Req1, {error, malformed}}
	end.


%% @private
-spec init_file(cowboy_req:req(), opts(), binary(), boolean()) -> 
	{cowboy_rest, cowboy_req:req(), state()}.

init_file(Req, Opts, FilePath, IsDir) ->
	case file:read_file_info(FilePath, [{time, universal}]) of
		{ok, #file_info{type=directory}} when IsDir ->
			case maps:get(index_file, Opts, undefined) of
				undefined -> 
					lager:debug("Webserver didn't allow directory ~s", [FilePath]),
					{cowboy_rest, Req, {error, forbidden}};
				Index ->
					FilePath2 = <<FilePath/binary, "/", Index/binary>>,
					lager:debug("Webserver sending index file ~s", [FilePath2]),
					init_file(Req, maps:remove(index_file, Opts), FilePath2, false)
			end;
		{ok, #file_info{type=directory}} when not IsDir ->
			Url = <<(cowboy_req:url(Req))/binary, "/">>,
			lager:debug("Webserver sent redirect to ~s", [Url]),
			Req2 = cowboy_req:set_resp_header(<<"location">>, Url, Req),
			Req3 = cowboy_req:reply(301, Req2),
			{ok, Req3, Opts};
		{ok, #file_info{}=File} ->
			lager:debug("Webserver found file ~s", [FilePath]),
			{cowboy_rest, Req, {file, File, Opts#{path:=FilePath}}};
		{error, enoent} ->
			lager:info("Webserver didn't find file ~s", [FilePath]),
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
forbidden(Req, {file, #file_info{access=Access}, _}=State) 
		when Access==write; Access==none ->
	{true, Req, State};
forbidden(Req, State) ->
	{false, Req, State}.


%% @private Detect the mimetype of the file.
-spec content_types_provided(cowboy_req:req(), state()) ->
	{[{binary(), get_file}], cowboy_req:req(), state()}.
	
content_types_provided(Req, {file, _, #{path:=Path}=Opts}=State) ->
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
resource_exists(Req, {file, #file_info{type=regular}, _}=State) ->
	{true, Req, State};
resource_exists(Req, State) ->
	{false, Req, State}.


%% @private Generate an etag for the file.
-spec generate_etag(cowboy_req:req(), state()) ->
	{{strong | weak, binary()}, cowboy_req:req(), state()}.

generate_etag(Req, {file, File, Opts}=State) ->
	case maps:get(etag, Opts, true) of
		true ->
			#file_info{size=Size, mtime=Mtime} = File,
			{generate_default_etag(Size, Mtime), Req, State};
		false ->
			{undefined, Req, State};
		{Module, Function} ->
			#{path:=Path} = Opts,
			#file_info{size=Size, mtime=Mtime} = File,
			{Module:Function(Path, Size, Mtime), Req, State}
	end.


%% @private
generate_default_etag(Size, Mtime) ->
	{strong, integer_to_binary(erlang:phash2({Size, Mtime}, 16#ffffffff))}.


%% @doc Return the time of last modification of the file.
-spec last_modified(cowboy_req:req(), state()) ->
	{calendar:datetime(), cowboy_req:req(), state()}.

last_modified(Req, {file, #file_info{mtime=Modified}, _}=State) ->
	{Modified, Req, State}.


%% @doc Stream the file.
-spec get_file(cowboy_req:req(), state()) ->
	{{stream, non_neg_integer(), fun()}, cowboy_req:req(), state()}.

get_file(Req, {file, #file_info{size=Size}, #{path:=Path}}=State) ->
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




% join(Req, Index) ->
% 	Url1 = cowboy_req:url(Req),
% 	Url2 = case byte_size(Url1) of
% 		0 ->
% 			<<"/">>;
% 		Size ->
% 			case binary:at(Url1, Size-1) of
% 				$/ -> Url1;
% 				_ -> <<Url1/binary, "/">>
% 			end
% 	end,
% 	<<Url2/binary, Index/binary>>.