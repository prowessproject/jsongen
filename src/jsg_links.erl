-module(jsg_links).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_dynamic_cluster.hrl").

-compile(export_all).


%%-define(debug,true).

-ifdef(debug).
-define(LOG(X,Y),
	io:format("{~p,~p}: ~s~n", [?MODULE,?LINE,io_lib:format(X,Y)])).
-else.
-define(LOG(X,Y),true).
-endif.


%% Given a set of file corresponding to JSON schemas,
%% traverse the schemas to find (non-relative) link definitions.

compute_uri(Link={link,LinkData}) ->
  Href = link_href(Link),
  Template = uri_template:parse(binary_to_list(Href)),
  uri_template:sub(Link,binary_to_list(Href)).

generate_argument(Link) ->
  jsg_store:put(eqc_gen_context,Link),
  S = get_schema(link_schema(Link)),
  Sch = link_def(Link),
  Schema = jsg_jsonschema:propertyValue(Sch,"schema"),
  QuerySchema = jsg_jsonschema:propertyValue(Sch,"querySchema"),
  RequestType = link_request_type(Link),
  Body = 
    case may_have_body(RequestType) of
      true when Schema=/=undefined -> 
	BodyGen = jsongen:json(Schema),
	{ok,eqc_gen:pick(BodyGen)};
      _ -> 
	undefined
    end,
  QueryParameters =
    case may_have_body(RequestType) of
      true when QuerySchema=/=undefined ->
	QGen = jsongen:json(QuerySchema),
	{ok,eqc_gen:pick(QGen)};
      false when QuerySchema=/=undefined ->
	QGen = jsongen:json(QuerySchema),
	{ok,eqc_gen:pick(QGen)};
      false when Schema=/=undefined ->
	QGen = jsongen:json(Schema),
	{ok,eqc_gen:pick(QGen)};
      _ ->
	undefined
    end,
  {Body,QueryParameters}.

may_have_body(get) ->
  false;
may_have_body(delete) ->
  false;
may_have_body(_) ->
  true.

extract_dynamic_links(Link,Term,Object) ->
  S = link_schema(Link),
  LD = link_def(Link),
  Title = link_title(Link),
  NewHistory = [{Title,Object}|link_history(Link)],
  DynamicLinks =
    case jsg_jsonschema:propertyValue(LD,"targetSchema") of
      undefined ->
	[];
      SchemaDesc ->
	extract_links(Link,SchemaDesc,Term,[],Object,NewHistory)
    end,
  lists:map
    (fun ({link,Props}) -> 
	 {link,
	  [{object,Object},{history,NewHistory}|
	   proplists:delete(history,Props)]}
     end, DynamicLinks).

extract_links(FollowedLink,Sch,Term,Pointer,Object,History) ->
  Schema = {struct,Proplist} = get_schema(Sch),
  case proplists:get_value(<<"type">>,Proplist) of
    undefined ->
      %% Could be a union schema; we don't handle this yet
      [];

    <<"object">> ->
      Links = js_links_machine:collect_schema_links(Sch,true),
      ShallowLinks =
	lists:flatmap
	  (fun (Link={link,Props}) ->
	       Href = link_href(Link),
	       Template = uri_template:parse(binary_to_list(Href)),
	       try uri_template:sub({FollowedLink,Object,lists:reverse(Pointer)},Template) of
		   CHREF -> [{link,[{calculated_href,CHREF}|Props]}]
	       catch _:_ ->
		   io:format
		     ("*** Warning: skipping link ~p due to problems "++
			"resolving href~n",
		      [link_title(Link)]),
		   []
	       end
	   end,
	   Links),
      DeepLinks =
	extract_links_from_subterms
	  (FollowedLink,Schema,Term,Pointer,Object,History),
      ShallowLinks++DeepLinks;

    <<"array">> ->
      case proplists:get_value(<<"items">>,Proplist) of
	ItemSchemaDesc={struct,_} ->
	  {_,Result} =
	    lists:foldl
	      (fun (SubItem,{Index,Acc}) ->
		   SubItemLinks =
		     extract_links
		       (FollowedLink,ItemSchemaDesc,SubItem,[Index|Pointer],
			Object,History),
		   {Index+1,SubItemLinks++Acc}
	       end,
	       {0,[]},
	       Term),
	  Result;
	_ -> []
      end;
    
    _Other -> []
  end.

