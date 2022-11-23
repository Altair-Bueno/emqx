%%--------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_connector_ssl).

-include_lib("emqx/include/logger.hrl").

-export([
    convert_certs/2,
    clear_certs/2,
    try_clear_certs/3
]).

%% TODO: rm `connector` case after `dev/ee5.0` merged into `master`.
%% The `connector` config layer will be removed.
%% for bridges with `connector` field. i.e. `mqtt_source` and `mqtt_sink`
convert_certs(RltvDir, #{<<"connector">> := Connector} = Config) when
    is_map(Connector)
->
    SSL = map_get_oneof([<<"ssl">>, ssl], Connector, undefined),
    new_ssl_config(RltvDir, Config, SSL);
convert_certs(RltvDir, #{connector := Connector} = Config) when
    is_map(Connector)
->
    SSL = map_get_oneof([<<"ssl">>, ssl], Connector, undefined),
    new_ssl_config(RltvDir, Config, SSL);
%% for bridges without `connector` field. i.e. webhook
convert_certs(RltvDir, #{<<"ssl">> := SSL} = Config) ->
    new_ssl_config(RltvDir, Config, SSL);
convert_certs(RltvDir, #{ssl := SSL} = Config) ->
    new_ssl_config(RltvDir, Config, SSL);
%% for bridges use connector name
convert_certs(_RltvDir, Config) ->
    {ok, Config}.

clear_certs(RltvDir, Config) ->
    clear_certs2(RltvDir, normalize_key_to_bin(Config)).

clear_certs2(RltvDir, #{<<"connector">> := Connector} = _Config) when
    is_map(Connector)
->
    OldSSL = map_get_oneof([<<"ssl">>, ssl], Connector, undefined),
    ok = emqx_tls_lib:delete_ssl_files(RltvDir, undefined, OldSSL);
clear_certs2(RltvDir, #{<<"ssl">> := OldSSL} = _Config) ->
    ok = emqx_tls_lib:delete_ssl_files(RltvDir, undefined, OldSSL);
clear_certs2(_RltvDir, _) ->
    ok.

try_clear_certs(RltvDir, NewConf, OldConf) ->
    try_clear_certs2(
        RltvDir,
        normalize_key_to_bin(NewConf),
        normalize_key_to_bin(OldConf)
    ).

try_clear_certs2(RltvDir, #{<<"connector">> := NewConnector}, #{<<"connector">> := OldConnector}) when
    is_map(NewConnector),
    is_map(OldConnector)
->
    NewSSL = map_get_oneof([<<"ssl">>, ssl], NewConnector, undefined),
    OldSSL = map_get_oneof([<<"ssl">>, ssl], OldConnector, undefined),
    ok = emqx_tls_lib:delete_ssl_files(RltvDir, NewSSL, OldSSL);
try_clear_certs2(RltvDir, #{<<"ssl">> := NewSSL}, #{<<"ssl">> := OldSSL}) ->
    ok = emqx_tls_lib:delete_ssl_files(RltvDir, NewSSL, OldSSL);
try_clear_certs2(RltvDir, NewConf, OldConf) ->
    ?SLOG(debug, #{msg => "unexpected_conf", path => RltvDir, new => NewConf, OldConf => OldConf}),
    ok.

new_ssl_config(RltvDir, Config, SSL) ->
    case emqx_tls_lib:ensure_ssl_files(RltvDir, SSL) of
        {ok, NewSSL} ->
            {ok, new_ssl_config(Config, NewSSL)};
        {error, Reason} ->
            {error, {bad_ssl_config, Reason}}
    end.

new_ssl_config(#{connector := Connector} = Config, NewSSL) ->
    Config#{connector => Connector#{ssl => NewSSL}};
new_ssl_config(#{<<"connector">> := Connector} = Config, NewSSL) ->
    Config#{<<"connector">> => Connector#{<<"ssl">> => NewSSL}};
new_ssl_config(#{ssl := _} = Config, NewSSL) ->
    Config#{ssl => NewSSL};
new_ssl_config(#{<<"ssl">> := _} = Config, NewSSL) ->
    Config#{<<"ssl">> => NewSSL};
new_ssl_config(Config, _NewSSL) ->
    Config.

map_get_oneof([], _Map, Default) ->
    Default;
map_get_oneof([Key | Keys], Map, Default) ->
    case maps:find(Key, Map) of
        error ->
            map_get_oneof(Keys, Map, Default);
        {ok, Value} ->
            Value
    end.

normalize_key_to_bin(Map) when is_map(Map) ->
    maps:fold(
        fun
            (K, V, Acc) when is_atom(K) ->
                Bin = erlang:atom_to_binary(K, utf8),
                Acc#{Bin => V};
            (K, V, Acc) ->
                Acc#{K => V}
        end,
        #{},
        Map
    );
normalize_key_to_bin(Any) ->
    Any.
