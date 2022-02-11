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

-module(emqx_retainer).

-behaviour(gen_server).

-include("emqx_retainer.hrl").
-include_lib("emqx/include/logger.hrl").

-export([start_link/0]).

-export([ on_session_subscribed/4
        , on_message_publish/2
        ]).

-export([ dispatch/4
        , delete_message/2
        , store_retained/2
        , deliver/5]).

-export([ get_expiry_time/1
        , update_config/1
        , clean/0
        , delete/1
        , page_read/3
        , post_config_update/5
        , stats_fun/0
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-type state() :: #{ enable := boolean()
                  , context_id := non_neg_integer()
                  , context := undefined | context()
                  , clear_timer := undefined | reference()
                  , release_quota_timer := undefined | reference()
                  , wait_quotas := list()
                  }.

-define(DEF_MAX_PAYLOAD_SIZE, (1024 * 1024)).
-define(DEF_EXPIRY_INTERVAL, 0).
-define(MAX_PAYLOAD_SIZE_CONFIG_PATH, [retainer, max_payload_size]).

-define(CAST(Msg), gen_server:cast(?MODULE, Msg)).

-callback delete_message(context(), topic()) -> ok.
-callback store_retained(context(), message()) -> ok.
-callback read_message(context(), topic()) -> {ok, list()}.
-callback page_read(context(), topic(), non_neg_integer(), non_neg_integer()) ->
    {ok, list()}.
-callback match_messages(context(), topic(), cursor()) -> {ok, list(), cursor()}.
-callback clear_expired(context()) -> ok.
-callback clean(context()) -> ok.
-callback size(context()) -> non_neg_integer().

%%--------------------------------------------------------------------
%% Hook API
%%--------------------------------------------------------------------
-spec on_session_subscribed(_, _, emqx_types:subopts(), _) -> any().
on_session_subscribed(_, _, #{share := ShareName}, _) when ShareName =/= undefined ->
    ok;
on_session_subscribed(_, Topic, #{rh := Rh} = Opts, Context) ->
    IsNew = maps:get(is_new, Opts, true),
    case Rh =:= 0 orelse (Rh =:= 1 andalso IsNew) of
        true -> dispatch(Context, Topic);
        _ -> ok
    end.

%% RETAIN flag set to 1 and payload containing zero bytes
on_message_publish(Msg = #message{flags   = #{retain := true},
                                  topic   = Topic,
                                  payload = <<>>},
                   Context) ->
    delete_message(Context, Topic),
    case get_stop_publish_clear_msg() of
        true ->
            {ok, emqx_message:set_header(allow_publish, false, Msg)};
        _ ->
            {ok, Msg}
    end;

on_message_publish(Msg = #message{flags = #{retain := true}}, Context) ->
    Msg1 = emqx_message:set_header(retained, true, Msg),
    store_retained(Context, Msg1),
    {ok, Msg};
on_message_publish(Msg, _) ->
    {ok, Msg}.

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

%% @doc Start the retainer
-spec(start_link() -> emqx_types:startlink_ret()).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec dispatch(context(), pid(), topic(), cursor()) -> ok.
dispatch(Context, Pid, Topic, Cursor) ->
    Mod = get_backend_module(),
    case Cursor =/= undefined orelse emqx_topic:wildcard(Topic) of
        false ->
            {ok, Result} = Mod:read_message(Context, Topic),
            deliver(Result, Context, Pid, Topic, undefined);
        true  ->
            {ok, Result, NewCursor} =  Mod:match_messages(Context, Topic, Cursor),
            deliver(Result, Context, Pid, Topic, NewCursor)
    end.

deliver([], Context, Pid, Topic, Cursor) ->
    case Cursor of
        undefined ->
            ok;
        _ ->
            dispatch(Context, Pid, Topic, Cursor)
    end;
deliver(Result, #{context_id := Id} = Context, Pid, Topic, Cursor) ->
    case erlang:is_process_alive(Pid) of
        false ->
            ok;
        _ ->
            #{msg_deliver_quota := MaxDeliverNum} = emqx:get_config([retainer, flow_control]),
            case MaxDeliverNum of
                0 ->
                    _ = [Pid ! {deliver, Topic, Msg} || Msg <- Result],
                    ok;
                _ ->
                    case do_deliver(Result, Id, Pid, Topic) of
                        ok ->
                            deliver([], Context, Pid, Topic, Cursor);
                        abort ->
                            ok
                    end
            end
    end.

get_expiry_time(#message{headers = #{properties := #{'Message-Expiry-Interval' := 0}}}) ->
    0;
get_expiry_time(#message{headers = #{properties := #{'Message-Expiry-Interval' := Interval}},
                         timestamp = Ts}) ->
    Ts + Interval * 1000;
get_expiry_time(#message{timestamp = Ts}) ->
    Interval = emqx_conf:get([retainer, msg_expiry_interval], ?DEF_EXPIRY_INTERVAL),
    case Interval of
        0 -> 0;
        _ -> Ts + Interval
    end.

get_stop_publish_clear_msg() ->
    emqx_conf:get([retainer, stop_publish_clear_msg], false).

-spec update_config(hocon:config()) -> {ok, _} | {error, _}.
update_config(Conf) ->
    emqx_conf:update([retainer], Conf, #{override_to => cluster}).

clean() ->
    call(?FUNCTION_NAME).

delete(Topic) ->
    call({?FUNCTION_NAME, Topic}).

page_read(Topic, Page, Limit) ->
    call({?FUNCTION_NAME, Topic, Page, Limit}).

post_config_update(_, _UpdateReq, NewConf, OldConf, _AppEnvs) ->
    call({update_config, NewConf, OldConf}).

call(Req) ->
    gen_server:call(?MODULE, Req, infinity).

stats_fun() ->
    gen_server:cast(?MODULE, ?FUNCTION_NAME).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    emqx_conf:add_handler([retainer], ?MODULE),
    init_shared_context(),
    State = new_state(),
    #{enable := Enable} = Cfg = emqx:get_config([retainer]),
    {ok,
     case Enable of
         true ->
             enable_retainer(State, Cfg);
         _ ->
             State
     end}.

handle_call({update_config, NewConf, OldConf}, _, State) ->
    State2 = update_config(State, NewConf, OldConf),
    {reply, ok, State2};

handle_call({wait_semaphore, Id}, From, #{wait_quotas := Waits} = State) ->
    {noreply, State#{wait_quotas := [{Id, From} | Waits]}};

handle_call(clean, _, #{context := Context} = State) ->
    clean(Context),
    {reply, ok, State};

handle_call({delete, Topic}, _, #{context := Context} = State) ->
    delete_message(Context, Topic),
    {reply, ok, State};

handle_call({page_read, Topic, Page, Limit}, _, #{context := Context} = State) ->
    Mod = get_backend_module(),
    Result = Mod:page_read(Context, Topic, Page, Limit),
    {reply, Result, State};

handle_call(Req, _From, State) ->
    ?SLOG(error, #{msg => "unexpected_call", call => Req}),
    {reply, ignored, State}.

handle_cast(stats_fun, #{context := Context} = State) ->
    Mod = get_backend_module(),
    Size = Mod:size(Context),
    emqx_stats:setstat('retained.count', 'retained.max', Size),
    {noreply, State};

handle_cast(Msg, State) ->
    ?SLOG(error, #{msg => "unexpected_cast", cast => Msg}),
    {noreply, State}.

handle_info(clear_expired, #{context := Context} = State) ->
    Mod = get_backend_module(),
    Mod:clear_expired(Context),
    Interval = emqx_conf:get([retainer, msg_clear_interval], ?DEF_EXPIRY_INTERVAL),
    {noreply, State#{clear_timer := add_timer(Interval, clear_expired)}, hibernate};

handle_info(release_deliver_quota, #{context := Context, wait_quotas := Waits} = State) ->
    insert_shared_context(?DELIVER_SEMAPHORE, get_msg_deliver_quota()),
    case Waits of
        [] ->
            ok;
        _ ->
            #{context_id := NowId} = Context,
            Waits2 = lists:reverse(Waits),
            lists:foreach(fun({Id, From}) ->
                                  gen_server:reply(From, Id =:= NowId)
                          end,
                          Waits2)
    end,
    Interval = emqx:get_config([retainer, flow_control, quota_release_interval]),
    {noreply, State#{release_quota_timer := add_timer(Interval, release_deliver_quota),
                     wait_quotas := []}};

handle_info(Info, State) ->
    ?SLOG(error, #{msg => "unexpected_info", info => Info}),
    {noreply, State}.

terminate(_Reason, #{clear_timer := TRef1, release_quota_timer := TRef2}) ->
    _ = stop_timer(TRef1),
    _ = stop_timer(TRef2),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
-spec new_state() -> state().
new_state() ->
    #{enable => false,
      context_id => 0,
      context => undefined,
      clear_timer => undefined,
      release_quota_timer => undefined,
      wait_quotas => []}.

-spec new_context(pos_integer()) -> context().
new_context(Id) ->
    #{context_id => Id}.


payload_size_limit() ->
    emqx_conf:get(?MAX_PAYLOAD_SIZE_CONFIG_PATH, ?DEF_MAX_PAYLOAD_SIZE).

%% @private
dispatch(Context, Topic) ->
    emqx_retainer_pool:async_submit(fun ?MODULE:dispatch/4,
                                    [Context, self(), Topic, undefined]).

-spec delete_message(context(), topic()) -> ok.
delete_message(Context, Topic) ->
    Mod = get_backend_module(),
    Mod:delete_message(Context, Topic).

-spec store_retained(context(), message()) -> ok.
store_retained(Context, #message{topic = Topic, payload = Payload} = Msg) ->
    Size = iolist_size(Payload),
    case payload_size_limit() of
        Limit when Limit > 0 andalso Limit < Size ->
            ?SLOG(error, #{msg => "retain_failed_for_payload_size_exceeded_limit",
                           topic => Topic,
                           config => emqx_hocon:format_path(?MAX_PAYLOAD_SIZE_CONFIG_PATH),
                           size => Size,
                           limit => Limit});
        _ ->
            Mod = get_backend_module(),
            Mod:store_retained(Context, Msg)
    end.

-spec clean(context()) -> ok.
clean(Context) ->
    Mod = get_backend_module(),
    Mod:clean(Context).

-spec do_deliver(list(term()), pos_integer(), pid(), topic()) -> ok | abort.
do_deliver([Msg | T], Id, Pid, Topic) ->
    case require_semaphore(?DELIVER_SEMAPHORE, Id) of
        true ->
            Pid ! {deliver, Topic, Msg},
            do_deliver(T, Id, Pid, Topic);
        _ ->
            abort
    end;
do_deliver([], _, _, _) ->
    ok.

-spec require_semaphore(semaphore(), pos_integer()) -> boolean().
require_semaphore(Semaphore, Id) ->
    Remained = ets:update_counter(?SHARED_CONTEXT_TAB,
                                  Semaphore,
                                  {#shared_context.value, -1, -1, -1}),
    wait_semaphore(Remained, Id).

-spec wait_semaphore(non_neg_integer(), pos_integer()) -> boolean().
wait_semaphore(X, Id) when X < 0 ->
    call({?FUNCTION_NAME, Id});
wait_semaphore(_, _) ->
    true.

-spec init_shared_context() -> ok.
init_shared_context() ->
    ?SHARED_CONTEXT_TAB = ets:new(?SHARED_CONTEXT_TAB,
                                  [ set, named_table, public
                                  , {keypos, #shared_context.key}
                                  , {write_concurrency, true}
                                  , {read_concurrency, true}]),
    lists:foreach(fun({K, V}) ->
                          insert_shared_context(K, V)
                  end,
                  [{?DELIVER_SEMAPHORE, get_msg_deliver_quota()}]).


-spec insert_shared_context(shared_context_key(), term()) -> ok.
insert_shared_context(Key, Term) ->
    ets:insert(?SHARED_CONTEXT_TAB, #shared_context{key = Key, value = Term}),
    ok.

-spec get_msg_deliver_quota() -> non_neg_integer().
get_msg_deliver_quota() ->
    emqx:get_config([retainer, flow_control, msg_deliver_quota]).

-spec update_config(state(), hocons:config(), hocons:config()) -> state().
update_config(State, Conf, OldConf) ->
    update_config(maps:get(enable, Conf),
                  maps:get(enable, OldConf),
                  State,
                  Conf,
                  OldConf).

-spec update_config(boolean(), boolean(), state(), hocons:config(), hocons:config()) -> state().
update_config(false, _, State, _, _) ->
    disable_retainer(State);

update_config(true, false, State, NewConf, _) ->
    enable_retainer(State, NewConf);

update_config(true, true,
              #{clear_timer := ClearTimer,
                release_quota_timer := QuotaTimer} = State, NewConf, OldConf) ->
    #{config := Cfg,
      flow_control := #{quota_release_interval := QuotaInterval},
      msg_clear_interval := ClearInterval} = NewConf,

    #{config := OldCfg} = OldConf,

    StorageType = maps:get(type, Cfg),
    OldStrorageType = maps:get(type, OldCfg),
    case OldStrorageType of
        StorageType ->
            State#{clear_timer := check_timer(ClearTimer,
                                              ClearInterval,
                                              clear_expired),
                   release_quota_timer := check_timer(QuotaTimer,
                                                      QuotaInterval,
                                                      release_deliver_quota)};
        _ ->
            State2 = disable_retainer(State),
            enable_retainer(State2, NewConf)
    end.

-spec enable_retainer(state(), hocon:config()) -> state().
enable_retainer(#{context_id := ContextId} = State,
                #{msg_clear_interval := ClearInterval,
                  flow_control := #{quota_release_interval := ReleaseInterval},
                  config := Config}) ->
    NewContextId = ContextId + 1,
    Context = create_resource(new_context(NewContextId), Config),
    load(Context),
    State#{enable := true,
           context_id := NewContextId,
           context := Context,
           clear_timer := add_timer(ClearInterval, clear_expired),
           release_quota_timer := add_timer(ReleaseInterval, release_deliver_quota)}.

-spec disable_retainer(state()) -> state().
disable_retainer(#{clear_timer := TRef1,
                   release_quota_timer := TRef2,
                   context := Context,
                   wait_quotas := Waits} = State) ->
    unload(),
    ok = lists:foreach(fun(E) -> gen_server:reply(E, false) end, Waits),
    ok = close_resource(Context),
    State#{enable := false,
           clear_timer := stop_timer(TRef1),
           release_quota_timer := stop_timer(TRef2),
           wait_quotas := []}.

-spec stop_timer(undefined | reference()) -> undefined.
stop_timer(undefined) ->
    undefined;
stop_timer(TimerRef) ->
    _ = erlang:cancel_timer(TimerRef),
    undefined.

add_timer(0, _) ->
    undefined;
add_timer(undefined, _) ->
    undefined;
add_timer(Ms, Content) ->
    erlang:send_after(Ms, self(), Content).

check_timer(undefined, Ms, Context) ->
    add_timer(Ms, Context);
check_timer(Timer, 0, _) ->
    stop_timer(Timer);
check_timer(Timer, undefined, _) ->
    stop_timer(Timer);
check_timer(Timer, _, _) ->
    Timer.

-spec get_backend_module() -> backend().
get_backend_module() ->
    ModName = case emqx:get_config([retainer, config]) of
                  #{type := built_in_database} -> mnesia;
                  #{type := Backend} -> Backend
              end,
    erlang:list_to_existing_atom(io_lib:format("~ts_~ts", [?APP, ModName])).

create_resource(Context, #{type := built_in_database} = Cfg) ->
    emqx_retainer_mnesia:create_resource(Cfg),
    Context;

create_resource(Context, #{type := DB} = Config) ->
    ResourceID = erlang:iolist_to_binary([io_lib:format("~ts_~ts", [?APP, DB])]),
    case emqx_resource:create(
           ResourceID,
           <<"default">>,
           list_to_existing_atom(io_lib:format("~ts_~ts", [emqx_connector, DB])),
           Config) of
        {ok, already_created} ->
            Context#{resource_id => ResourceID};
        {ok, _} ->
            Context#{resource_id => ResourceID};
        {error, Reason} ->
            error({load_config_error, Reason})
    end.

-spec close_resource(context()) -> ok | {error, term()}.
close_resource(#{resource_id := ResourceId}) ->
    emqx_resource:stop(ResourceId);
close_resource(_) ->
    ok.

-spec load(context()) -> ok.
load(Context) ->
    _ = emqx:hook('session.subscribed', {?MODULE, on_session_subscribed, [Context]}),
    _ = emqx:hook('message.publish', {?MODULE, on_message_publish, [Context]}),
    emqx_stats:update_interval(emqx_retainer_stats, fun ?MODULE:stats_fun/0),
    ok.

unload() ->
    emqx:unhook('message.publish', {?MODULE, on_message_publish}),
    emqx:unhook('session.subscribed', {?MODULE, on_session_subscribed}),
    emqx_stats:cancel_update(emqx_retainer_stats),
    ok.
