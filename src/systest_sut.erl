%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% ----------------------------------------------------------------------------
%%
%% Copyright (c) 2005 - 2012 Nebularis.
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
%% IN THE SOFTWARE.
%% ----------------------------------------------------------------------------
-module(systest_sut).

-behaviour(gen_server).

-export([start/1, start/2, start_link/2, start/3, start_link/3]).
-export([stop/1, stop/2]).
-export([restart_proc/2, restart_proc/3]).
-export([procs/1, check_config/2, status/1]).
-export([print_status/1, log_status/1]).
-export([proc_names/1, proc_pids/1]).

%% OTP gen_server Exports

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-include("systest.hrl").

-exprecs_prefix([operation]).
-exprecs_fname(["record_", prefix]).
-exprecs_vfname([fname, "__", version]).

-compile({parse_transform, exprecs}).
-export_records([sut]).

%%
%% Public API
%%

start(Config) ->
    start(global, Config).

start(SutId, Config) ->
    start(SutId, SutId, Config).

start(ScopeId, SutId, Config) ->
    start_it(start, ScopeId, SutId, Config).

start_link(SutId, Config) ->
    start(SutId, SutId, Config).

start_link(ScopeId, SutId, Config) ->
    start_it(start_link, ScopeId, SutId, Config).

start_it(How, ScopeId, SutId, Config) ->
    ct:log("Processing SUT ~p~n", [SutId]),
    case apply(gen_server, How, [{local, SutId},
                                 ?MODULE, [ScopeId, SutId, Config], []]) of
        {error, noconfig} ->
            Config;
        {ok, Pid} ->
            Config2 = systest_config:ensure_value(SutId, Pid, Config),
            systest_config:replace_value(active, Pid, Config2);
        {error, _Other}=Err ->
            Err
    end.

stop(SutRef) ->
    stop(SutRef, infinity).

stop(SutRef, Timeout) ->
    gen_server:call(SutRef, stop, Timeout).

restart_proc(SutRef, Proc) ->
    restart_proc(SutRef, Proc, infinity).

restart_proc(SutRef, Proc, Timeout) ->
    case gen_server:call(SutRef, {restart, Proc}, Timeout) of
        {restarted, {_OldProc, NewProc}} ->
            {ok, NewProc};
        Other ->
            {error, Other}
    end.

status(SutRef) ->
    gen_server:call(SutRef, status).

procs(SutRef) ->
    gen_server:call(SutRef, procs).

print_status(Sut) ->
    ct:log(lists:flatten([print_status_info(N) || N <- status(Sut)])).

log_status(Sut) ->
    ct:log(lists:flatten([print_status_info(N) || N <- status(Sut)])).

check_config(Sut, Config) ->
    with_sut({Sut, Sut}, fun build_procs/4, Config).

%% doing useful things with sut records....

proc_names(Sut) when is_record(Sut, sut) ->
    [element(1, N) || N <- get(procs, Sut)].

proc_pids(Sut) when is_record(Sut, sut) ->
    [element(2, N) || N <- get(procs, Sut)].

%%
%% OTP gen_server API
%%

init([Scope, Id, Config]) ->
    process_flag(trap_exit, true),
    %% TODO: now that we're using locally registered
    %% names, perhaps this logic can go away?
    case systest_watchdog:sut_started(Id, self()) of
        ok ->
            case with_sut({Scope, Id}, fun start_host/4, Config) of
                Sut=#sut{procs=Procs, on_start=Hooks} ->
                    try 
                        case Hooks of
                            [{on_start, Run}|_] ->
                                ct:log("running SUT on_start hooks ~p~n",
                                       [Run]),
                                [systest_hooks:run(Sut,
                                                   Hook, Sut) || Hook <- Run];
                            Other ->
                                ct:log("ignoring SUT hooks ~p~n", [Other]),
                                ok
                        end,
                        [begin
                             {_, Ref} = Proc,
                             ct:log("~p joined_sut~n", [Proc]),
                             systest_proc:joined_sut(Ref, Sut, Procs -- [Proc])
                         end || Proc <- Procs],
                        {ok, Sut}
                    catch 
                        throw:{hook_failed, Reason} -> {stop, Reason};
                        _:Error                     -> {stop, Error}
                    end;
                Error ->
                    {stop, Error}
            end;
        {error, clash} ->
            {stop, name_in_use}
    end.

