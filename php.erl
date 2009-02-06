%%%-------------------------------------------------------------------
%%% File    : php.erl
%%% Author  : Andy Skelton <andy@automattic.com>
%%% Purpose : Provides API for evaluating PHP code.
%%% Created : 15 Jan 2009 by Andy Skelton <andy@automattic.com>
%%%
%%% Copyright (C) 2009 Automattic
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%-------------------------------------------------------------------

%% @author Andy Skelton <andy@automattic.com>
%%                      [http://andy.wordpress.com/]
%% @doc This module provides all of the API functions and a gen_server
%%      that marshals requests for PHP code evaluation. It maintains
%%      queues of available and reserved PHP processes and serves each
%%      client request in order. PHP processes are reused to cut down
%%      on startup overhead and memory limits are checked after each
%%      PHP code evaluation to help prevent resource hogging.
%%
%%      Configuration is done in the php.app file. Options include the
%%      path to the PHP binary, code to initialize the environment,
%%      and a default memory limit. It is also possible to set the
%%      number of concurrent PHP instances; the default is the number
%%      of logical processors available to the Erlang VM.
-module(php).

-behaviour(gen_server).

%% API
-export([
		 start/0,
		 stop/0,
		 start_link/0,
		 eval/1,eval/2,eval/3,
		 reserve/0,reserve/1,
		 release/1,
		 get_mem/1,
		 restart_all/0
		]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		 terminate/2, code_change/3]).

-record(state, {
		  sup,
		  free     = [],
		  reserved = [],
		  waiting  = [],
		  restart
		 }).

-record(php, {
		  ref,
		  pid,
		  maxmem
		 }).

-record(restart, {
		  pids = [],
		  froms = []
		 }).

%%====================================================================
%% API
%%====================================================================

%% @spec start() -> ok
%% @doc Starts the PHP application, supervisor, a number of workers,
%%      and this API server module with the options set in php.app.
start() ->
	application:start(php).

%% @spec stop() -> ok
%% @doc Stops the PHP application and everything it started.
stop() ->
	application:stop(php).

%% @private
%% @spec start_link() -> {ok, state()}
%% @doc An entry point for the supervisor. This calls init(Pid) with
%%      the pid of the supervisor so we can discover the workers.
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, self(), []).

%% @spec eval(Code) -> result()
%%       Code = list() | binary()
%% @type result() = ( {ok, Output, Return, Error, Status} |
%%                    {parse_error, Error, Status}        |
%%                    {exit, ExitCode | timeout} )
%%       Output   = binary()
%%       Return   = any()
%%       Error    = binary()
%%       Status   = continue | break
%%       ExitCode = integer()
%% @doc Equivalent to eval(Code, undefined, infinity).
eval(Code) ->
	eval(Code, undefined, infinity).

%% @spec eval(Code, (reference() | Timeout)) -> result()
%%       Timeout = integer() | infinity
%% @doc Equivalent to eval(Code, Php, infinity) or eval(Code,
%%      undefined, Timeout).
eval(Code, Ref) when is_reference(Ref) ->
	eval(Code, Ref, infinity);
eval(Code, Timeout) when is_integer(Timeout), Timeout > 0; Timeout =:= infinity ->
	eval(Code, undefined, Timeout);
eval(_, _) ->
	{error, invalid_argument}.

%% @spec eval(Code, Ref, Timeout) -> result() | {error, term()}
%%       Code     = list() | binary()
%%       Ref      = reference() | undefined
%%       Timeout  = integer() | infinity
%% @doc Tests syntax and evaluates PHP code.
%%      A parse error will result in {parse_error, Error, Status}.
%%      A fatal error or exit() will result in {exit, ExitCode}.
%%      On success, Error contains the last error message. You may
%%      call trigger_error() to store a string here but an error or
%%      warning (subject to error_reporting()) will overwrite it.
%%      Status indicates whether the PHP process continued or broke
%%      after evaluation. This suggests that any variables you set
%%      in a reserved PHP persist but that can not be guaranteed.
eval(Code, Ref, Timeout) ->
	gen_server:call(?MODULE, {eval, Code, Ref, Timeout}, infinity).

%% @spec reserve() -> reference()
%% @doc Equivalent to reserve(undefined).
reserve() ->
	reserve(undefined).

%% @spec reserve(MaxMem) -> reference()
%%       MaxMem  = integer() | infinity | undefined
%% @doc Reserves a PHP instance that will only be accessible to
%%      callers possessing the key returned by this function. A
%%      reservation can be passed around or held indefinitely.
%%      MaxMem is in KiB. PHP size is measured by `'ps -o rss`'
%%      after each evaluation and if it exceeds MaxMem, the PHP
%%      instance is restarted and the returned Status is break.
%%      If MaxMem is undefined, it becomes the value in php.app.
reserve(MaxMem) ->
	gen_server:call(?MODULE, {reserve, MaxMem, ref}, infinity).

%% @spec release(reference()) -> ok
%% @doc Cancels the reservation of a PHP instance, returning it
%%      to the pool of available instances.
release(Ref) ->
	gen_server:cast(?MODULE, {release, Ref}).

%% @spec get_mem(reference()) -> integer() | {error, term()}
%% @doc Measures the memory footprint of the PHP instance using
%%      `'ps -o rss`'. If the instance has died, it is restarted
%%      before the measurement is taken.
get_mem(Ref) ->
	gen_server:call(?MODULE, {get_mem, Ref}, infinity).

%% @spec restart_all() -> ok
%% @doc Restarts each PHP thread, waiting if any are reserved. This
%%      is intended to force an updated PHPLOOP into use.
restart_all() ->
	gen_server:call(?MODULE, restart_all, infinity).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init(From) ->
	process_flag(trap_exit,true),
	State=#state{sup=From,restart=#restart{}},
	{ok, State}.

