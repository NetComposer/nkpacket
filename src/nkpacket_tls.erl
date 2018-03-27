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

%% @doc NkPACKET TLS processing from Hackney

-module(nkpacket_tls).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([make_tls_opts/1]).

-include("nkpacket.hrl").
-include_lib("public_key/include/OTP-PUB-KEY.hrl").

%% ===================================================================
%% Public
%% ===================================================================

%% @doc Adds SSL options
-spec make_tls_opts(nkpacket:tls_types()) ->
    list().

make_tls_opts(Opts) ->
    Opts1 = nklib_util:filtermap(
        fun(Term) ->
            case Term of
                {tls_certfile, Val} -> {true, {certfile, Val}};
                {tls_keyfile, Val} -> {true, {keyfile, Val}};
                {tls_cacertfile, Val} -> {true, {cacertfile, Val}};
                {tls_password, Val} -> {true, {password, Val}};
                {tls_verify, Val} -> {true, {verify, Val}};
                {tls_depth, Val} -> {true, {depth, Val}};
                {tls_versions, Val} -> {true, {versions, Val}};
                _ -> false
            end
        end,
        maps:to_list(Opts)),
    Defaults1 = nkpacket_app:get(tls_defaults),
    Defaults2 = case lists:keymember(certfile, 1, Opts1) of
        true ->
            maps:remove(keyfile, Defaults1);
        false ->
            Defaults1
    end,
    Opts2 = maps:merge(Defaults2, maps:from_list(Opts1)),
    Opts3 = case Opts2 of
        #{verify:=true} ->
            Opts2#{verify=>verify_peer, fail_if_no_peer_cert=>true};
        #{verify:=false} ->
            maps:remove(verify, Opts2);
        _ ->
            Opts2
    end,
    Opts4 = case Opts of
        #{tls_insecure:=true} ->
            Opts3;
        _ ->
            case maps:is_key(verify, Opts3) of
                true ->
                    Opts3;
                false ->
                    maps:merge(verify_host(Opts), Opts3)
            end
    end,
    maps:to_list(Opts4).


%% @private
verify_host(#{host:=Host}) ->
    #{
        verify => verify_peer,
        depth => 99,
        cacerts => certifi:cacerts(),
        partial_chain => fun partial_chain/1,
        verify_fun => {
            fun ssl_verify_hostname:verify_fun/3,
            [{check_hostname, Host}]
        }
    };

verify_host(_) ->
    #{}.


%% @private
partial_chain(Certs) ->
    Certs1 = lists:reverse(
        [{Cert, public_key:pkix_decode_cert(Cert, otp)} || Cert <- Certs]),
    CACerts = certifi:cacerts(),
    CACerts1 = [public_key:pkix_decode_cert(Cert, otp) || Cert <- CACerts],
    case find(Certs1, CACerts1) of
        {ok, Trusted} ->
            {trusted_ca, element(1, Trusted)};
        _ ->
            unknown_ca
    end.


%% @private
find([{_, Cert}=First|Rest], CACerts) ->
    case check_cert(CACerts, Cert) of
        true ->
            {ok, First};
        false ->
            find(Rest, CACerts)
    end;

find([], _) ->
    error.


%% @private
check_cert(CACerts, Cert) ->
    lists:any(
        fun(CACert) ->
            extract_public_key_info(CACert) == extract_public_key_info(Cert)
        end,
        CACerts).

extract_public_key_info(Cert) ->
    ((Cert#'OTPCertificate'.tbsCertificate)#'OTPTBSCertificate'.subjectPublicKeyInfo).

