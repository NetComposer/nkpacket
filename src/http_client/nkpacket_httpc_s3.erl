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


-module(nkpacket_httpc_s3).
-export([get_object/3, put_object/4, make_get_url/4, make_put_url/5]).


-include_lib("nklib/include/nklib.hrl").



%% ===================================================================
%% Public
%% ===================================================================


-type acl() ::
	private | public_read | public_read_write | authenticated_read |
	bucket_owner_read | bucket_owner_full_control.


-type config() ::
	#{
		key_id => binary(),
		key => binary(),
		host => binary(),
		access_method => path | vhost,
		acl => acl(),
		headers => [{iolist(), iolist()}],
		params => [{iolist(), iolist()}],
		meta => [{iolist(), iolist()}]
	}.



%% @doc
%% Valid Headers:
%% - range
%% - if-modified-since
%% - if-unmodified-since
%% - if-match
%% - if-none-match
%% - x-amz-server-side-encryption-customer-algorithm
%% - x-amz-server-side-encryption-customer-key
%% - x-amz-server-side-encryption-customer-key-md5
%%
%% Valid parameters
%% - versionId
%%
%% Path must start with /

-spec get_object(binary(), binary(), config()) ->
	{Uri::binary(), Path::binary(), Headers::[{binary(), binary()}]}.

get_object(Bucket, Path, Config) ->
	s3_request(get, Bucket, Path, <<>>, Config).



%% @doc
%% Valid Headers:
%% - content-type
%%
%% Can Use meta and acl
%% Path must start with /

-spec put_object(binary(), binary(), iolist(), config()) ->
	{Uri::binary(), Path::binary(), Headers::[{binary(), binary()}]}.

put_object(Bucket, Path, Body, Config) ->
	Headers1 = maps:get(headers, Config, []),
	Headers2 = case maps:find(acl, Config) of
		{ok, ACL} ->
			ACL2 = case ACL of
				private -> <<"private">>;
				public_read -> <<"public-read">>;
				public_read_write -> <<"public-read-write">>;
				authenticated_read -> <<"authenticated-read">>;
				bucket_owner_read -> <<"bucket-owner-read">>;
				bucket_owner_full_control -> <<"bucket-owner-full-control">>
			end,
			[{<<"x-amz-acl">>, ACL2} | Headers1];
		error ->
			Headers1
	end,
	Headers3 = case maps:find(meta, Config) of
		{ok, Meta} ->
			[
				{
					<<"x-amz-meta-", (nklib_util:to_lower(Key))/binary>>,
					to_bin(Val)
				}
				||
				{Key, Val} <- Meta
			] ++ Headers2;
		error ->
			Headers2
	end,
	Body2 = iolist_to_binary(Body),
	Config2 = Config#{headers=>Headers3},
	s3_request(put, Bucket, Path, Body2, Config2).


%% @doc Generates an URL-like access for read
-spec make_get_url(binary(),  binary(), integer(), config()) ->
	binary().

make_get_url(Bucket, Path, ExpireSecs, Config) ->
	Expires = to_bin(nklib_util:timestamp() + ExpireSecs),
	Path2 = list_to_binary([$/, Bucket, Path]),
	ToSign = list_to_binary(["GET\n\n\n", Expires, $\n, Path2]),
	#{key_id:=KeyId, key:=Key} = Config,
	Enc = base64:encode(crypto:hmac(sha, Key, ToSign)),
	Qs = list_to_binary([
		"?AWSAccessKeyId=", url_encode(KeyId),
		"&Signature=", url_encode(Enc),
		"&Expires=", Expires
	]),
	{Uri, _Domain} = get_uri(Config),
	<<Uri/binary, Path2/binary, Qs/binary>>.


%% @doc Generates an URL-like access for write
-spec make_put_url(binary(),  binary(), binary(), integer(), config()) ->
	binary().

make_put_url(Bucket, Path, CT, ExpireSecs, Config) ->
	Expires = to_bin(nklib_util:timestamp() + ExpireSecs),
	Path2 = list_to_binary([$/, Bucket, Path]),
	ToSign = list_to_binary(["PUT\n\n", CT, $\n, Expires, $\n, Path2]),
	#{key_id:=KeyId, key:=Key} = Config,
	Enc = base64:encode(crypto:hmac(sha, Key, ToSign)),
	Qs = list_to_binary([
		"?AWSAccessKeyId=", url_encode(KeyId),
		"&Signature=", url_encode(Enc),
		"&Expires=", Expires
	]),
	{Uri, _Domain} = get_uri(Config),
	<<Uri/binary, Path2/binary, Qs/binary>>.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private
