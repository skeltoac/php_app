%%%-------------------------------------------------------------------
%%% File    : php.erl
%%% Author  : Richard Jones <rj@last.fm>, Andy Skelton <andy@automattic.com>
%%% Purpose : Provides API for evaluating PHP code.
%%% Created : 19 Jan 2009 by Andy Skelton <andy@automattic.com>
%%% License : GPLv2
%%%-------------------------------------------------------------------

%%
%% Takes a serialized php object and turns it into an erlang data structure
%%
-module(php_util).
-author("Richard Jones <rj at last.fm>"). % http://www.metabrew.com/article/reading-serialized-php-objects-from-erlang/ GPLv2
-author("Andy Skelton <andy at automattic.com>"). % minor tweaks
-export([unserialize/1]).
-export([get_opt/3]).
%% Usage:  {Result, Leftover} = php:unserialize(...)
unserialize(S) when is_binary(S) ->
	unserialize(binary_to_list(S));
unserialize(S) when is_list(S) ->
	{[Result], Rest} = takeval(S, 1),
	{Result, Rest}.

%% Internal stuff

takeval(Str, Num) ->
	{Parsed, Remains} = takeval(Str, Num, []),
	{lists:reverse(Parsed), Remains}.

takeval([$} | Leftover], 0, Acc)    -> {Acc, Leftover};
takeval(Str, 0, Acc)                -> {Acc, Str};
takeval([], 0, Acc)                 -> Acc;

takeval(Str, Num, Acc) ->
    {Val, Rest} = phpval(Str),
	%%Lots of tracing if you enable this:
	%%io:format("\nState\n Str: ~s\n Num: ~w\n Acc:~w\n", [Str,Num,Acc]),
	%%io:format("-Val: ~w\n-Rest: ~s\n\n",[Val, Rest]),
    takeval(Rest, Num-1, [Val | Acc]).
%%
%% Parse induvidual php values.
%% a "phpval" here is T:val; where T is the type code for int, object, array etc..
%%
%% Simple ones:
phpval([])                      -> {[],[]};
phpval([ $} | Rest ])           -> phpval(Rest);    % skip }
phpval([$N,$;|Rest])            -> {null, Rest};    % null
phpval([$E,$;|Rest])            -> {error, Rest};   % error (custom)
phpval([$b,$:,$1,$; | Rest])    -> {true, Rest};    % true
phpval([$b,$:,$0,$; | Rest])    -> {false, Rest};   % false
%% r seems to be a recursive reference to something, represented as an int.
phpval([$r, $: | Rest]) ->
    {RefNum, [$; | Rest1]} = string:to_integer(Rest),
    {{php_ref, RefNum}, Rest1};
%% int
phpval([$i, $: | Rest])->
    {Num, [$; | Rest1]} = string:to_integer(Rest),
    {Num, Rest1};
%% double / float
%% NB: php floats can be ints, and string:to_float doesn't like that.
phpval([$d, $: | Rest]) ->
    {Num, [$; | Rest1]} = case string:to_float(Rest) of
							  {error, no_float} -> string:to_integer(Rest);
							  {N,R} -> {N,R}
						  end,
    {Num, Rest1};
%% string
phpval([$s, $: | Rest]) ->
    {Len, [$: | Rest1]} =string:to_integer(Rest),
    S = list_to_binary(string:sub_string(Rest1, 2, Len+1)),
    {S, lists:nthtail(Len+3, Rest1)};
%% array
phpval([$a, $: | Rest]) ->
    {NumEntries, [$:, 123 | Rest1]} =string:to_integer(Rest), % 123 is ${
	{Array, Rest2} = takeval(Rest1, NumEntries*2),
	{arraytidy(Array), Rest2};

%% object O:4:\"User\":53:{
phpval([$O, $: | Rest]) ->
	{ClassnameLen, [$: | Rest1]} =string:to_integer(Rest),
	%% Rest1: "classname":NumEnt:{..
	Classname = string:sub_string(Rest1, 2, ClassnameLen+1),
	Rest1b = lists:nthtail(ClassnameLen+3, Rest1),
	{NumEntries, [$:, 123 | Rest2]} = string:to_integer(Rest1b), % 123 is ${
	{Classvals, Rest3} = takeval(Rest2, NumEntries*2),
	{{class, Classname, arraytidy(Classvals)}, Rest3};

%% string does not begin with serialized data
phpval(String) ->
	{none, String}.

%%
%% Helpers:
%%
%% convert [ k1,v1,k2,v2,k3,v3 ] into [ {k1,v2}, {k2,v2}, {k3,v3} ]
arraytidy(L) ->
    lists:reverse(lists:foldl(fun arraytidy/2, [], L)).

arraytidy(El, [{K, '_'} | L]) ->
	[{listify(K), El} | L];
arraytidy(El, L) ->
	[{El, '_'} | L].

%%% Make binary array keys into lists
listify(K) when is_binary(K) ->
    listify(binary_to_list(K));
listify(K) ->
	K.

get_opt(Opt, Opts, Default) ->
	case lists:keysearch(Opt, 1, Opts) of
		{value, {Opt, Value}} ->
			Value;
		_ -> Default
	end.
