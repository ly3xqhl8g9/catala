(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020 Inria, contributor:
   Denis Merigoux <denis.merigoux@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

(** Translation from {!module: Desugared.Ast} to {!module: Scopelang.Ast} *)

open Catala_utils
open Shared_ast
module D = Desugared.Ast

(** {1 Expression translation}*)

type target_scope_vars =
  | WholeVar of ScopeVar.t
  | States of (StateName.t * ScopeVar.t) list

type ctx = {
  decl_ctx : decl_ctx;
  scope_var_mapping : target_scope_vars ScopeVar.Map.t;
  reentrant_vars : typ ScopeVar.Map.t;
  var_mapping : (D.expr, untyped Ast.expr Var.t) Var.Map.t;
}

let tag_with_log_entry
    (e : untyped Ast.expr boxed)
    (l : log_entry)
    (markings : Uid.MarkedString.info list) : untyped Ast.expr boxed =
  if Global.options.trace <> None then
    Expr.eappop
      ~op:(Log (l, markings), Expr.pos e)
      ~tys:[Type.any (Expr.pos e)]
      ~args:[e] (Mark.get e)
  else e

let rec translate_expr (ctx : ctx) (e : D.expr) : untyped Ast.expr boxed =
  let m = Mark.get e in
  match Mark.remove e with
  | EVar v -> Expr.evar (Var.Map.find v ctx.var_mapping) m
  | EAbs { binder; pos; tys } ->
    let vars, body = Bindlib.unmbind binder in
    let new_vars = Array.map (fun var -> Var.make (Bindlib.name_of var)) vars in
    let ctx =
      List.fold_left2
        (fun ctx var new_var ->
          { ctx with var_mapping = Var.Map.add var new_var ctx.var_mapping })
        ctx (Array.to_list vars) (Array.to_list new_vars)
    in
    Expr.eabs (Expr.bind new_vars (translate_expr ctx body)) pos tys m
  | ELocation (DesugaredScopeVar { name; state = None }) ->
    Expr.elocation
      (ScopelangScopeVar
         {
           name =
             (match
                ScopeVar.Map.find (Mark.remove name) ctx.scope_var_mapping
              with
             | WholeVar new_s_var -> Mark.copy name new_s_var
             | States _ -> failwith "should not happen");
         })
      m
  | ELocation (DesugaredScopeVar { name; state = Some state }) ->
    Expr.elocation
      (ScopelangScopeVar
         {
           name =
             (match
                ScopeVar.Map.find (Mark.remove name) ctx.scope_var_mapping
              with
             | WholeVar _ -> failwith "should not happen"
             | States states -> Mark.copy name (List.assoc state states));
         })
      m
  | ELocation (ToplevelVar v) -> Expr.elocation (ToplevelVar v) m
  | EDStructAmend { name_opt = Some name; e; fields } ->
    let str_fields = StructName.Map.find name ctx.decl_ctx.ctx_structs in
    let fields =
      Ident.Map.fold
        (fun id e ->
          match
            StructName.Map.find name
              (Ident.Map.find id ctx.decl_ctx.ctx_struct_fields)
          with
          | field -> StructField.Map.add field (translate_expr ctx e)
          | exception (Ident.Map.Not_found _ | StructName.Map.Not_found _) ->
            Message.error ~pos:(Expr.pos e)
              ~fmt_pos:
                [
                  ( (fun ppf ->
                      Format.fprintf ppf "Declaration of structure %a"
                        StructName.format name),
                    Mark.get (StructName.get_info name) );
                ]
              "Field %a@ does@ not@ belong@ to@ structure@ %a" Ident.format id
              StructName.format name)
        fields StructField.Map.empty
    in
    if StructField.Map.cardinal fields = StructField.Map.cardinal str_fields
    then
      Message.warning ~pos:(Expr.mark_pos m)
        "All fields of@ %a@ are@ rewritten@ in@ this@ replacement."
        StructName.format name;
    let orig_var = Var.make "orig" in
    let orig_e = Expr.evar orig_var (Mark.get e) in
    let fields =
      StructField.Map.mapi
        (fun field _ty ->
          match StructField.Map.find_opt field fields with
          | Some e -> e
          | None -> Expr.estructaccess ~name ~field ~e:orig_e m)
        str_fields
    in
    Expr.make_let_in (Mark.ghost orig_var)
      (TStruct name, Expr.pos e)
      (translate_expr ctx e)
      (Expr.estruct ~name ~fields m)
      (Expr.mark_pos m)
  | EDStructAmend { name_opt = None; _ } | EDStructAccess _ ->
    assert false (* This shouldn't appear in desugared after disambiguation *)
  | EScopeCall { scope; args } ->
    Expr.escopecall ~scope
      ~args:
        (ScopeVar.Map.fold
           (fun v (p, e) args' ->
             let v' =
               match ScopeVar.Map.find v ctx.scope_var_mapping with
               | WholeVar v' -> v'
               | States ((_, v') :: _) ->
                 (* When there are multiple states, the input is always the
                    first one *)
                 v'
               | States [] -> assert false
             in
             let e' = translate_expr ctx e in
             let m = Expr.no_attrs (Mark.get e) in
             let e' =
               match ScopeVar.Map.find_opt v ctx.reentrant_vars with
               | Some (TArrow (targs, _), _) ->
                 (* Functions are treated specially: the default only applies to
                    their return type *)
                 let arg = Var.make "arg" in
                 let pos = Expr.mark_pos m in
                 Expr.make_ghost_abs [arg]
                   (Expr.edefault ~excepts:[] ~just:(Expr.elit (LBool true) m)
                      ~cons:
                        (Expr.epuredefault
                           (Expr.make_app e' [Expr.evar arg m] targs pos)
                           m)
                      m)
                   targs pos
               | Some _ -> Expr.epuredefault e' m
               | None -> e'
             in
             ScopeVar.Map.add v' (p, e') args')
           args ScopeVar.Map.empty)
      m
  | EApp { f; tys; args } -> (
    (* Detuplification of function arguments *)
    let pos = Expr.pos f in
    let f = translate_expr ctx f in
    match args, tys with
    | [arg], [_] -> Expr.eapp ~f ~tys m ~args:[translate_expr ctx arg]
    | [(ETuple args, _)], _ ->
      assert (List.length args = List.length tys);
      Expr.eapp ~f ~tys m ~args:(List.map (translate_expr ctx) args)
    | [((EVar _, _) as arg)], ts ->
      let size = List.length ts in
      let args =
        let e = translate_expr ctx arg in
        List.init size (fun index -> Expr.etupleaccess ~e ~size ~index m)
      in
      Expr.eapp ~f ~tys m ~args
    | [arg], ts ->
      let size = List.length ts in
      let v = Var.make "args" in
      let e = Expr.evar v (Mark.get arg) in
      let args =
        List.init size (fun index -> Expr.etupleaccess ~e ~size ~index m)
      in
      Expr.make_let_in (Mark.ghost v) (TTuple ts, pos) (translate_expr ctx arg)
        (Expr.eapp ~f ~tys m ~args)
        pos
    | args, tys ->
      assert (List.length args = List.length tys);
      Expr.eapp ~f ~tys m ~args:(List.map (translate_expr ctx) args))
  | EAppOp { op; tys; args } ->
    let args = List.map (translate_expr ctx) args in
    Operator.kind_dispatch op
      ~monomorphic:(fun op -> Expr.eappop ~op ~tys ~args m)
      ~polymorphic:(fun op -> Expr.eappop ~op ~tys ~args m)
      ~overloaded:(fun op ->
        match Operator.resolve_overload op tys with
        | op, `Straight -> Expr.eappop ~op ~tys ~args m
        | op, `Reversed ->
          Expr.eappop ~op ~tys:(List.rev tys) ~args:(List.rev args) m)
  | ( EStruct _ | EStructAccess _ | ETuple _ | ETupleAccess _ | EInj _
    | EMatch _ | ELit _ | EDefault _ | EPureDefault _ | EFatalError _
    | EIfThenElse _ | EArray _ | EEmpty | EErrorOnEmpty _ | EPos _ ) as e ->
    Expr.map ~f:(translate_expr ctx) (e, m)

(** {1 Rule tree construction} *)

(** Intermediate representation for the exception tree of rules for a particular
    scope definition. *)
type rule_tree =
  | Leaf of D.rule list
      (** Rules defining a base case piecewise. List is non-empty. *)
  | Node of rule_tree list * D.rule list
      (** [Node (exceptions, base_case)] is a list of exceptions to a non-empty
          list of rules defining a base case piecewise. *)

(** Transforms a flat list of rules into a tree, taking into account the
    priorities declared between rules *)
let def_to_exception_graph
    (def_info : D.ScopeDef.t)
    (def : D.rule RuleName.Map.t) :
    Desugared.Dependency.ExceptionsDependencies.t =
  let exc_graph = Desugared.Dependency.build_exceptions_graph def def_info in
  Desugared.Dependency.check_for_exception_cycle def exc_graph;
  exc_graph

let rule_to_exception_graph (scope : D.scope) = function
  | Desugared.Dependency.Vertex.Var (var, None)
    when ScopeVar.Map.mem var scope.scope_sub_scopes ->
    (* Before calling the sub_scope, we need to include all the re-definitions
       of subscope parameters*)
    D.ScopeDef.Map.fold
      (fun ((sscope, kind) as def_key) scope_def exc_graphs ->
        match kind with
        | D.ScopeDef.Var _ -> exc_graphs
        | D.ScopeDef.SubScopeInput _
          when (not (ScopeVar.equal var (Mark.remove sscope)))
               || Mark.remove scope_def.D.scope_def_io.io_input = NoInput
                  && RuleName.Map.is_empty scope_def.scope_def_rules ->
          (* We exclude subscope variables that have 0 re-definitions and are
             not visible in the input of the subscope *)
          exc_graphs
        | D.ScopeDef.SubScopeInput { var_within_origin_scope; _ } ->
          (* This definition redefines a variable of the correct subscope. But
             we have to check that this redefinition is allowed with respect to
             the io parameters of that subscope variable. *)
          let def = scope_def.D.scope_def_rules in
          let is_cond = scope_def.scope_def_is_condition in
          let () =
            match Mark.remove scope_def.D.scope_def_io.io_input with
            | NoInput ->
              Message.error
                ~extra_pos:
                  (( "Incriminated subscope:",
                     Mark.get (ScopeVar.get_info (Mark.remove sscope)) )
                  :: ( "Incriminated variable:",
                       Mark.get (ScopeVar.get_info var_within_origin_scope) )
                  :: List.map
                       (fun rule ->
                         ( "Incriminated subscope variable definition:",
                           Mark.get (RuleName.get_info rule) ))
                       (RuleName.Map.keys def))
                "%a" Format.pp_print_text
                "Invalid assignment to a subscope variable that is not tagged \
                 as input or context."
            | OnlyInput when RuleName.Map.is_empty def && not is_cond ->
              (* If the subscope variable is tagged as input, then it shall be
                 defined. *)
              Message.error
                ~extra_pos:
                  [
                    ( "Incriminated subscope:",
                      Mark.get (ScopeVar.get_info (Mark.remove sscope)) );
                    "Incriminated variable:", Mark.get sscope;
                  ]
                "%a" Format.pp_print_text
                "This subscope variable is a mandatory input but no definition \
                 was provided."
            | _ -> ()
          in
          let new_exc_graph = def_to_exception_graph def_key def in
          D.ScopeDef.Map.add def_key new_exc_graph exc_graphs)
      scope.scope_defs D.ScopeDef.Map.empty
  | Desugared.Dependency.Vertex.Var (var, state) -> (
    let pos = Mark.get (ScopeVar.get_info var) in
    let scope_def =
      D.ScopeDef.Map.find ((var, pos), D.ScopeDef.Var state) scope.scope_defs
    in
    let var_def = scope_def.D.scope_def_rules in
    match Mark.remove scope_def.D.scope_def_io.io_input with
    | OnlyInput when not (RuleName.Map.is_empty var_def) ->
      (* If the variable is tagged as input, then it shall not be redefined. *)
      Message.error
        ~extra_pos:
          (("Incriminated variable:", Mark.get (ScopeVar.get_info var))
          :: List.map
               (fun rule ->
                 ( "Incriminated variable definition:",
                   Mark.get (RuleName.get_info rule) ))
               (RuleName.Map.keys var_def))
        "%a" Format.pp_print_text
        "There cannot be a definition for a scope variable tagged as input."
    | OnlyInput -> D.ScopeDef.Map.empty
    (* we do not provide any definition for an input-only variable *)
    | _ ->
      D.ScopeDef.Map.singleton
        ((var, pos), D.ScopeDef.Var state)
        (def_to_exception_graph ((var, pos), D.ScopeDef.Var state) var_def))
  | Assertion _ -> D.ScopeDef.Map.empty (* no exceptions for assertions *)

let scope_to_exception_graphs (scope : D.scope) :
    Desugared.Dependency.ExceptionsDependencies.t D.ScopeDef.Map.t =
  let scope_dependencies =
    Desugared.Dependency.build_scope_dependencies scope
  in
  Desugared.Dependency.check_for_cycle scope scope_dependencies;
  let scope_ordering =
    Desugared.Dependency.correct_computation_ordering scope_dependencies
  in
  List.fold_left
    (fun exceptions_graphs scope_def_key ->
      let new_exceptions_graphs = rule_to_exception_graph scope scope_def_key in
      D.ScopeDef.Map.disjoint_union new_exceptions_graphs exceptions_graphs)
    D.ScopeDef.Map.empty scope_ordering

let build_exceptions_graph (pgrm : D.program) :
    Desugared.Dependency.ExceptionsDependencies.t D.ScopeDef.Map.t =
  let g =
    ScopeName.Map.fold
      (fun _ scope exceptions_graph ->
        let new_exceptions_graphs = scope_to_exception_graphs scope in
        D.ScopeDef.Map.disjoint_union new_exceptions_graphs exceptions_graph)
      pgrm.program_root.module_scopes D.ScopeDef.Map.empty
  in
  let g =
    if Global.options.whole_program then
      ModuleName.Map.fold
        (fun _ modul g ->
          ScopeName.Map.fold
            (fun _ scope exceptions_graph ->
              let new_exceptions_graphs = scope_to_exception_graphs scope in
              D.ScopeDef.Map.disjoint_union new_exceptions_graphs
                exceptions_graph)
            modul.D.module_scopes g)
        pgrm.program_modules g
    else g
  in
  g

(** Transforms a flat list of rules into a tree, taking into account the
    priorities declared between rules *)
let def_map_to_tree
    (def : D.rule RuleName.Map.t)
    (exc_graph : Desugared.Dependency.ExceptionsDependencies.t) : rule_tree list
    =
  (* we start by the base cases: they are the vertices which have no
     successors *)
  let base_cases =
    Desugared.Dependency.ExceptionsDependencies.fold_vertex
      (fun v base_cases ->
        if
          Desugared.Dependency.ExceptionsDependencies.out_degree exc_graph v = 0
        then v :: base_cases
        else base_cases)
      exc_graph []
  in
  let rec build_tree (base_cases : Desugared.Dependency.ExceptionVertex.t) :
      rule_tree =
    let exceptions =
      Desugared.Dependency.ExceptionsDependencies.pred exc_graph base_cases
    in
    let base_case_as_rule_list =
      List.map
        (fun r -> RuleName.Map.find r def)
        (RuleName.Map.keys base_cases.rules)
    in
    match exceptions with
    | [] -> Leaf base_case_as_rule_list
    | _ -> Node (List.map build_tree exceptions, base_case_as_rule_list)
  in
  List.map build_tree base_cases

(** From the {!type: rule_tree}, builds an {!constructor: Dcalc.EDefault}
    expression in the scope language. The [~toplevel] parameter is used to know
    when to place the toplevel binding in the case of functions. *)
let rec rule_tree_to_expr
    ~(toplevel : bool)
    ~(is_reentrant_var : bool)
    ~(subscope : bool)
    (ctx : ctx)
    (def_pos : Pos.t)
    (params : D.expr Var.t list option)
    (tree : rule_tree) : untyped Ast.expr boxed =
  let emark = Expr.no_attrs (Untyped { pos = def_pos }) in
  let exceptions, base_rules =
    match tree with Leaf r -> [], r | Node (exceptions, r) -> exceptions, r
  in
  (* because each rule has its own variables parameters and we want to convert
     the whole rule tree into a function, we need to perform some alpha-renaming
     of all the expressions *)
  let substitute_parameter (e : D.expr boxed) (rule : D.rule) : D.expr boxed =
    match params, rule.D.rule_parameter with
    | Some new_params, Some (old_params_with_types, _) ->
      let old_params, _ = List.split old_params_with_types in
      let old_params = Array.of_list (List.map Mark.remove old_params) in
      let new_params = Array.of_list new_params in
      let binder = Bindlib.bind_mvar old_params (Mark.remove e) in
      Mark.add (Mark.get e)
      @@ Bindlib.box_apply2
           (fun binder new_param -> Bindlib.msubst binder new_param)
           binder
           (new_params |> Array.map Bindlib.box_var |> Bindlib.box_array)
    | None, None -> e
    | _ -> assert false
    (* should not happen *)
  in
  let ctx =
    match params with
    | None -> ctx
    | Some new_params ->
      ListLabels.fold_left new_params ~init:ctx ~f:(fun ctx new_param ->
          match Var.Map.find_opt new_param ctx.var_mapping with
          | None ->
            let new_param_scope = Var.make (Bindlib.name_of new_param) in
            {
              ctx with
              var_mapping =
                Var.Map.add new_param new_param_scope ctx.var_mapping;
            }
          | Some _ ->
            (* We only create a mapping if none exists because
               [rule_tree_to_expr] is called recursively on the exceptions of
               the tree and we don't want to create a new Scopelang variable for
               the parameter at each tree level. *)
            ctx)
  in
  let base_just_list =
    List.map (fun rule -> substitute_parameter rule.D.rule_just rule) base_rules
  in
  let base_cons_list =
    List.map (fun rule -> substitute_parameter rule.D.rule_cons rule) base_rules
  in
  let translate_and_unbox_list (list : D.expr boxed list) :
      untyped Ast.expr boxed list =
    List.map
      (fun e ->
        (* There are two levels of boxing here, the outermost is introduced by
           the [translate_expr] function for which all of the bindings should
           have been closed by now, so we can safely unbox. *)
        translate_expr ctx (Expr.unbox e))
      list
  in
  let default_containing_base_cases =
    Expr.edefault
      ~excepts:
        (List.fold_right2
           (fun base_just base_cons acc ->
             match Expr.unbox base_just with
             | ELit (LBool false), _ -> acc
             | _ ->
               let cons = Expr.make_puredefault base_cons in
               Expr.edefault
                 ~excepts:[]
                   (* Here we insert the logging command that records when a
                      decision is taken for the value of a variable. *)
                 ~just:(tag_with_log_entry base_just PosRecordIfTrueBool [])
                 ~cons
                 (Expr.no_attrs (Mark.get cons))
               :: acc)
           (translate_and_unbox_list base_just_list)
           (translate_and_unbox_list base_cons_list)
           [])
      ~just:(Expr.elit (LBool false) emark)
      ~cons:(Expr.eempty emark) emark
  in
  let exceptions =
    List.map
      (rule_tree_to_expr ~toplevel:false ~is_reentrant_var ~subscope ctx def_pos
         params)
      exceptions
  in
  let default =
    if exceptions = [] then default_containing_base_cases
    else
      Expr.edefault ~excepts:exceptions
        ~just:(Expr.elit (LBool true) emark)
        ~cons:
          (* if toplevel then Expr.eerroronempty default_containing_base_cases emark
           * else *)
          default_containing_base_cases emark
  in
  let default =
    if toplevel && not (subscope && is_reentrant_var) then
      Expr.eerroronempty default emark
    else default
  in
  match params, (List.hd base_rules).D.rule_parameter with
  | None, None -> default
  | Some new_params, Some (ls, _) ->
    let _, tys = List.split ls in
    if toplevel then
      (* When we're creating a function from multiple defaults, we must check
         that the result returned by the function is not empty, unless we're
         dealing with a context variable which is reentrant (either in the
         caller or callee). In this case the ErrorOnEmpty will be added later in
         the scopelang->dcalc translation. *)
      Expr.make_ghost_abs
        (new_params |> List.map (fun x -> Var.Map.find x ctx.var_mapping))
        default tys def_pos
    else default
  | _ -> (* should not happen *) assert false

(** {1 AST translation} *)

(** Translates a definition inside a scope, the resulting expression should be
    an {!constructor: Dcalc.EDefault} *)
let translate_def
    ~(is_cond : bool)
    ~(is_subscope_var : bool)
    (ctx : ctx)
    (def_info : D.ScopeDef.t)
    (def : D.rule RuleName.Map.t)
    (params : (Uid.MarkedString.info * typ) list Mark.pos option)
    (typ : typ)
    (io : D.io)
    (exc_graph : Desugared.Dependency.ExceptionsDependencies.t) :
    untyped Ast.expr boxed =
  (* Here, we have to transform this list of rules into a default tree. *)
  let top_list = def_map_to_tree def exc_graph in
  let is_input =
    match Mark.remove io.D.io_input with OnlyInput -> true | _ -> false
  in
  let is_reentrant =
    match Mark.remove io.D.io_input with Reentrant -> true | _ -> false
  in
  let top_value : D.rule option =
    if is_cond && ((not is_subscope_var) || (is_subscope_var && is_input)) then
      (* We add the bottom [false] value for conditions, only for the scope
         where the condition is declared. Except when the variable is an input,
         where we want the [false] to be added at each caller parent scope. *)
      Some (D.always_false_rule (D.ScopeDef.get_position def_info) params)
    else None
  in
  if
    RuleName.Map.cardinal def = 0
    && is_subscope_var
    (* Here we have a special case for the empty definitions. Indeed, we could
       use the code for the regular case below that would create a convoluted
       default always returning empty error, and this would be correct. But it
       gets more complicated with functions. Indeed, if we create an empty
       definition for a subscope argument whose type is a function, we get
       something like [fun () -> (fun real_param -> < ... >)] that is passed as
       an argument to the subscope. The sub-scope de-thunks but the de-thunking
       does not return empty error, signalling there is not reentrant variable,
       because functions are values! So the subscope does not see that there is
       not reentrant variable and does not pick its internal definition instead.
       See [test/test_scope/subscope_function_arg_not_defined.catala_en] for a
       test case exercising that subtlety.

       To avoid this complication we special case here and put an empty error
       for all subscope variables that are not defined. It covers the subtlety
       with functions described above but also conditions with the false default
       value. *)
    && not (is_cond && is_input)
    (* However, this special case suffers from an exception: when a condition is
       defined as an OnlyInput to a subscope, since the [false] default value
       will not be provided by the calee scope, it has to be placed in the
       caller. *)
  then
    let m = Untyped { pos = D.ScopeDef.get_position def_info } in
    let empty = Expr.eempty m in
    match params with
    | Some (ps, _) ->
      let labels, tys = List.split ps in
      Expr.make_abs
        (List.map (fun lbl -> Mark.map Var.make lbl) labels)
        empty tys (Expr.mark_pos m)
    | _ -> empty
  else
    rule_tree_to_expr ~toplevel:true ~is_reentrant_var:is_reentrant
      ~subscope:is_subscope_var ctx
      (D.ScopeDef.get_position def_info)
      (Option.map
         (fun (ps, _) ->
           (List.map (fun (lbl, _) -> Var.make (Mark.remove lbl))) ps)
         params)
      (match top_list, top_value with
      | [], None ->
        (* In this case, there are no rules to define the expression and no
           default value so we put an empty rule. *)
        Leaf [D.empty_rule (Mark.get typ) params]
      | [], Some top_value ->
        (* In this case, there are no rules to define the expression but a
           default value so we put it. *)
        Leaf [top_value]
      | _, Some top_value ->
        (* When there are rules + a default value, we put the rules as
           exceptions to the default value *)
        Node (top_list, [top_value])
      | [top_tree], None -> top_tree
      | _, None -> Node (top_list, [D.empty_rule (Mark.get typ) params]))

let translate_rule
    ctx
    (scope : D.scope)
    (exc_graphs :
      Desugared.Dependency.ExceptionsDependencies.t D.ScopeDef.Map.t) = function
  | Desugared.Dependency.Vertex.Var (var, state) -> (
    let decl_pos = Mark.get (ScopeVar.get_info var) in
    let scope_def =
      D.ScopeDef.Map.find
        ((var, Pos.void), D.ScopeDef.Var state)
        scope.scope_defs
    in
    let all_def_pos =
      List.map
        (fun r -> Mark.get (RuleName.get_info r))
        (RuleName.Map.keys scope_def.scope_def_rules)
    in
    match ScopeVar.Map.find_opt var scope.scope_sub_scopes with
    | None -> (
      let var_def = scope_def.D.scope_def_rules in
      let var_params = scope_def.D.scope_def_parameters in
      let var_typ = scope_def.D.scope_def_typ in
      let is_cond = scope_def.D.scope_def_is_condition in
      match Mark.remove scope_def.D.scope_def_io.io_input with
      | OnlyInput when not (RuleName.Map.is_empty var_def) ->
        assert false (* error already raised *)
      | OnlyInput -> []
      (* we do not provide any definition for an input-only variable *)
      | _ ->
        let scope_def_key = (var, decl_pos), D.ScopeDef.Var state in
        let expr_def =
          translate_def ctx scope_def_key var_def var_params var_typ
            scope_def.D.scope_def_io
            (D.ScopeDef.Map.find scope_def_key exc_graphs)
            ~is_cond ~is_subscope_var:false
        in
        let scope_var =
          match ScopeVar.Map.find var ctx.scope_var_mapping, state with
          | WholeVar v, None -> v
          | States states, Some state -> List.assoc state states
          | _ -> assert false
        in
        [
          Ast.ScopeVarDefinition
            {
              var = Mark.add all_def_pos scope_var;
              typ = var_typ;
              io = scope_def.D.scope_def_io;
              e = Expr.unbox expr_def;
            };
        ])
    | Some subscope ->
      (* Before calling the subscope, we need to include all the re-definitions
         of subscope parameters *)
      let subscope_params =
        D.ScopeDef.Map.fold
          (fun def_key scope_def acc ->
            match def_key with
            | _, D.ScopeDef.Var _ -> acc
            | (v, _), D.ScopeDef.SubScopeInput _
              when (not (ScopeVar.equal var v))
                   || Mark.remove scope_def.D.scope_def_io.io_input = NoInput
                      && RuleName.Map.is_empty scope_def.scope_def_rules ->
              acc
            | v, D.ScopeDef.SubScopeInput { var_within_origin_scope; _ } ->
              let pos = Mark.get v in
              let def = scope_def.D.scope_def_rules in
              let def_typ = scope_def.scope_def_typ in
              let is_cond = scope_def.scope_def_is_condition in
              assert (
                (* an error should have been already raised *)
                match scope_def.D.scope_def_io.io_input with
                | NoInput, _ -> false
                | OnlyInput, _ -> is_cond || not (RuleName.Map.is_empty def)
                | _ -> true);
              let var_within_origin_scope =
                match
                  ScopeVar.Map.find var_within_origin_scope
                    ctx.scope_var_mapping
                with
                | WholeVar v -> v
                | States ((_, v) :: _) -> v
                | States [] -> assert false
              in
              let def_var =
                Var.make
                  (String.concat "."
                     [
                       Mark.remove (ScopeVar.get_info (Mark.remove v));
                       ScopeVar.to_string var_within_origin_scope;
                     ])
              in
              let typ =
                Scope.input_type def_typ scope_def.D.scope_def_io.D.io_input
              in
              let expr_def =
                translate_def ctx def_key def scope_def.D.scope_def_parameters
                  def_typ scope_def.D.scope_def_io
                  (D.ScopeDef.Map.find def_key exc_graphs)
                  ~is_cond ~is_subscope_var:true
              in
              ScopeVar.Map.add var_within_origin_scope
                (def_var, pos, typ, expr_def)
                acc)
          scope.scope_defs ScopeVar.Map.empty
      in
      let subscope_param_map =
        ScopeVar.Map.map (fun (_, p, _, expr) -> p, expr) subscope_params
      in
      let subscope_expr =
        Expr.escopecall ~scope:subscope ~args:subscope_param_map
          (Untyped { pos = decl_pos })
      in
      assert (RuleName.Map.is_empty scope_def.D.scope_def_rules);
      (* The subscope will be defined by its inputs, it's not supposed to have
         direct rules yet *)
      let scope_info = ScopeName.Map.find subscope ctx.decl_ctx.ctx_scopes in
      let subscope_var_dcalc =
        match ScopeVar.Map.find var ctx.scope_var_mapping with
        | WholeVar v -> v
        | _ -> assert false
      in
      let subscope_def =
        Ast.ScopeVarDefinition
          {
            var = Mark.add all_def_pos subscope_var_dcalc;
            typ =
              ( TStruct scope_info.out_struct_name,
                Mark.get (ScopeVar.get_info var) );
            io = scope_def.D.scope_def_io;
            e = Expr.unbox_closed subscope_expr;
          }
      in
      [subscope_def])
  | Assertion a_name ->
    let assertion_expr =
      D.AssertionName.Map.find a_name scope.scope_assertions
    in
    (* we unbox here because assertions do not have free variables (at this
       point Bindlib variables are only for function parameters)*)
    let assertion_expr = translate_expr ctx (Expr.unbox assertion_expr) in
    [Ast.Assertion (Expr.unbox assertion_expr)]

let translate_scope_interface ctx scope =
  let get_svar scope_def =
    let svar_in_ty =
      Scope.input_type scope_def.D.scope_def_typ
        scope_def.D.scope_def_io.io_input
    in
    {
      Ast.svar_in_ty;
      svar_out_ty = scope_def.D.scope_def_typ;
      svar_io = scope_def.scope_def_io;
    }
  in
  let scope_sig =
    (* Add the definitions of standard scope vars *)
    ScopeVar.Map.fold
      (fun var (states : D.var_or_states) acc ->
        match states with
        | WholeVar ->
          let scope_def =
            D.ScopeDef.Map.find
              ((var, Pos.void), D.ScopeDef.Var None)
              scope.D.scope_defs
          in
          ScopeVar.Map.add
            (match ScopeVar.Map.find var ctx.scope_var_mapping with
            | WholeVar v -> v
            | States _ -> assert false)
            (get_svar scope_def) acc
        | States states ->
          (* What happens in the case of variables with multiple states is
             interesting. We need to create as many Var entries in the scope
             signature as there are states. *)
          List.fold_left
            (fun acc (state : StateName.t) ->
              let scope_def =
                D.ScopeDef.Map.find
                  ((var, Pos.void), D.ScopeDef.Var (Some state))
                  scope.D.scope_defs
              in
              ScopeVar.Map.add
                (match ScopeVar.Map.find var ctx.scope_var_mapping with
                | WholeVar _ -> assert false
                | States states' -> List.assoc state states')
                (get_svar scope_def) acc)
            acc states)
      scope.scope_vars ScopeVar.Map.empty
  in
  let scope_sig =
    (* Add the definition of vars corresponding to subscope calls, and their
       parameters (subscope vars) *)
    ScopeVar.Map.fold
      (fun var _scope_name acc ->
        let scope_def =
          D.ScopeDef.Map.find
            ((var, Pos.void), D.ScopeDef.Var None)
            scope.D.scope_defs
        in
        ScopeVar.Map.add
          (match ScopeVar.Map.find var ctx.scope_var_mapping with
          | WholeVar v -> v
          | States _ -> assert false)
          (get_svar scope_def) acc)
      scope.D.scope_sub_scopes scope_sig
  in
  let pos = Mark.get (ScopeName.get_info scope.scope_uid) in
  Mark.add pos
    {
      Ast.scope_decl_name = scope.scope_uid;
      scope_decl_rules = [];
      scope_sig;
      scope_options = scope.scope_options;
      scope_visibility = scope.scope_visibility;
    }

let translate_scope
    (ctx : ctx)
    (exc_graphs :
      Desugared.Dependency.ExceptionsDependencies.t D.ScopeDef.Map.t)
    (scope : D.scope) : untyped Ast.scope_decl Mark.pos =
  let scope_dependencies =
    Desugared.Dependency.build_scope_dependencies scope
  in
  Desugared.Dependency.check_for_cycle scope scope_dependencies;
  let scope_ordering =
    Desugared.Dependency.correct_computation_ordering scope_dependencies
  in
  let scope_decl_rules =
    List.fold_left
      (fun scope_decl_rules scope_def_key ->
        let new_rules = translate_rule ctx scope exc_graphs scope_def_key in
        scope_decl_rules @ new_rules)
      [] scope_ordering
  in
  Mark.map
    (fun s -> { s with Ast.scope_decl_rules })
    (translate_scope_interface ctx scope)

(** {1 API} *)

let translate_program
    (desugared : D.program)
    (exc_graphs :
      Desugared.Dependency.ExceptionsDependencies.t D.ScopeDef.Map.t) :
    untyped Ast.program =
  (* First we give mappings to all the locations between Desugared and This
     involves creating a new Scopelang scope variable for every state of a
     Desugared variable. *)
  let ctx =
    let ctx =
      {
        scope_var_mapping = ScopeVar.Map.empty;
        var_mapping = Var.Map.empty;
        reentrant_vars = ScopeVar.Map.empty;
        decl_ctx = desugared.program_ctx;
      }
    in
    let add_scope_mappings modul ctx =
      ScopeName.Map.fold
        (fun _ scdef ctx ->
          let ctx =
            (* Add normal scope vars to the env *)
            ScopeVar.Map.fold
              (fun scope_var (states : D.var_or_states) ctx ->
                let var_name, var_pos = ScopeVar.get_info scope_var in
                let new_var =
                  match states with
                  | D.WholeVar -> WholeVar (ScopeVar.fresh (var_name, var_pos))
                  | States states ->
                    let var_prefix = var_name ^ "#" in
                    let state_var state =
                      ScopeVar.fresh
                        (Mark.map (( ^ ) var_prefix) (StateName.get_info state))
                    in
                    States
                      (List.map (fun state -> state, state_var state) states)
                in
                let reentrant =
                  let state =
                    match states with
                    | D.WholeVar -> None
                    | States (s :: _) -> Some s
                    | States [] -> assert false
                  in
                  match
                    D.ScopeDef.Map.find_opt
                      ((scope_var, Pos.void), Var state)
                      scdef.D.scope_defs
                  with
                  | Some
                      {
                        scope_def_io = { io_input = Runtime.Reentrant, _; _ };
                        scope_def_typ;
                        _;
                      } ->
                    Some scope_def_typ
                  | _ -> None
                in
                {
                  ctx with
                  scope_var_mapping =
                    ScopeVar.Map.add scope_var new_var ctx.scope_var_mapping;
                  reentrant_vars =
                    Option.fold reentrant
                      ~some:(fun ty ->
                        ScopeVar.Map.add scope_var ty ctx.reentrant_vars)
                      ~none:ctx.reentrant_vars;
                })
              scdef.D.scope_vars ctx
          in
          let ctx =
            (* Add scope vars pointing to subscope executions to the env (their
               definitions are introduced during the processing of the rules
               above) *)
            ScopeVar.Map.fold
              (fun var _ ctx ->
                let var_name, var_pos = ScopeVar.get_info var in
                let scope_var_mapping =
                  let new_var = WholeVar (ScopeVar.fresh (var_name, var_pos)) in
                  ScopeVar.Map.add var new_var ctx.scope_var_mapping
                in
                { ctx with scope_var_mapping })
              scdef.D.scope_sub_scopes ctx
          in
          ctx)
        modul.D.module_scopes ctx
    in
    (* Todo: since we rename all scope vars at this point, it would be better to
       have different types for Desugared.ScopeVar.t and Scopelang.ScopeVar.t *)
    ModuleName.Map.fold
      (fun _ m ctx -> add_scope_mappings m ctx)
      desugared.D.program_modules
      (add_scope_mappings desugared.D.program_root ctx)
  in
  let decl_ctx =
    let ctx_scopes =
      ScopeName.Map.map
        (fun out_str ->
          let out_struct_fields =
            ScopeVar.Map.fold
              (fun var fld out_map ->
                let var' =
                  match ScopeVar.Map.find var ctx.scope_var_mapping with
                  | WholeVar v -> v
                  | States l -> snd (List.hd (List.rev l))
                in
                ScopeVar.Map.add var' fld out_map)
              out_str.out_struct_fields ScopeVar.Map.empty
          in
          { out_str with out_struct_fields })
        desugared.program_ctx.ctx_scopes
    in
    { desugared.program_ctx with ctx_scopes }
  in
  let ctx = { ctx with decl_ctx } in
  let program_modules =
    ModuleName.Map.map
      (fun m ->
        ScopeName.Map.map
          (fun scope ->
            if Global.options.whole_program then
              translate_scope ctx exc_graphs scope
            else translate_scope_interface ctx scope)
          m.D.module_scopes)
      desugared.D.program_modules
  in
  let program_topdefs =
    let translate_topdef modul =
      TopdefName.Map.filter_map
        (fun id -> function
          | {
              D.topdef_expr = Some e;
              topdef_type = ty;
              topdef_visibility = vis;
              topdef_external = ext;
            } ->
            Some (Expr.unbox (translate_expr ctx e), ty, vis, ext)
          | { D.topdef_expr = None; topdef_external = true; _ } -> None
          | {
              D.topdef_expr = None;
              topdef_type = _, pos;
              topdef_external = false;
              _;
            } ->
            Message.error ~pos "No definition found for %a" TopdefName.format id)
        modul.D.module_topdefs
    in
    let program_topdefs = translate_topdef desugared.program_root in
    let program_topdefs =
      if Global.options.whole_program then
        ModuleName.Map.fold
          (fun _mn modul topdefs ->
            TopdefName.Map.disjoint_union (translate_topdef modul) topdefs)
          desugared.program_modules program_topdefs
      else program_topdefs
    in
    program_topdefs
  in
  let program_scopes =
    let translate_scope modul =
      ScopeName.Map.map (translate_scope ctx exc_graphs) modul.D.module_scopes
    in
    let program_scopes = translate_scope desugared.D.program_root in
    if Global.options.whole_program then
      ModuleName.Map.fold
        (fun _mn modul scopes ->
          ScopeName.Map.disjoint_union (translate_scope modul) scopes)
        desugared.program_modules program_scopes
    else program_scopes
  in
  {
    Ast.program_module_name = desugared.D.program_module_name;
    program_topdefs;
    program_scopes;
    program_ctx = ctx.decl_ctx;
    program_modules;
    program_lang = desugared.program_lang;
  }