s3_request(Method, Bucket, Path, Body, Config) ->
	Headers1 = maps:get(headers, Config, []),
	{Uri, Domain} = get_uri(Config),
	AccessMethod = maps:get(access_method, Config, path),
	{Host2, Path2} =  case AccessMethod of
		vhost ->
			%% Add bucket name to the front of hostname,
			%% i.e. https://bucket.name.s3.amazonaws.com/<path>
			{
				list_to_binary([Bucket, $., Domain]),
				url_encode_loose(Path)
			};
		path ->
			%% Add bucket name into a URL path
			%% i.e. https://s3.amazonaws.com/bucket/<path>
			{
				Domain,
				list_to_binary([$/, Bucket, Path])
			}
	end,
	Region = case binary:split(nklib_util:to_binary(Domain), <<".amazonaws.com">>) of
		[<<"s3-", Zone/binary>>, <<>>] ->
			Zone;
		[<<"s3.", Zone/binary>>, <<>>] ->
			Zone;
		_ ->
			<<"us-east-1">>
	end,
	Headers2 = [{<<"host">>, Host2} | Headers1],
	Config2 = Config#{region=>Region, service=><<"s3">>, headers=>Headers2},
	{RequestQS, RequestHeaders} = sign_v4(Method, Path2, Body, Config2),
	Path3 = list_to_binary([
		Path2,
		case RequestQS of
			<<>> ->
				<<>>;
			_ ->
				[$?, RequestQS]
		end
	]),
	{Uri, Path3, RequestHeaders}.