%% @private
handle_call(get_state, _From, State) ->
	{reply, State, State};
handle_call({eval, Code, Ref, Timeout}, From, State) ->
	Php = if
			  Ref =:= undefined ->
				  undefined;
			  true ->
				  find_php(Ref, State#state.reserved)
		  end,
	if
		Php =:= none ->
			{reply, {error, invalid_reservation}, State};
		true ->
			spawn_link( fun () -> do_eval(Code, Php, From, Timeout) end ),
			{noreply, State}
	end;
handle_call({reserve, MaxMem, What}, From, State) ->
	case State#state.waiting of
		[] -> % no processes waiting for php reservation
			case {State#state.free, State#state.reserved} of
				{[],[]} -> % php_eval workers undiscovered (first call to reserve)
					[Pid|Free] = lists:foldl(
									  fun ({_,Pid,_,[php_eval]}, Acc)->[Pid|Acc];
										  (_, Acc) -> Acc
									  end,
									  [],
									  supervisor:which_children(State#state.sup)
									 ),
					Php = make_php(Pid,MaxMem),
					{reply, make_reply(Php, What), State#state{free=Free, reserved=[Php]}};
				{[],_} -> % all php_eval workers are reserved
					Waiting = [{From,MaxMem,What}],
					{noreply, State#state{waiting=Waiting}};
				{[Pid|Free],_} -> % at least one php_eval worker is free
					Php = make_php(Pid,MaxMem),
					Reserved = [Php|State#state.reserved],
					{reply, make_reply(Php, What), State#state{free=Free, reserved=Reserved}}
			end;
		_ -> % processes are already waiting
			Waiting = State#state.waiting++[{From,MaxMem,What}],
			{noreply, State#state{waiting=Waiting}}
	end;
handle_call({get_mem, Ref}, From, State) ->
	case find_php(Ref, State#state.reserved) of
		none -> {reply, {error, invalid_reservation}, State};
		Php  ->
			spawn_link( fun () -> do_get_mem(Php, From) end ),
			{noreply, State}
	end;
handle_call(restart_all, From, State) ->
	Froms = (State#state.restart)#restart.froms,
	Pids = all_pids(State),
	[spawn(fun()->eval(";")end) || _ <- lists:seq(1,length(Pids))],
	{noreply, State#state{restart=#restart{froms=[From|Froms],pids=Pids}}};
handle_call(Request, _From, State) ->
	{reply, {unknown_call, Request}, State}.

%% @private
handle_cast({release, Ref}, State) ->
	case find_php(Ref, State#state.reserved) of
		none ->
			{noreply, State};
		Php ->
			State2 = maybe_restart(Php#php.pid, State),
			State3 = do_release(Php, State2),
			{noreply, State3}
	end;
handle_cast(_Msg, State) ->
	{noreply, State}.

%% @private
handle_info(_Info, State) ->
	{noreply, State}.

%% @private
terminate(_Reason, _State) ->
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

reserve_php() ->
	gen_server:call(?MODULE, {reserve, undefined, php}, infinity).

maybe_restart(Pid, #state{restart=#restart{froms=Froms,pids=Pids}}=State) ->
	case lists:member(Pid, Pids) of
		false ->
			State;
		true ->
			gen_server:call(Pid, {eval, "exit;", 1, infinity}, infinity),
			Pids2 = lists:delete(Pid, Pids),
			if
				Pids2 =:= [] ->
					Restart = #restart{},
					lists:foreach(
					  fun (From) -> gen_server:reply(From, ok) end,
					  Froms
					 );
				true ->
					Restart = #restart{froms=Froms,pids=Pids2}
			end,
			State#state{restart=Restart}
	end.

do_release(Php, State) ->
	Reserved = lists:delete(Php, State#state.reserved),
	Free = State#state.free ++ [Php#php.pid],
	case State#state.waiting of
		[] -> % no processes in the queue
			State#state{reserved=Reserved, free=Free};
		[{From,MaxMem,What}|Waiting] -> % there is a process waiting for a reservation
			[Pid|NewFree] = Free,
			NextPhp=make_php(Pid,MaxMem),
			gen_server:reply(From, make_reply(NextPhp, What)),
			State#state{waiting=Waiting, reserved=[NextPhp|Reserved], free=NewFree}
	end.

do_eval(Code, #php{pid=Pid,maxmem=MaxMem}, From, Timeout) ->
	Reply = gen_server:call(Pid, {eval, Code, Timeout, MaxMem}, infinity),
	gen_server:reply(From, Reply);
do_eval(Code, _, From, Timeout) ->
	Php = reserve_php(),
	do_eval(Code, Php, From, Timeout),
	release(Php#php.ref).

do_get_mem(#php{pid=Pid}, From) ->
	Mem = gen_server:call(Pid, get_mem),
	gen_server:reply(From, Mem).

all_pids(#state{free=[], reserved=[]}) ->
	[];
all_pids(#state{free=Free,reserved=Reserved}) ->
	lists:foldl(
	  fun (#php{pid=Pid}, Acc) -> [Pid|Acc] end,
	  Free,
	  Reserved
	 ).

make_php(Pid, MaxMem) ->
	#php{ref=make_ref(),pid=Pid,maxmem=MaxMem}.

find_php(_, []) ->
	none;
find_php(Ref, [#php{ref=Ref}=Php|_]) ->
	Php;
find_php(Ref, [_|T]) ->
	find_php(Ref, T).

make_reply(Php, php) ->
	Php;
make_reply(#php{ref=Ref}, ref) ->
	Ref.
