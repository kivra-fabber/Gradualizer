-module(typechecker).

-compile([export_all]).

compatible({type, _, any, []}, _) ->
  true;
compatible(_, {type, _, any, []}) ->
  true;
compatible({type, _, 'fun', Args1, Res1},{type, _, 'fun', Args2, Res2}) ->
    compatible_lists(Args1, Args2) andalso
	compatible(Res1, Res2);
compatible({type, _, tuple, Tys1}, {type, _, tuple, Tys2}) ->
    compatible_lists(Tys1, Tys2);
compatible({user_type, _, Name1, Args1}, {user_type, _, Name2, Args2}) ->
    Name1 =:= Name2 andalso
	compatible_lists(Args1, Args2);
compatible(_, _) ->
    false.



compatible_lists(TyList1,TyList2) ->
    length(TyList1) =:= length(TyList2) andalso
	lists:all(fun ({Ty1, Ty2}) ->
			  compatible(Ty1, Ty2)
		  end
		 ,lists:zip(TyList1, TyList2)).

-spec type_check_expr(#{ any() => any() },#{ any() => any() },any()) -> any().
type_check_expr(_FEnv, VEnv, {var, _, Var}) ->
    maps:get(Var, VEnv);
type_check_expr(FEnv, VEnv, {tuple, _, [TS]}) ->
    [ type_check_expr(FEnv, VEnv, Expr) || Expr <- TS ];
type_check_expr(FEnv, VEnv, {call, _, Name, Args}) ->
    ArgTys = [ type_check_expr(FEnv, VEnv, Arg) || Arg <- Args],
    case type_check_fun(FEnv, VEnv, Name) of
	{type, _, any, []} ->
	    {type, 0, any, []};
	{type, _, 'fun', [{type, _, product, TyArgs}, ResTy]} ->
	    case compatible_lists(TyArgs, ArgTys) of
		true ->
		    ResTy;
		false ->
		    throw(type_error)
	    end
    end;
type_check_expr(FEnv, VEnv, {block, _, Block}) ->
    type_check_block(FEnv, VEnv, Block);
type_check_expr(_FEnv, _VEnv, {string, _, _}) ->
    {usertype, 0, string, []};
type_check_expr(_FEnv, _VEnv, {nil, _}) ->
    {type, 0, nil, []}.




type_check_fun(FEnv, _VEnv, {atom, _, Name}) ->
    maps:get(Name, FEnv);
type_check_fun(FEnv, _VEnv, {remote, _, {atom,_,Module}, {atom,_,Fun}}) ->
    maps:get({Module,Fun}, FEnv);
type_check_fun(FEnv, VEnv, Expr) ->
    type_check_expr(FEnv, VEnv, Expr).

type_check_block(FEnv, VEnv, [Expr]) ->
    type_check_expr(FEnv, VEnv, Expr);
type_check_block(FEnv, VEnv, [Expr | Exprs]) ->
    type_check_expr(FEnv, VEnv, Expr),
    type_check_block(FEnv, VEnv, Exprs).

infer_clauses(FEnv, VEnv, Clauses) ->
    merge_types(lists:map(fun (Clause) ->
				  infer_clause(FEnv, VEnv, Clause)
			  end, Clauses)).

infer_clause(FEnv, VEnv, {clause, _, Args, [], Block}) -> % We don't accept guards right now.
    VEnvNew = add_any_types_pats(Args, VEnv),
    type_check_block(FEnv, VEnvNew, Block).

check_clauses(FEnv, VEnv, ArgsTy, Clauses) ->
    merge_types(lists:map(fun (Clause) ->
				  check_clause(FEnv, VEnv, ArgsTy, Clause)
			  end, Clauses)).

check_clause(FEnv, VEnv, ArgsTy, {clause, _, Args, [], Block}) ->
    case length(ArgsTy) =:= length(Args) of
	false ->
	    throw(argument_length_mismatch);
	true ->
	    VEnvNew = add_types_pats(Args, ArgsTy, VEnv),
	    type_check_block(FEnv, VEnvNew, Block)
    end.
	    

type_check_function(FEnv, {function,_, Name, _NArgs, Clauses}) ->
    case maps:find(Name, FEnv) of
	{ok, {type, _, 'fun', [{type, _, product, ArgsTy}, ResTy]}} ->
	    Ty = check_clauses(FEnv, #{}, ArgsTy, Clauses),
	    case compatible(Ty, ResTy) of
		true -> ResTy;
		false -> throw(result_type_mismatch)
	    end;
	error ->
	    Types = infer_clauses(FEnv, #{}, Clauses),
	    merge_types(Types)
    end.

type_check_file(File) ->
    {ok, Forms} = epp:parse_file(File,[]),
    {Specs, Funs} = collect_specs_and_functions(Forms),
    FEnv = create_fenv(Specs),
    lists:map(fun (Function) ->
		      type_check_function(FEnv, Function) end, Funs).

collect_specs_and_functions(Forms) ->
    aux(Forms,[],[]).
aux([], Specs, Funs) ->
    {Specs, Funs};
aux([Fun={function, _, _, _, _} | Forms], Specs, Funs) ->
    aux(Forms, Specs, [Fun | Funs]);
aux([{attribute, _, spec, Spec} | Forms], Specs, Funs) ->
    aux(Forms, [Spec | Specs], Funs);
aux([_|Forms], Specs, Funs) ->
    aux(Forms, Specs, Funs).

merge_types([Ty]) ->
    Ty;
merge_types(apa) ->
    error.

create_fenv([{{Name,_},[Type]}|Specs]) ->
    (create_fenv(Specs))#{ Name => Type };
create_fenv([{{Name,_},_}|_]) ->
    throw({multiple_types_not_supported,Name});
create_fenv([]) ->
    #{}.

add_types_pats([], [], VEnv) ->
    VEnv;
add_types_pats([Pat | Pats], [Ty | Tys], VEnv) ->
    add_types_pats(Pats, Tys, add_type_pat(Pat, Ty, VEnv)).

add_type_pat({var, _, '_'}, _Ty, VEnv) ->
    VEnv;
add_type_pat({var, _, A}, Ty, VEnv) ->
    VEnv#{ A => Ty }.


add_any_types_pats([], VEnv) ->
    VEnv;
add_any_types_pats([Pat|Pats], VEnv) ->
    add_any_types_pats(Pats, add_any_types_pat(Pat, VEnv)).

add_any_types_pat(A, VEnv) when is_atom(A) ->
    VEnv;
add_any_types_pat({match, _, P1, P2}, VEnv) ->
    add_any_types_pats([P1, P2], VEnv);
add_any_types_pat({cons, _, Head, Tail}, VEnv) ->
    add_any_types_pats([Head, Tail], VEnv);
add_any_types_pat({nil, _}, VEnv) ->
    VEnv;
add_any_types_pat({tuple, _, Pats}, VEnv) ->
    add_any_types_pats(Pats, VEnv);
add_any_types_pat({var, _,'_'}, VEnv) ->
    VEnv;
add_any_types_pat({var, _,A}, VEnv) ->
    VEnv#{ A => {type, 0, any, []} }.





