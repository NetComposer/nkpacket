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


%% S3 client
-module(nkpacket_httpc_s3).
-export([get_object/3, put_object/5, make_get_url/4, make_put_url/5]).
-export([test/0]).

-include_lib("nklib/include/nklib.hrl").

%% ===================================================================
%% Public
%% ===================================================================


-type acl() ::
	private | public_read | public_read_write | authenticated_read |
	bucket_owner_read | bucket_owner_full_control.


-type config() ::
	nklib_aws:request_v4_config() |
	#{
		acl => acl()
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
	{Method::binary(), Uri::binary(), [{binary(), binary()}]}.

get_object(Bucket, Path, Config) ->
	Config2 = Config#{
		method => get,
		path => list_to_binary([$/, Bucket, Path]),
        service => s3
	},
	nklib_aws:request_v4(Config2).



%% @doc
%% Valid Headers:
%% - content-type
%%
%% Can Use meta and acl
%% Path must start with /
%%
%% Hash must be crypto:hash(sha245, Body)

-spec put_object(binary(), binary(), binary(), binary(), config()) ->
    {Method::binary(), Uri::binary(), [{binary(), binary()}]}.

put_object(Bucket, Path, CT, BodyHash, Config) ->
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
    Headers3 = [{<<"content-type">>, CT} | Headers2],
	Config2 = Config#{
		method => put,
        service => s3,
        path => list_to_binary([$/, Bucket, Path]),
		headers => Headers3,
		hash => BodyHash
	},
	nklib_aws:request_v4(Config2).



%% @doc Generates an URL-like access for read
-spec make_get_url(binary(),  binary(), integer(), config()) ->
    {Method::binary(), Uri::binary()}.

make_get_url(Bucket, Path, TTL, Config) ->
	Config2 = Config#{
		method => <<"GET">>,
        service => s3,
		ttl => TTL,
        path => list_to_binary([$/, Bucket, Path])
	},
	nklib_aws:request_v4_tmp(Config2).



%% @doc Generates an URL-like access for write
-spec make_put_url(binary(),  binary(), binary(), integer(), config()) ->
    {Method::binary(), Uri::binary()}.

make_put_url(Bucket, Path, CT, TTL, Config) ->
	Config2 = Config#{
		method => <<"PUT">>,
        service => s3,
		ttl => TTL,
		content_type => CT,
        path => list_to_binary([$/, Bucket, Path])
	},
	nklib_aws:request_v4_tmp(Config2).





%% ===================================================================
%% S3 Sample
%% ===================================================================

% export MINIO_ACCESS_KEY=5UBED0Q9FB7MFZ5EWIOJ; export MINIO_SECRET_KEY=CaK4frX0uixBOh16puEsWEvdjQ3X3RTDvkvE+tUI; minio server .

-define(TEST_KEY, <<"5UBED0Q9FB7MFZ5EWIOJ">>).
-define(TEST_SECRET, <<"CaK4frX0uixBOh16puEsWEvdjQ3X3RTDvkvE+tUI">>).
-define(TEST_BUCKET, <<"bucket1">>).
-define(TEST_PATH, <<"/test1">>).


test() ->
	{ok, 200, _, <<>>} = s3_test_put(),
	{ok, 200, _, <<"124">>} = s3_test_get(),
	{ok, 200, _, <<>>} = s3_test_put_url(),
	{ok, 200, _, <<"125">>} = s3_test_get_url(),
	ok.


s3_test_config() ->
	#{
        scheme => http,
        host => "127.0.0.1",
        port => 9000,
        key => ?TEST_KEY,
		secret => ?TEST_SECRET
	}.


s3_test_get() ->
	C = s3_test_config(),
	{Method, Url, Headers} = get_object(?TEST_BUCKET, ?TEST_PATH, C),
	request(Method, Url, Headers, <<>>).


s3_test_put() ->
    Body = <<"124">>,
    CT = <<"application/1">>,
	C1 = s3_test_config(),
	C2 = C1#{
		params => #{a => 1, <<"b">> => <<"2">>},
		meta => #{"b" => "2"},
		acl => private
	},
    Hash = crypto:hash(sha256, Body),
	{Method, Url, Headers} = put_object(?TEST_BUCKET, ?TEST_PATH, CT, Hash, C2),
    request(Method, Url, Headers, Body).


s3_test_put_url() ->
    Body = <<"125">>,
	CT = <<"application/json">>,
    C1 = s3_test_config(),
	{Method, Url} = make_put_url(?TEST_BUCKET, ?TEST_PATH, CT, 5000, C1),
    request(Method, Url, [{<<"content-type">>, CT}], Body).


s3_test_get_url() ->
    C1 = s3_test_config(),
	{Method, Url} = make_get_url(?TEST_BUCKET, ?TEST_PATH, 5000, C1),
    request(Method, Url, [], <<>>).


request(Method, Url, Headers, Body) ->
    Opts = #{tls_verify => host},
    {ok, {Scheme, _, Host, Port, Path, Query}} = http_uri:parse(Url),
    Connect = list_to_binary([
        nklib_util:to_binary(Scheme), "://",
        Host, ":", nklib_util:to_binary(Port)
    ]),
    Path2 = <<Path/binary, Query/binary>>,
    nkpacket_httpc:request(Connect, Method, Path2, Headers, Body, Opts).


