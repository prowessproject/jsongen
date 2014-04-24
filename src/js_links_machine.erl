-module(js_links_machine).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").
-include_lib("eqc/include/eqc_dynamic_cluster.hrl").


%%-define(debug,true).

-ifdef(debug).
-define(LOG(X,Y),
	io:format("{~p,~p}: ~s~n", [?MODULE,?LINE,io_lib:format(X,Y)])).
-else.
-define(LOG(X,Y),true).
-endif.


-record(state,{static_links,links,private_state=void}).


api_spec() ->
  #api_spec{}.

initial_state() ->
  PrivateState = 
    case exists_private_function(initial_state,0) of
      true ->
	(private_module()):initial_state();
      false ->
	void
    end,
  #state
    {static_links=sets:from_list(initial_links()),
     links=sets:new(),
     private_state=PrivateState}.

command(State) ->
  make_call(command,fun command_int/1, [State]).

command_int(State) ->
  Alternatives =
    [
     {call, ?MODULE, follow_link, [Link,gen_http_request(Link)]} ||
      Link <-
	sets:to_list
	  (sets:union
	     (State#state.static_links,
	      State#state.links)),
      link_permitted(State,Link)
    ],
  eqc_gen:oneof(Alternatives).

callouts(_,_) ->
  ?EMPTY.

link_permitted(State,Link) ->
  make_call(link_permitted,fun link_permitted_int/2,[State,Link]).

link_permitted_int(State,Link) ->
  true.

precondition(State,Call) ->
  make_call(precondition,fun precondition_int/2,[State,Call]).

precondition_int(State,Call) ->
  case Call of
    {_, _, follow_link, [Link,_], _} ->
      (sets:is_element(Link,State#state.static_links) orelse
       sets:is_element(Link,State#state.links)) andalso
      link_permitted(State,Link)
  end.

postcondition(State,Call,Result) ->
  make_call(postcondition,fun postcondition_int/3,[State,Call,Result]).

postcondition_int(State,Call,Result) ->
  case validate_call_not_error_result(Call,Result) of
    true ->
      case http_result_code(Result) of
	200 ->
	  validate_call_result_body(Call,Result);
	Other ->
	  io:format
	    ("~n*** Error: postcondition error: for http call~n~s~nhttp responded with result code ~p, expected result code 200~n",
	     [format_http_call(Call),Other]),
	  false
      end;
    _ -> false
  end.

validate_call_not_error_result(Call,Result) ->
  case http_result_type(Result) of
    ok ->
      true;
    {error,Error} ->
      io:format
	("~n*** Error: postcondition error: for http call~n~s~nhttp responded with error ~p~n",
	 [format_http_call(Call),http_error(Result)]),
      false
  end.

validate_call_result_body(Call,Result) ->
  Link = test:link_link(Call),
  Schema = test:link_schema(Call),
  case jsg_jsonschema:propertyValue(Link,"targetSchema") of
    undefined ->
      true;
    TargetSchema ->
      RealTargetSchema = jsg_links:get_schema(TargetSchema,Schema),
      case response_has_json_body(Result) of
	false ->
	  false;
	true ->
	  Body = http_body(Result),
	  JSON = mochijson2:decode(Body),
	  try jesse_schema_validator:validate(RealTargetSchema,JSON,[]) of
	    {ok,_} -> true
	  catch Class:Reason ->
	      io:format
		("~n*** Error: postcondition error: for http call~n~s~n"++
		   "the JSON value~n~s~n"++
		   "did not validate against the schema~n~s~n"++
		   "due to error~n~p~n",
		 [format_http_call(Call),
		  mochijson2:encode(JSON),
		  mochijson2:encode(RealTargetSchema),
		  Reason]),
	      false
	  end
      end
  end.

next_state(State,Result,Call) ->
  make_call(next_state,fun next_state_int/3,[State,Result,Call]).

next_state_int(State,Result,Call) ->
  case Call of
    {_, ?MODULE, follow_link, [Link,_], _} ->
      case Result of
	{normal,{200,Body}} -> 
	  %%io:format("normal result: extracting links~n",[]),
	  NewLinks =
	    jsg_links:extract_dynamic_links(Link,mochijson2:decode(Body)),
	  State#state{links=sets:union(sets:from_list(NewLinks),State#state.links)};
	_ -> State
      end;
    _ -> ?LOG("Call was~n~p~n",[Call]), State
  end.

make_call(ExternalFunction,InternalFunction,Args) ->
  [{private_module,Module}] = 
    ets:lookup(js_links_machine_data,private_module),
  {arity,Arity} = erlang:fun_info(InternalFunction,arity),
  case exists_private_function(ExternalFunction,Arity+1) of
    true ->
      apply(Module,ExternalFunction,[InternalFunction|Args]);
    false ->
      ?LOG
	("function ~p:~p/~p missing~n",
	 [Module,ExternalFunction,Arity+1]),
      apply(InternalFunction,Args)
  end.

exists_private_function(Function,Arity) ->
  [{private_module,Module}] = 
    ets:lookup(js_links_machine_data,private_module),
  try Module:module_info(exports) of
      Exports -> lists:member({Function,Arity},Exports)
  catch _:_ -> false end.

private_module() ->
  [{private_module,Module}] = 
    ets:lookup(js_links_machine_data,private_module),
  Module.

initial_links() ->
  [{initial_links,Links}] =
    ets:lookup(js_links_machine_data,initial_links),
  Links.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

gen_http_request(Link) ->
  URI = jsg_links:compute_uri(Link),
  RequestType = jsg_links:request_type(Link),
  Argument = jsg_links:generate_argument(Link),
  {URI,RequestType,Argument}.

follow_link(Link,HTTPRequest={URI,RequestType,Argument}) ->
  ?LOG("~nfollow_link: URI is ~p; request ~p~n",[URI,RequestType]),
  Result =
    case Argument of
      {ok,Body} ->
	case has_body(RequestType) of
	  true ->
	    http_request_with_body(URI,RequestType,mochijson2:encode(Body));
	  false ->
	    http_request_with_headers(URI,RequestType,encode_headers(Body))
	end;
      _ ->
	http_request(URI,RequestType)
    end,
  Result.

format_http_call(Call) ->
  case Call of
    {_, ?MODULE, follow_link, [_,{URI,RequestType,Body}], _} ->
      format_http_call(URI,RequestType,Body)
  end.

format_http_call(URI,RequestType,Body) ->
  BodyString =
    case Body of
      {ok,JSON} ->
	io_lib:format(" body=~s",[mochijson2:encode(JSON)]);
      _ ->
	""
    end,
  io_lib:format
    ("~s using ~s~s",
     [URI,string:to_upper(atom_to_list(RequestType)),BodyString]).

has_body(get) ->
  false;
has_body(delete) ->
  false;
has_body(_) ->
  true.

encode_headers(X) ->
  X.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

http_request_with_body(URI,Type,Body) ->
  Result =
    httpc:request
      (Type,
       {URI,
	[],
	"application/json",
	iolist_to_binary(Body)},
       [{timeout,1500}],
       []),
  Result.

http_request_with_headers(URI,Type,Headers) ->
  Result =
    httpc:request
      (Type,
       {URI,
	Headers},
       [{timeout,1500}],
       []),
  Result.

http_request(URI,Type) ->
  Result = 
    httpc:request
      (Type,
       {URI,[]},
       [{timeout,1500}],
       []),
  Result.
  
http_result_type({ok,_}) ->
  ok;
http_result_type(Other) ->
  Other.

http_error({error,Error}) ->
  Error.

http_headers({ok,{_,Headers,_}}) ->
  Headers.

http_body({ok,{_,_,Body}}) ->
  Body.

http_status_line({ok,{StatusLine,_,_}}) ->
  StatusLine.

http_version(Result) ->
  case http_status_line(Result) of
    {Version,_,_} ->
      Version
  end.

http_result_code(Result) ->
  case http_status_line(Result) of
    {_,ResultCode,_} ->
      ResultCode
  end.

http_reason_phrase(Result) ->
  case http_status_line(Result) of
    {_,_,ReasonPhrase} ->
      ReasonPhrase
  end.

http_response_is_ok(Result) ->
  case http_result_type(Result) of
    ok ->  http_result_code(Result)==200;
    _ -> false
  end.

http_content_length(Result) ->
  Headers = http_headers(Result),
  proplists:get_value("content-length",Headers).

http_content_type(Result) ->
  Headers = http_headers(Result),
  proplists:get_value("content-type",Headers).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

response_has_body(Result) ->
  case http_result_type(Result) of
    ok -> 
      ContentLength = http_content_length(Result),
      if
	ContentLength=/=undefined ->
	  ContLen = list_to_integer(ContentLength),
	  ContLen>0;
	true -> 
	  false
      end;
    _ -> false
  end.

response_has_json_body(Result) ->
  case response_has_body(Result) of
    true -> http_content_type(Result) == "application/json";
    false -> false
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init_table(PrivateModule,Links) ->
  case ets:info(js_links_machine_data) of
    undefined ->
      ok;
    _ ->
      [{pid,Pid}] = ets:lookup(js_links_machine_data,pid),
      exit(Pid,kill),
      ets:delete(js_links_machine_data)
  end,
  spawn
    (fun () ->
	 ets:new(js_links_machine_data,[named_table,public]),
	 ets:insert(js_links_machine_data,{pid,self()}),
	 wait_forever()
     end),
  wait_until_stable(),
  ets:insert(js_links_machine_data,{private_module,PrivateModule}),
  ets:insert(js_links_machine_data,{initial_links,Links}).

wait_until_stable() ->
  case ets:info(js_links_machine_data) of
    L when is_list(L) ->
      ok;
    _ ->
      wait_until_stable()
  end.

wait_forever() ->
  receive _ -> wait_forever() end.

  
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

prop_ok() ->
  ?FORALL
     (Cmds, eqc_dynamic_cluster:dynamic_commands(?MODULE),
      ?CHECK_COMMANDS
	 ({H, DS, Res},
	  ?MODULE,
	  Cmds,
	  begin
	    if
	      Res == ok ->
		true;
	      true ->
		print_counterexample(Cmds,H,DS,Res),
		false
	    end
	  end)).

print_counterexample(Cmds,H,DS,Reason) ->
  io:format("~nTest failed with reason ~p~n",[Reason]),
  {FailingCommandSequence,_} = lists:split(length(H)+1,Cmds),
  ReturnValues = 
    case Reason of
      {exception,_} ->
	(lists:map(fun ({_,_,Result}) -> Result end, H))++[Reason];
      _ ->
	(lists:map(fun ({_,_,Result}) -> Result end, H))
    end,
  io:format("~nCommand sequence:~n"),
  io:format("---------------~n~n"),
  print_commands(lists:zip(tl(FailingCommandSequence),ReturnValues)),
  io:format("~n~n").

print_commands([]) ->
  ok;
print_commands([{Call={call,_,follow_link,_,_},Result}|Rest]) ->
  Title = test:link_title(Call),
  TitleString = 
    if 
      Title==undefined ->
	"Link ";
      true ->
	io_lib:format("Link ~p ",[Title])
    end,
  ResultString =
    case http_result_type(Result) of
      {error,Error} -> 
	io_lib:format(" ->~n    error ~p~n",[Error]);
      ok ->
	ResponseCode = http_result_code(Result),
	case response_has_body(Result) of
	  true -> 
	    io_lib:format
	      (" ->~n    ~p with body ~s",
	       [ResponseCode,http_body(Result)]);
	  false ->
	    io_lib:format
	      (" ->~n     ~p",
	       [ResponseCode])
	end
    end,
  io:format
    ("~saccess ~s~s~n~n",
     [TitleString,format_http_call(Call),ResultString]),
  print_commands(Rest).
  
test() ->
  case eqc:quickcheck(eqc:on_output(fun eqc_printer/2,prop_ok())) of
    false ->
      io:format("~n~n***FAILED~n");
    true ->
      io:format("~n~nPASSED~n",[])
  end.

%% To make eqc not print the horrible counterexample
eqc_printer(Format,String) ->
  case Format of
    "~p~n" -> ok;
    _ -> io:format(Format,String)
  end.

       

