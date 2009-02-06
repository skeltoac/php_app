%%%-------------------------------------------------------------------
%%% File    : php_app.erl
%%% Author  : Andy Skelton <andy@automattic.com>
%%% Purpose : Helps start php_sup
%%% Created : 15 Jan 2009 by Andy Skelton <andy@automattic.com>
%%% License : GPLv2
%%%-------------------------------------------------------------------
-module(php_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, StartArgs) ->
	php_sup:start_link(StartArgs).

stop(_State) ->
	ok.
