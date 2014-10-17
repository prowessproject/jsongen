-module(jsg_store).

-export([put/2,get/1]).

put(Key,Value) ->
  ensure_open(),
  ets:insert(jsg_store,{Key,Value}).

get(Key) ->
  try ets:lookup(jsg_store,Key) of
    [{Key,Value}] -> {ok,Value};
    _ -> false
  catch _:_ -> false end.
      
ensure_open() ->
  case ets:info(jsg_store) of
    undefined ->
      open_db();
    _ ->
      ok
  end.

open_clean_db() ->
  open_db(),
  ets:delete_all(jsg_store).

open_db() ->
  spawn(fun () ->
	    ets:new(jsg_store,[named_table,public]),
	    wait_forever()
	end),
  wait_until_stable().

wait_forever() ->
  receive _ -> wait_forever() end.

wait_until_stable() ->
  case ets:info(jsg_store) of
    undefined ->
      timer:sleep(10),
      wait_until_stable();
    _ ->
      ok
  end.
  