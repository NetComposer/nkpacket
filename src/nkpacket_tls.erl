%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
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
-export([make_outbound_opts/1, make_inbound_opts/1, defaults_certs/0]).
-export([partial_chain/1]).

-include("nkpacket.hrl").
-include_lib("public_key/include/OTP-PUB-KEY.hrl").

%% ===================================================================
%% Public
%% ===================================================================


%% @doc Adds SSL options
-spec make_outbound_opts(nkpacket:tls_types()) ->
    list().

make_outbound_opts(#{tls_verify:=host, host:=Host}) ->
    Defaults = default_outbound(),
    Opts = Defaults#{
        verify => verify_peer,
        depth => 99,
        cacerts => certifi:cacerts(),
        partial_chain => fun ?MODULE:partial_chain/1,
        verify_fun => {
            fun ssl_verify_hostname:verify_fun/3,
            [{check_hostname, binary_to_list(Host)}]
        }
    },
    maps:to_list(Opts);

make_outbound_opts(#{tls_verify:=host}=Opts) ->
    lager:warning("NkPACKET: TLS host is not available"),
    make_outbound_opts(maps:remove(tls_verify, Opts));

make_outbound_opts(Opts) ->
    make_opts(Opts, default_outbound()).


%% @doc Adds SSL options
-spec make_inbound_opts(nkpacket:tls_types()) ->
    list().

make_inbound_opts(Opts) ->
    make_opts(Opts, default_inbound()).


%% @private
make_opts(Opts, Defaults) ->
    Opts2 = maps:fold(
        fun(Key, Val, Acc) ->
            case Key of
                tls_verify -> Acc#{verify => Val};
                tls_certfile -> Acc#{certfile => Val};
                tls_keyfile -> Acc#{keyfile => Val};
                tls_cacertfile -> Acc#{cacertfile => Val};
                tls_password -> Acc#{password => Val};
                tls_depth -> Acc#{depth => Val};
                tls_versions -> Acc#{versions => Val};
                _ -> Acc
            end
        end,
        Defaults,
        Opts),
    Opts3 = case Opts2 of
        #{verify:=true} ->
            Opts2#{verify=>verify_peer, fail_if_no_peer_cert=>true};
        _ ->
            maps:remove(verify, Opts2)
    end,
    maps:to_list(Opts3).


default_outbound() ->
    #{
        secure_renegotiate => true,
        reuse_sessions => true,
        %honor_cipher_order => true,        % server only?
        ciphers => ciphers(),
        versions => ['tlsv1.2', 'tlsv1.1', tlsv1, sslv3]
    }.

default_inbound() ->
    Certs = nkpacket_app:get(default_certs),
    Certs#{
        versions => ['tlsv1.2', 'tlsv1.1', tlsv1]
    }.


%% from Hackney and https://wiki.mozilla.org/Security/Server_Side_TLS
ciphers() ->
    [
        "ECDHE-ECDSA-AES256-GCM-SHA384",
        "ECDHE-RSA-AES256-GCM-SHA384",
        "ECDHE-ECDSA-AES256-SHA384",
        "ECDHE-RSA-AES256-SHA384",
        "ECDHE-ECDSA-DES-CBC3-SHA",
        "ECDH-ECDSA-AES256-GCM-SHA384",
        "ECDH-RSA-AES256-GCM-SHA384",
        "ECDH-ECDSA-AES256-SHA384",
        "ECDH-RSA-AES256-SHA384",
        "DHE-DSS-AES256-GCM-SHA384",
        "DHE-DSS-AES256-SHA256",
        "AES256-GCM-SHA384",
        "AES256-SHA256",
        "ECDHE-ECDSA-AES128-GCM-SHA256",
        "ECDHE-RSA-AES128-GCM-SHA256",
        "ECDHE-ECDSA-AES128-SHA256",
        "ECDHE-RSA-AES128-SHA256",
        "ECDH-ECDSA-AES128-GCM-SHA256",
        "ECDH-RSA-AES128-GCM-SHA256",
        "ECDH-ECDSA-AES128-SHA256",
        "ECDH-RSA-AES128-SHA256",
        "DHE-DSS-AES128-GCM-SHA256",
        "DHE-DSS-AES128-SHA256",
        "AES128-GCM-SHA256",
        "AES128-SHA256",
        "ECDHE-ECDSA-AES256-SHA",
        "ECDHE-RSA-AES256-SHA",
        "DHE-DSS-AES256-SHA",
        "ECDH-ECDSA-AES256-SHA",
        "ECDH-RSA-AES256-SHA",
        "AES256-SHA",
        "ECDHE-ECDSA-AES128-SHA",
        "ECDHE-RSA-AES128-SHA",
        "DHE-DSS-AES128-SHA",
        "ECDH-ECDSA-AES128-SHA",
        "ECDH-RSA-AES128-SHA",
        "AES128-SHA"
    ].

defaults_certs() ->
    case code:priv_dir(nkpacket) of
        PrivDir when is_list(PrivDir) ->
            #{
                certfile => filename:join(PrivDir, "cert.pem"),
                keyfile => filename:join(PrivDir, "key.pem")
            };
        _ ->
            #{}
    end.


%% @private
partial_chain(Certs) ->
    find_partial_chain(lists:reverse(Certs)).


%% @private
find_partial_chain([]) ->
    unknown_ca;

find_partial_chain([Cert|Rest]) ->
    case check_cert(certifi:cacerts(), Cert) of
        true ->
            {trusted_ca, Cert};
        false ->
            find_partial_chain(Rest)
    end.


%% @private
check_cert([], _Cert) ->
    false;

check_cert([CACert|Rest], Cert) ->
    case extract_public_key_info(CACert) == extract_public_key_info(Cert) of
        true ->
            true;
        false ->
            check_cert(Rest, Cert)
    end.

extract_public_key_info(Cert) ->
    Cert2 = public_key:pkix_decode_cert(Cert, otp),
    ((Cert2#'OTPCertificate'.tbsCertificate)#'OTPTBSCertificate'.subjectPublicKeyInfo).



%% Code from hackney, previous is much cleaner but not tested

%%%% code from rebar3 undert BSD license
%%partial_chain(Certs) ->
%%    Certs1 = lists:reverse([{Cert, public_key:pkix_decode_cert(Cert, otp)} ||
%%        Cert <- Certs]),
%%    CACerts = certifi:cacerts(),
%%    CACerts1 = [public_key:pkix_decode_cert(Cert, otp) || Cert <- CACerts],
%%
%%    case find(fun({_, Cert}) ->
%%        check_cert(CACerts1, Cert)
%%    end, Certs1) of
%%        {ok, Trusted} ->
%%            {trusted_ca, element(1, Trusted)};
%%        _ ->
%%            unknown_ca
%%    end.
%%
%%extract_public_key_info(Cert) ->
%%    ((Cert#'OTPCertificate'.tbsCertificate)#'OTPTBSCertificate'.subjectPublicKeyInfo).
%%
%%check_cert(CACerts, Cert) ->
%%    lists:any(fun(CACert) ->
%%        extract_public_key_info(CACert) == extract_public_key_info(Cert)
%%    end, CACerts).
%%
%%-spec find(fun(), list()) -> {ok, term()} | error.
%%find(Fun, [Head|Tail]) when is_function(Fun) ->
%%    case Fun(Head) of
%%        true ->
%%            {ok, Head};
%%        false ->
%%            find(Fun, Tail)
%%    end;
%%find(_Fun, []) ->
%%    error.