extract_links_from_subterms(FollowedLink,{struct,Proplist},Term,Pointer,Object,History) ->
  case proplists:get_value(<<"properties">>,Proplist) of
    undefined -> [];
    {struct,Properties} ->
      lists:flatmap
	(fun ({Property,Def}) ->
	     {struct,Props} = Term,
	     case proplists:get_value(Property,Props) of
	       undefined ->
		 [];
	       SubProp ->
		 extract_links
		   (FollowedLink,Def,SubProp,[binary_to_list(Property)|Pointer],Object,History)
	     end
	 end, Properties)
  end.

intern_object(Term) ->
  %% This is far from process safe...
  case jsg_store:get(Term) of
    {ok,N} -> N;
    _ -> 
      Counter =
	case jsg_store:get(object_counter) of
	  {ok,Cnt} ->
	    Cnt;
	  _ ->
	    jsg_store:put(object_counter,0),
	    0
	end,
      jsg_store:put(Term,Counter),
      jsg_store:put({object,Counter},Term),
      jsg_store:put(object_counter,Counter+1),
      Counter
  end.

get_schema(Value={struct,Proplist}) ->
  get_schema(Value,{struct,[]});
get_schema([Child,Root]) ->
  get_schema(Child,Root).

get_schema(Value={struct,Proplist},Root) ->
  case proplists:get_value(<<"$ref">>,Proplist) of
    undefined ->
      Value;
    Ref ->
      %%io:format("Ref is ~p Root is~n~p~n",[Ref,Root]),
      jsg_jsonref:unref(Value,Root)
  end.

make_schema(Schema,Parent) ->
  case is_parent_relative(Schema) of
    true ->
      [Schema,Parent];
    false ->
      Schema
  end.

is_parent_relative({struct,Proplist}) ->
  case proplists:get_value(<<"$ref">>,Proplist) of
    undefined ->
      false;
    Ref ->
      case binary_to_list(Ref) of
	[$#|_] -> true;
	_ -> false
      end
  end.
  
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

link_def(Link) ->
  Schema = link_schema(Link),
  RootSchema = {struct,[]},
  {struct,SchemaDef} = get_schema(Schema,RootSchema),
  N = link_num(Link),
  Links = proplists:get_value(<<"links">>,SchemaDef),
  %%io:format("Links are ~p~n",[Links]),
  lists:nth(N,Links).

link_title(Link) ->
  {struct,LinkDef} = link_def(Link),
  case proplists:get_value(<<"title">>,LinkDef) of
    L when is_binary(L) ->
      binary_to_list(L);
    Other ->
      Other
  end.

print_link(Link={link,LD}) ->
  {struct,LinkDef} = link_def(Link),
  LinkTitle = 
    case proplists:get_value(<<"title">>,LinkDef) of
      L when is_binary(L) ->
	binary_to_list(L);
      Other ->
	Other
    end,
  Href =
    proplists:get_value(<<"href">>,LinkDef),
  Schema =
    proplists:get_value(schema,LD),
  Object =
    proplists:get_value(object,LD),
  {link,[{title,LinkTitle},{href,Href},{schema,Schema},{object,Object}]}.

link_request_type(Link) ->
  {struct,LinkDef} = link_def(Link),
  case proplists:get_value(<<"method">>,LinkDef) of
    undefined -> get;
    Other -> list_to_atom(string:to_lower(binary_to_list(Other)))
  end.

link_href(Link) ->
  {struct,LinkDef} = link_def(Link),
  proplists:get_value(<<"href">>,LinkDef).

link_targetSchema(Link) ->
  {struct,LinkDef} = link_def(Link),
  proplists:get_value(<<"targetSchema">>,LinkDef).

link_schema(Link) ->
  {link,LD} = Link,
  proplists:get_value(schema,LD).

link_num(Link) ->
  {link,LD} = Link,
  proplists:get_value(link,LD).

link_history(Link) ->
  {link,LD} = Link,
  proplists:get_value(history,LD,[]).

link_calculated_href(Link) ->	     
  {link,LD} = Link,
  proplists:get_value(calculated_href,LD,[]).
      
  
