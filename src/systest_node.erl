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
-module(systest_node).

-include("systest.hrl").

-type node_info() :: #'systest.node_info'{}.

-export_type([node_info/0]).

-export([behaviour_info/1]).
-export([make_node/3]).
-export([node_id/2]).
-export([start/1, stop/1, kill/1]).
-export([sigkill/1, stop_and_wait/1, kill_and_wait/1]).
-export([shutdown_and_wait/2, status/1, interact/2]).

-export([status_check/1]).

%% OTP gen_server Exports

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-exprecs_prefix([operation, "_"]).
-exprecs_fname([prefix, "node_info"]).
-exprecs_vfname([fname, "__", version]).

-compile({parse_transform, exprecs}).
-export_records(['systest.node_info']).

%%
%% Public API
%%

-spec behaviour_info(term()) -> any().
behaviour_info(callbacks) ->
    [{start,     1},
     {stop,      1},
     {kill,      1},
     {status,    1},
     {interact,  2},
     {handle_msg 2}];
behaviour_info(_) ->
    undefined.

-spec node_id(Host::atom(), Name::atom()) -> atom().
node_id(Host, Name) ->
    list_to_atom(atom_to_list(Name) ++ "@" ++ atom_to_list(Host)).

-spec make_node(atom(), atom(), systest_config:config()) -> node_info().
make_node(Scope, Node, Config) ->
    make_node([{ct, Config}] ++ Config ++ node_config(Scope, Node)).

