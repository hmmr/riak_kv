%% -------------------------------------------------------------------
%%
%% Store the state about what bucket type DDLs have been compiled.
%%
%% Copyright (c) 2015-2016 Basho Technologies, Inc.  All Rights Reserved.
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

-module(riak_kv_compile_tab).

-export([
         delete_dets/1,
         get_compiled_ddl_version/1,
         get_ddl/1,
         get_state/1,
         get_ddl_records_needing_recompiling/1,
         insert/5,
         is_compiling/1,
         new/1,
         update_state/2]).

-define(TABLE, ?MODULE).

-type compiling_state() :: compiling | compiled | failed | retrying.
-export_type([compiling_state/0]).

-define(is_compiling_state(S),
        (S == compiling orelse
         S == compiled orelse
         S == failed orelse
         S == retrying)).

%% 
-spec new(file:name()) ->
        {ok, dets:tab_name()} | {error, any()}.
new(FileDir) ->
    FilePath = filename:join(FileDir, [?TABLE, ".dets"]),
    lager:debug("Opening DDL DETS table ~s", [FilePath]),
    Result = dets:open_file(?TABLE, [{type, set}, {repair, force}, {file, FilePath}]),
    %% Only update the DETS database if it opens successfully
    case Result of
        {ok, _} ->
            %% Convert all legacy DDL compilation records to current format
            upgrade_legacy_records(),

            %% Clean up any lingering records stuck in the compiling state
            mark_compiling_for_retry();
        _ -> ok
    end,
    Result.

%%
-spec delete_dets(file:name()) ->
    ok | {error, any()}.
delete_dets(FileDir) ->
    FilePath = filename:join(FileDir, [?TABLE, ".dets"]),
    dets:close(FilePath),
    file:delete(FilePath).

%%
-spec insert(BucketType :: binary(),
             DDLVersion :: riak_ql_ddl:compiler_version_type(),
             DDL :: term(),
             CompilerPid :: pid(),
             State :: compiling_state()) -> ok.
insert(BucketType, DDLVersion, DDL, CompilerPid, State) ->
    lager:info("DDL DETS Update: ~p, ~p, ~p, ~p, ~p",
               [BucketType, DDLVersion, DDL, CompilerPid, State]),
    dets:insert(?TABLE, {BucketType, DDLVersion, DDL, CompilerPid, State}),
    dets:sync(?TABLE),
    ok.

%% Check if the bucket type is in the compiling state.
-spec is_compiling(BucketType :: binary()) ->
    {true, pid()} | false.
is_compiling(BucketType) ->
    case dets:lookup(?TABLE, BucketType) of
        [{_,_,_,Pid,compiling}] ->
            {true, Pid};
        _ ->
            false
    end.

%%
-spec get_state(BucketType :: binary()) ->
        compiling_state() | notfound.
get_state(BucketType) when is_binary(BucketType) ->
    case dets:lookup(?TABLE, BucketType) of
        [{_,_,_,_,State}] ->
            State;
        [] ->
            notfound
    end.

%%
-spec get_compiled_ddl_version(BucketType :: binary()) ->
    riak_ql_ddl:compiler_version_type() | notfound.
get_compiled_ddl_version(BucketType) when is_binary(BucketType) ->
    case dets:match(?TABLE, {BucketType,'$1','_','_','_'}) of
        [[Version]] ->
            Version;
        [] ->
            notfound
    end.

%%
-spec get_ddl(BucketType :: binary()) ->
        term() | notfound.
get_ddl(BucketType) when is_binary(BucketType) ->
    case dets:lookup(?TABLE, BucketType) of
        [{_,_,DDL,_,_}] ->
            DDL;
        [] ->
            notfound
    end.

%% Update the compilation state using the compiler pid as a key.
%% Since it has an active Pid, it is assumed to have a DDL version already.
-spec update_state(CompilerPid :: pid(), State :: compiling_state()) ->
        ok | notfound.
update_state(CompilerPid, State) when is_pid(CompilerPid),
                                       ?is_compiling_state(State) ->
    case dets:match(?TABLE, {'$1','$2','$3',CompilerPid,'_'}) of
        [[BucketType, DDLVersion, DDL]] ->
            insert(BucketType, DDLVersion, DDL, CompilerPid, State);
        [] ->
            notfound
    end.

%% Mark any lingering compilations as being retried
-spec mark_compiling_for_retry() -> ok.
mark_compiling_for_retry() ->
    CompilingPids = dets:match(?TABLE, {'_','_','_','$1',compiling}),
    lists:foreach(fun([Pid]) -> update_state(Pid, retrying) end, CompilingPids).

%% Get the list of records which need to be recompiled
-spec get_ddl_records_needing_recompiling(DDLVersion :: riak_ql_ddl:compiler_version_type()) ->
    [binary()].