%% @private
get_uri(Config) ->
	Host = maps:get(host, Config),
	[#uri{scheme=Scheme, domain=Domain, port=Port}] = nklib_parse:uris(Host),
	URI = list_to_binary([
		case Scheme of
			http -> <<"http://">>;
			https -> <<"https://">>
		end,
		Domain,
		case Port of
			0 ->
				<<>>;
			_ ->
				[$:, nklib_util:to_binary(Port)]
		end
	]),
	{URI, Domain}.



%% @private
sign_v4(Method, Uri, Body, Config) ->
	Headers1 = maps:get(headers, Config, []),
	QueryParams1 = maps:get(params, Config, []),
	Date = iso_8601_basic_time(),
	BodyHash = nklib_util:hex(crypto:hash(sha256, Body)),
	Headers2 = [
		{"x-amz-date", Date},
		{"x-amz-content-sha256", BodyHash}
		| Headers1
	],
	NormHeaders = [
		{nklib_util:to_lower(Name), nklib_util:to_binary(Value)}
		|| {Name, Value} <- Headers2
	],
	SortedHeaders = lists:keysort(1, NormHeaders),
	CanonicalHeaders = [[Name, $:, Value, $\n] || {Name, Value} <- SortedHeaders],
	SignedHeaders = nklib_util:bjoin([Name || {Name, _} <- SortedHeaders], <<";">>),
	NormalizedQS = [
		<<(url_encode(Name))/binary, $=, (url_encode(value_to_string(Value)))/binary>>
		|| {Name, Value} <- QueryParams1
	],
	CanonicalQueryString = nklib_util:bjoin(lists:sort(NormalizedQS), <<"&">>),
	Request = [
		nklib_util:to_upper(Method), $\n,
		Uri, $\n,
		CanonicalQueryString, $\n,
		CanonicalHeaders, $\n,
		SignedHeaders, $\n,
		BodyHash
	],
	Service = maps:get(service, Config, <<"s3">>),
	Region = maps:get(region, Config, <<"eu-west-1">>),
	<<Date2:8/binary, _/binary>> = Date,
	CredentialScope = [Date2, $/, Region, $/, Service, "/aws4_request"],
	ToSign = [
		<<"AWS4-HMAC-SHA256\n">>,
		Date, $\n,
		CredentialScope, $\n,
		nklib_util:hex(crypto:hash(sha256, Request))
	],
	KeyId = maps:get(key_id, Config),
	Key = maps:get(key, Config),
	KDate = crypto:hmac(sha256, <<"AWS4", Key/binary>>, Date2),
	KRegion = crypto:hmac(sha256, KDate, Region),
	KService = crypto:hmac(sha256, KRegion, Service),
	SigningKey = crypto:hmac(sha256, KService, <<"aws4_request">>),
	Signature = nklib_util:hex(crypto:hmac(sha256, SigningKey, ToSign)),
	Auth = list_to_binary(lists:flatten([
		<<"AWS4-HMAC-SHA256">>,
		<<" Credential=">>, KeyId, $/, CredentialScope, $,,
		<<" SignedHeaders=">>, SignedHeaders, $,,
		<<" Signature=">>, Signature
	])),
	{CanonicalQueryString, [{<<"authorization">>, Auth} | NormHeaders]}.


%% @private
iso_8601_basic_time() ->
	{{Year,Month,Day},{Hour,Min,Sec}} = calendar:now_to_universal_time(os:timestamp()),
	list_to_binary(io_lib:format(
		"~4.10.0B~2.10.0B~2.10.0BT~2.10.0B~2.10.0B~2.10.0BZ",
		[Year, Month, Day, Hour, Min, Sec])).


%% @private
value_to_string(Integer) when is_integer(Integer) ->
	integer_to_list(Integer);

value_to_string(Atom) when is_atom(Atom) ->
	atom_to_list(Atom);

value_to_string(Binary) when is_binary(Binary) ->
	Binary;

value_to_string(String) when is_list(String) ->
	unicode:characters_to_binary(String).


%% @private
url_encode(Binary) when is_binary(Binary) ->
	url_encode(unicode:characters_to_list(Binary));

url_encode(String) ->
	url_encode(String, []).

url_encode([], Acc) ->
	list_to_binary(lists:reverse(Acc));

url_encode([Char|String], Acc)
	when Char >= $A, Char =< $Z;
	Char >= $a, Char =< $z;
	Char >= $0, Char =< $9;
	Char =:= $-; Char =:= $_;
	Char =:= $.; Char =:= $~ ->
	url_encode(String, [Char|Acc]);

url_encode([Char|String], Acc) ->
	url_encode(String, utf8_encode_char(Char) ++ Acc).

%% @private
url_encode_loose(Binary) when is_binary(Binary) ->
	url_encode_loose(binary_to_list(Binary));

url_encode_loose(String) ->
	url_encode_loose(String, []).

url_encode_loose([], Acc) ->
	list_to_binary(lists:reverse(Acc));

url_encode_loose([Char|String], Acc)
	when Char >= $A, Char =< $Z;
	Char >= $a, Char =< $z;
	Char >= $0, Char =< $9;
	Char =:= $-; Char =:= $_;
	Char =:= $.; Char =:= $~;
	Char =:= $/ ->
	url_encode_loose(String, [Char|Acc]);

url_encode_loose([Char|String], Acc)
	when Char >=0, Char =< 255 ->
	url_encode_loose(String, [hex_char(Char rem 16), hex_char(Char div 16), $% | Acc]).


%% @private
utf8_encode_char(Char) when Char > 16#FFFF, Char =< 16#10FFFF ->
	encode_char(Char band 16#3F + 16#80)
	++ encode_char((16#3F band (Char bsr 6)) + 16#80)
		++ encode_char((16#3F band (Char bsr 12)) + 16#80)
		++ encode_char((Char bsr 18) + 16#F0);

utf8_encode_char(Char) when Char > 16#7FF, Char =< 16#FFFF ->
	encode_char(Char band 16#3F + 16#80)
	++ encode_char((16#3F band (Char bsr 6)) + 16#80)
		++ encode_char((Char bsr 12) + 16#E0);

utf8_encode_char(Char) when Char > 16#7F, Char =< 16#7FF ->
	encode_char(Char band 16#3F + 16#80)
	++ encode_char((Char bsr 6) + 16#C0);

utf8_encode_char(Char) when Char =< 16#7F ->
	encode_char(Char).

encode_char(Char) ->
	[hex_char(Char rem 16), hex_char(Char div 16), $%].


%% @private
hex_char(C) when C < 10 -> $0 + C;
hex_char(C) when C < 16 -> $A + C - 10.


%% @private
to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) -> nklib_util:to_binary(Term).