handle_call(procs, _From, State=#sut{procs=Procs}) ->
    {reply, Procs, State};
handle_call(status, _From, State=#sut{procs=Procs}) ->
    {reply, [{N, systest_proc:status(N)} || {_, N} <- Procs], State};
handle_call({stop, Timeout}, From, State) ->
    shutdown(State, Timeout, From);
handle_call(stop, From, State) ->
    shutdown(State, infinity, From);
handle_call({restart, Proc}, From,
            State=#sut{procs=Procs, pending=P}) ->
    case [N || N <- Procs, element(1, N) == Proc orelse
                           element(2, N) == Proc] of
        [] ->
            {reply, {error, Proc}, State};
        [{_, Ref}=Found] ->
            systest_proc:stop(Ref),
            State2 = State#sut{
                pending=[{restart, Found, From}|P]
            },
            {noreply, State2}
    end;
handle_call(_Msg, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, normal}=Ev, State=#sut{name=Sut}) ->
    systest_watchdog:proc_stopped(Sut, Pid),
    {noreply, clear_pending(Ev, State)};
handle_info({'EXIT', Pid, Reason}, State) ->
    {stop, {proc_exit, Pid, Reason}, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%
%% Internal API
%%

clear_pending({'EXIT', Pid, normal},
              #sut{id = Identity, name = SutName,
                   config = Config, procs = Procs,
                   pending = Pending}=State) ->
    case [P || {_, {_, DyingPid}, _}=P <- Pending, DyingPid == Pid] of
        [{restart, {Id, Pid}=DeadProc, Client}]=Restart ->
            {ProcName, Host} = systest_utils:proc_id_and_hostname(Id),
            [Proc] = build_procs(SutName, SutName,
                                 {Host, [ProcName]}, Config),
            NewProc = start_proc(Identity, Proc),
            RemainingProcs = Procs -- [DeadProc],
            systest_proc:joined_sut(element(2, NewProc),
                                        State, RemainingProcs),
            gen_server:reply(Client, {restarted, {DeadProc, NewProc}}),
            NewProcState = [NewProc|(RemainingProcs)],
            NewPendingState = Pending -- Restart,
            State#sut{procs = NewProcState, pending = NewPendingState};
        _ ->
            State
    end.

shutdown(State=#sut{name=Id, procs=Procs}, Timeout, ReplyTo) ->
    %% NB: unlike systest_proc:shutdown_and_wait/2, this does not have to
    %% block and quite deliberately so - we want 'timed' shutdown when a
    %% common test hook is in effect unless the user prevents this...
    %%
    %% Another thing to note here is that systest_cleaner runs the kill_wait
    %% function in a different process. If we put a selective receive block
    %% here, we might well run into unexpected message ordering that could
    %% leave us in an inconsistent state.
    ProcRefs = [ProcRef || {_, ProcRef} <- Procs],
    case systest_cleaner:kill_wait(ProcRefs,
                                   fun systest_proc:stop/1, Timeout) of
        ok ->
            ct:log("Stopping SUT...~n"),
            [systest_watchdog:proc_stopped(Id, N) || N <- ProcRefs],
            gen_server:reply(ReplyTo, ok),
            {stop, normal, State};
        {error, {killed, StoppedOk}} ->
            ct:log("Halt Error: killed~n"),
            Err = {halt_error, orphans, ProcRefs -- StoppedOk},
            gen_server:reply(ReplyTo, Err),
            {stop, Err, State};
        Other ->
            ct:log("Halt Error: ~p~n", [Other]),
            gen_server:reply(ReplyTo, {error, Other}),
            {stop, {halt_error, Other}, State}
    end.

with_sut({Scope, Identity}, Handler, Config) ->
    case systest_config:sut_config(Scope, Identity) of
        {_, noconfig} ->
            noconfig;
        {Alias, SutConfig} ->
            try
                {Hosts, Hooks} = lists:splitwith(fun(E) ->
                                                     element(1, E) =/= on_start
                                                 end, SutConfig),
                ct:log("Configured hosts: ~p~n", [Hosts]),
                Procs = lists:flatten([Handler(Identity, Alias,
                                               Host, Config) || Host <- Hosts]),

                #sut{id = Identity,
                     scope = Scope,
                     name = Alias,
                     procs = Procs,
                     config = Config,
                     on_start = Hooks}
            catch _:Failed ->
                Failed
            end
    end.

%% TODO: make a Handler:status call to get detailed information back...
print_status_info({Proc, Status}) ->
    Lines = [{status, Status}|systest_proc:proc_data(Proc)],
    lists:flatten("Proc Info~n" ++ systest_utils:proplist_format(Lines) ++
                  "~n----------------------------------------------------~n").

build_procs(Identity, Sut, {Host, Procs}, Config) ->
    [systest_proc:make_proc(Sut, N, [{host, Host}, {scope, Identity},
                                         {name, N}|Config]) || N <- Procs].

start_host(Identity, Sut, {localhost, Procs}, Config) ->
    {ok, Hostname} = inet:gethostname(),
    start_host(Identity, Sut, {list_to_atom(Hostname), Procs}, Config);
start_host(Identity, Sut,
           {Host, Procs}=HostConf, Config) when is_atom(Host) andalso
                                                is_list(Procs) ->
    case ?CONFIG(verify_hosts, Config, false) of
        true  -> verify_host(Host);
        false -> ok
    end,
    [start_proc(Identity, Proc) ||
            Proc <- build_procs(Identity, Sut, HostConf, Config)].

start_proc(Identity, Proc) ->
    {ok, ProcRef} = systest_proc:start(Proc),
    systest_watchdog:proc_started(Identity, ProcRef),
    %% NB: the id field of Proc will *not* be set (correctly)
    %% until after the gen_server has started, so an API call
    %% is necessary rather than using systest_proc:get/2
    {?CONFIG(id, systest_proc:proc_data(ProcRef)), ProcRef}.

verify_host(Host) ->
    case systest_utils:is_epmd_contactable(Host, 5000) of
        true ->
            ok;
        {false, Reason} ->
            ct:log("Unable to contact ~p: ~p~n", [Host, Reason]),
            throw({host_unavailable, Host})
    end.