get_ddl_records_needing_recompiling(DDLVersion) ->
    %% First find all tables with a version
    MismatchedTables = dets:select(?TABLE, [{{'$1','$2','_','_',compiled},[{'/=','$2', DDLVersion}],['$$']}]),
    RetryingTables = dets:match(?TABLE, {'$1','$2','_','_',retrying}),
    Tables = [hd(X) || X <- MismatchedTables ++ RetryingTables],
    lager:info("Recompile the DDL of these bucket types ~p", [Tables]),
    Tables.

%% Convert all pre-1.3 records to include the DDL compiler version in the
%% DETS table. Insert will replace the existing record
-spec upgrade_legacy_records() -> ok.
upgrade_legacy_records() ->
    LegacyVersion = 1,
    OldVersions = dets:match(?TABLE, {'$1','$2','$3','$4'}),
    lists:foreach(fun([BucketType, DDL, Pid, State]) ->
                       ok = dets:insert(?TABLE, {BucketType, LegacyVersion, DDL, Pid, State})
                  end, OldVersions),
    ok.

%% ===================================================================
%% EUnit tests
%% ===================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(in_process(TestCode),
    Self = self(),
    spawn_link(
        fun() ->
            _ = riak_kv_compile_tab:delete_dets("."),
            _ = riak_kv_compile_tab:new("."),
            TestCode,
            Self ! test_ok
        end),
    receive
        test_ok -> ok
    end
).

insert_test() ->
    ?in_process(
        begin
            Pid = spawn(fun() -> ok end),
            ok = insert(<<"my_type">>, 2, {ddl_v1}, Pid, compiling),
            ?assertEqual(
                compiling,
                get_state(<<"my_type">>)
            )
        end).

update_state_test() ->
    ?in_process(
        begin
            Pid = spawn(fun() -> ok end),
            ok = insert(<<"my_type">>, 3, {ddl_v1}, Pid, compiling),
            ok = update_state(Pid, compiled),
            ?assertEqual(
                compiled,
                get_state(<<"my_type">>)
            )
        end).

is_compiling_test() ->
    ?in_process(
        begin
            Pid = spawn(fun() -> ok end),
            ok = insert(<<"my_type">>, 4, {ddl_v1}, Pid, compiling),
            ?assertEqual(
                {true, Pid},
                is_compiling(<<"my_type">>)
            )
        end).

compiled_version_test() ->
    ?in_process(
        begin
            Pid = spawn(fun() -> ok end),
            ok = insert(<<"my_type">>, 5, {ddl_v1}, Pid, compiled),
            ?assertEqual(
                [5],
                get_compiled_ddl_version(<<"my_type">>)
            )
        end).

get_ddl_test() ->
    ?in_process(
        begin
            Pid = spawn(fun() -> ok end),
            ok = insert(<<"my_type">>, 6, {ddl_v1}, Pid, compiled),
            ?assertEqual(
                {ddl_v1},
                get_ddl(<<"my_type">>)
            )
        end).

recompile_ddl_test() ->
    ?in_process(
        begin
            Pid = spawn(fun() -> ok end),
            Pid2 = spawn(fun() -> ok end),
            Pid3 = spawn(fun() -> ok end),
            Pid4 = spawn(fun() -> ok end),
            ok = insert(<<"my_type1">>, 6, {ddl_v1}, Pid, compiling),
            ok = insert(<<"my_type2">>, 7, {ddl_v1}, Pid2, compiled),
            ok = insert(<<"my_type3">>, 6, {ddl_v1}, Pid3, compiling),
            ok = insert(<<"my_type4">>, 8, {ddl_v1}, Pid4, compiled),
            mark_compiling_for_retry(),
            ?assertEqual(
                [<<"my_type1">>,
                 <<"my_type2">>,
                 <<"my_type3">>,
                ],
                lists:sort(get_ddl_records_needing_recompiling(8))
            )
        end).

update_legacy_ddl_test() ->
    ?in_process(
        begin
            Pid = spawn(fun() -> ok end),
            Pid2 = spawn(fun() -> ok end),
            Pid3 = spawn(fun() -> ok end),
            Pid4 = spawn(fun() -> ok end),
            ok = dets:insert(?TABLE, {<<"my_type">>, {ddl_v1}, Pid, compiled}),
            ok = dets:insert(?TABLE, {<<"my_type1">>, {ddl_v1}, Pid2, compiled}),
            ok = dets:insert(?TABLE, {<<"my_type2">>, {ddl_v1}, Pid3, compiled}),
            ok = dets:insert(?TABLE, {<<"my_type3">>, {ddl_v1}, Pid4, compiled}),
            upgrade_legacy_records(4),
            ?assertEqual(
                [[<<"my_type">>],[<<"my_type1">>],[<<"my_type2">>],[<<"my_type3">>]],
                lists:sort(dets:match(?TABLE, {'$1',4,'_','_','_'}))
            )
        end).
-endif.