-spec start(node_info()) -> node_info() | term().
start(NodeInfo=#'systest.node_info'{handler=Handler, link=ShouldLink,
                                    host=Host, name=Name, config=BaseConf}) ->
    ct:pal("Starting ~p on ~p~n", [Name, Host]),
    code:ensure_loaded(Handler),
    Id = case erlang:function_exported(Handler, id, 1) of
             true  -> Handler:id(NodeInfo);
             false -> node_id(Host, Name)
         end,
    NI = set_node_info([{id, Id},
                        {config,[{node, NodeInfo}|BaseConf]], NodeInfo),
    gen_server:start_link(?MODULE, [NI], []).

-spec stop(node_info()) -> ok.
stop(NI=#'systest.node_info'{handler=Handler, on_stop=Shutdown}) ->
    case Shutdown of
        [] -> ok;
        _  -> [ct:pal("~p~n", [interact(NI, In)]) || In <- Shutdown]
    end,
    Handler:stop(NI).

-spec kill(node_info()) -> ok.
kill(NI=#'systest.node_info'{handler=Handler}) ->
    Handler:kill(NI).

-spec sigkill(node_info()) -> string().
sigkill(#'systest.node_info'{os_pid=Pid}) ->
    ct:log("executing kill -9 ~s~n", [Pid]),
    Result = os:cmd("kill -9 " ++ Pid),
    ct:log(Result).

-spec stop_and_wait(node_info()) -> 'ok'.
stop_and_wait(NI) when is_record(NI, 'systest.node_info') ->
    shutdown_and_wait(NI, fun stop/1).

-spec kill_and_wait(node_info()) -> 'ok'.
kill_and_wait(NI) when is_record(NI, 'systest.node_info') ->
    shutdown_and_wait(NI, fun kill/1).

-spec status(node_info()) -> 'nodeup' | {'nodedown', term()}.
status(NI=#'systest.node_info'{handler=Handler}) ->
    Handler:status(NI).

-spec interact(node_info(), term()) -> term().
interact(Node, {local, Mod, Func, Args}) ->
    apply(Mod, Func, [Node|Args]);
interact(#'systest.node_info'{id=Node}, {Mod, Func, Args}) ->
    rpc:call(Node, Mod, Func, Args);
interact(NI=#'systest.node_info'{handler=Handler}, Inputs) ->
    Handler:interact(NI, Inputs).

%% NB: this *MUST* run on the client
shutdown_and_wait(NI=#'systest.node_info'{owner=Owner},
                  ShutdownOp) when is_pid(Owner) ->
    case (Owner == self()) orelse not(is_process_alive(Owner)) of
        true  -> ok;
        false -> link(Owner),
                 ct:log("Stopping ~p ....~n"
                        "Waiting for port owning process (~p) to exit...~n",
                        [NI#'systest.node_info'.id, Owner]),
                 ok = ShutdownOp(NI),
                 receive
                     {'EXIT', Owner, _Reason} -> ok;
                     Other                    -> ct:pal("Other ~p~n", [Other])
                 end
    end.

%%
%% OTP gen_server API
%%

-record(state, {node, handler, hander_state}).

init([Node#'systest.node_info'{handler=Handler]) ->
    process_flag(trap_exit, true),

    case catch( apply(Handler, start, [NodeInfo]) ) of
        {ok, NI2, HState} when is_record(NI2, 'systest.node_info') ->
            case NI2#'systest.node_info'.apps of
                []   -> ok;
                Apps -> [setup(NI2, App) || App <- Apps]
            end,
            %% TODO: we should really validate that these succeed!
            case NI2#'systest.node_info'.on_start of
                []   -> ok;
                Xtra -> [ct:pal("~p~n", [interact(NI2, In)]) || In <- Xtra]
            end,
            {ok, #state{node=NI2, handler=Handler, hander_state=HState}};
        Error ->
            %% TODO: do NOT rely on callbacks returning a proper gen_server
            %% init compatible response tuple - construct this for them....
            Error
    end.

handle_call(Msg, From, State) ->
    handle_msg(Msg, State, From).

handle_cast(Msg, St) ->
    handle_msg(Msg, State).

handle_info(Info, St#state{node=Node, handler=Mod, hander_state=Hs}) ->
    handle_msg(Info, State).

terminate(Reason, #state{handler=Mod}) ->
    ok = Mod:terminate(Reason, Node, State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%
%% Handler facing API
%%
status_check(Node) when is_atom(Node) ->
    case net_adm:ping(Node) of
        pong  -> nodeup;
        Other -> {nodedown, Other}
    end.

%%
%% Private API
%%

make_node(Config) ->
    %% NB: new_node_info is an exprecs generated function
    new_node_info([{scope,      ?REQUIRE(scope, Config)},
                   {host,       ?REQUIRE(host, Config)},
                   {name,       ?REQUIRE(name, Config)},
                   {handler,    lookup("startup.handler",
                                       Config, systest_cli)},
                   {link,       lookup("startup.link_to_parent",
                                       Config, false)},
                   {user,       ?CONFIG(user, Config, [])},
                   {flags,      ?CONFIG(flags, Config)},
                   {apps,       ?CONFIG(applications, Config)},
                   {on_start,   ?CONFIG(on_start, Config)},
                   {on_stop,    ?CONFIG(on_stop, Config)},
                   {config,     Config}]).

lookup(Key, Config, Default) ->
    case ?ECONFIG(Key, Config) of
        not_found -> Default;
        Value     -> Value
    end.

node_config(Cluster, Node) ->
    Nodes = systest_config:get_config({Cluster, nodes}),
    UserData = systest_config:get_config({Cluster, user_data}),
    ct:pal("Checking for ~p in ~p of ~p~n", [Node, Cluster, Nodes]),
    NodeConf = case ?CONFIG(Node, Nodes, undefined) of
                   undefined               -> [];
                   Refs when is_list(Refs) -> load_config(Refs)
               end,
    [{user, ?CONFIG(Node, UserData, [])}|NodeConf].

load_config(Refs) ->
    lists:foldl(fun merge_refs/2, [], Refs).

merge_refs(Ref, []) ->
    systest_config:get_config(Ref);
merge_refs(Ref, Acc) ->
    RefConfig = systest_config:get_config(Ref),
    Startup = systest_config:merge_config(
                    ?CONFIG(startup, Acc, []),
                    ?CONFIG(startup, RefConfig, [])),
    OnStart = ?CONFIG(on_start, Acc, []) ++
              ?CONFIG(on_start, RefConfig, []),
    OnStop  = ?CONFIG(on_stop, Acc, []) ++
              ?CONFIG(on_stop, RefConfig, []),

    Base = [ I || I={K, _} <- Acc,
                  lists:member(K, [flags, apps, user]) ],
    [{startup, Startup},
     {on_start, OnStart},
     {on_stop, OnStop}|Base].

setup(NI, {App, Vars}) ->
    interact(NI, {applicaiton, load, [App]}),
    [interact(NI, {application, set_env, [App, Env, Var]}) ||
                                            {Env, Var} <- Vars].

