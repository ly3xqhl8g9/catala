(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2023 Inria, contributor:
   Louis Gesbert <louis.gesbert@inria.fr>.

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

open Catala_utils
open Shared_ast

module Style = struct
  type color = Graph.Graphviz.color

  type elt = {
    fill : color;
    border : color;
    stroke : int; (* in px *)
    text : color;
  }

  type theme = {
    page_background : Graph.Graphviz.color;
    arrows : Graph.Graphviz.color;
    input : elt;
    middle : elt;
    constant : elt;
    condition : elt;
    output : elt;
  }

  let dark =
    {
      page_background = 0x0;
      arrows = 0x606060;
      input =
        { fill = 0x252526; border = 0xBC3FBC; stroke = 2; text = 0xFFFFFF };
      middle =
        { fill = 0x252526; border = 0x0097FB; stroke = 2; text = 0xFFFFFF };
      constant =
        { fill = 0x252526; border = 0x40C8AE; stroke = 2; text = 0xFFFFFF };
      condition =
        { fill = 0x252526; border = 0xff7700; stroke = 2; text = 0xFFFFFF };
      output =
        { fill = 0x252526; border = 0xFFFFFF; stroke = 2; text = 0xFFFFFF };
    }

  let light =
    {
      page_background = 0xffffff;
      arrows = 0x0;
      input = { fill = 0xffaa55; border = 0x0; stroke = 1; text = 0x0 };
      middle = { fill = 0xffee99; border = 0x0; stroke = 1; text = 0x0 };
      constant = { fill = 0x99bbff; border = 0x0; stroke = 1; text = 0x0 };
      condition = { fill = 0xffffff; border = 0xff7700; stroke = 2; text = 0x0 };
      output = { fill = 0xffffff; border = 0x1; stroke = 2; text = 0x0 };
    }

  let width pixels =
    let dpi = 96. in
    let pt_per_inch = 72.28 in
    float_of_int pixels /. dpi *. pt_per_inch
end

type flags = {
  with_conditions : bool;
  with_cleanup : bool;
  merge_level : int;
  format : [ `Dot | `Convert of string ];
  theme : Style.theme;
  show : string option;
  output : Global.raw_file option;
  base_src_url : string;
  line_format : string;
  inline_module_usages : bool;
}

(* -- Definition of the lazy interpreter -- *)

let log fmt = Format.ifprintf Format.err_formatter (fmt ^^ "@\n")
let error e = Message.error ~pos:(Expr.pos e)
let noassert = true

module Env = struct
  type t = Env of (expr, elt) Var.Map.t
  and elt = { base : expr * t; mutable reduced : expr * t }
  and expr = (dcalc, annot custom) gexpr
  and annot = { conditions : (expr * t) list }

  let find v (Env t) = Var.Map.find v t

  (* let get_bas v t = let v, env = find v t in v, !env *)
  let add v e e_env (Env t) =
    Env (Var.Map.add v { base = e, e_env; reduced = e, e_env } t)

  let empty = Env Var.Map.empty

  let join (Env t1) (Env t2) =
    Env
      (Var.Map.union
         (fun _ x1 x2 ->
           (* assert (x1 == x2); *)
           Some x2)
         t1 t2)

  let print ppf (Env t) =
    Format.pp_print_list ~pp_sep:Format.pp_print_space
      (fun ppf v -> Print.var_debug ppf v)
      ppf (Var.Map.keys t)
end

type expr = Env.expr
type annot = Env.annot = { conditions : (expr * Env.t) list }

type laziness_level = {
  eval_struct : bool;
      (* if true, evaluate members of structures, tuples, etc. *)
  eval_op : bool;
      (* if false, evaluate the operands but keep e.g. `3 + 4` as is *)
  eval_match : bool;
  eval_default : bool;
  (* if false, stop evaluating as soon as you can discriminate with
     `EEmptyError` *)
  eval_vars : expr Var.t -> bool;
      (* if false, variables are only resolved when they point to another
         unchanged variable *)
}

let value_level =
  {
    eval_struct = false;
    eval_op = true;
    eval_match = true;
    eval_default = true;
    eval_vars = (fun _ -> true);
  }

let add_condition ~condition e =
  Mark.map_mark
    (fun (Custom { pos; custom = { conditions } }) ->
      Custom { pos; custom = { conditions = condition :: conditions } })
    e

let add_conditions ~conditions e =
  Mark.map_mark
    (fun (Custom { pos; custom = { conditions = c } }) ->
      Custom { pos; custom = { conditions = conditions @ c } })
    e

let neg_op = function
  | Op.Xor ->
    Some Op.Eq
    (* Alright, we are cheating here since the type is wider, but the
       transformation preserves the semantics *)
  | Op.Lt_int_int -> Some Op.Gte_int_int
  | Op.Lt_rat_rat -> Some Op.Gte_rat_rat
  | Op.Lt_mon_mon -> Some Op.Gte_mon_mon
  | Op.Lt_dat_dat -> Some Op.Gte_dat_dat
  | Op.Lt_dur_dur -> Some Op.Gte_dur_dur
  | Op.Lte_int_int -> Some Op.Gt_int_int
  | Op.Lte_rat_rat -> Some Op.Gt_rat_rat
  | Op.Lte_mon_mon -> Some Op.Gt_mon_mon
  | Op.Lte_dat_dat -> Some Op.Gt_dat_dat
  | Op.Lte_dur_dur -> Some Op.Gt_dur_dur
  | Op.Gt_int_int -> Some Op.Lte_int_int
  | Op.Gt_rat_rat -> Some Op.Lte_rat_rat
  | Op.Gt_mon_mon -> Some Op.Lte_mon_mon
  | Op.Gt_dat_dat -> Some Op.Lte_dat_dat
  | Op.Gt_dur_dur -> Some Op.Lte_dur_dur
  | Op.Gte_int_int -> Some Op.Lt_int_int
  | Op.Gte_rat_rat -> Some Op.Lt_rat_rat
  | Op.Gte_mon_mon -> Some Op.Lt_mon_mon
  | Op.Gte_dat_dat -> Some Op.Lt_dat_dat
  | Op.Gte_dur_dur -> Some Op.Lt_dur_dur
  | _ -> None

let rec bool_negation pos e =
  match Expr.skip_wrappers e with
  | ELit (LBool true), m -> ELit (LBool false), m
  | ELit (LBool false), m -> ELit (LBool true), m
  | EAppOp { op = Op.Not, _; args = [(e, _)] }, m -> e, m
  | (EAppOp { op = op, opos; tys; args = [e1; e2] }, m) as e -> (
    match op with
    | Op.And ->
      ( EAppOp
          {
            op = Op.Or, opos;
            tys;
            args = [bool_negation pos e1; bool_negation pos e2];
          },
        m )
    | Op.Or ->
      ( EAppOp
          {
            op = Op.And, opos;
            tys;
            args = [bool_negation pos e1; bool_negation pos e2];
          },
        m )
    | op -> (
      match neg_op op with
      | Some op -> EAppOp { op = op, opos; tys; args = [e1; e2] }, m
      | None ->
        ( EAppOp
            {
              op = Op.Not, opos;
              tys = [TLit TBool, Expr.mark_pos m];
              args = [e];
            },
          m )))
  | (_, m) as e ->
    ( EAppOp
        { op = Op.Not, pos; tys = [TLit TBool, Expr.mark_pos m]; args = [e] },
      m )

let rec lazy_eval : decl_ctx -> Env.t -> laziness_level -> expr -> expr * Env.t
    =
 fun ctx env llevel e0 ->
  let eval_to_value ?(eval_default = true) env e =
    lazy_eval ctx env { value_level with eval_default } e
  in
  let is_zero env e =
    let zero = Runtime.integer_of_int 0 in
    let e, _env = eval_to_value env e in
    let condition =
      match Mark.remove e with
      | ELit (LInt i) -> Runtime.o_eq_int_int zero i
      | ELit (LRat r) ->
        Runtime.o_eq_rat_rat (Runtime.decimal_of_integer zero) r
      | ELit (LMoney m) ->
        Runtime.o_eq_mon_mon (Runtime.money_of_cents_integer zero) m
      | ELit (LDuration dt) ->
        Runtime.duration_to_years_months_days dt = (0, 0, 0)
      | _ -> false
    in
    if condition then Some (e, env) else None
  in
  let is_one env e =
    let one = Runtime.integer_of_int 1 in
    let e, env = eval_to_value env e in
    let condition =
      match Mark.remove e with
      | ELit (LInt i) -> Runtime.o_eq_int_int one i
      | ELit (LRat r) -> Runtime.o_eq_rat_rat (Runtime.decimal_of_integer one) r
      | ELit (LMoney m) -> Runtime.o_eq_mon_mon (Runtime.money_of_units_int 1) m
      | ELit (LDuration dt) ->
        Runtime.duration_to_years_months_days dt = (0, 0, 1)
      | _ -> false
    in
    if condition then Some (e, env) else None
  in
  match e0 with
  | EVar v, _ ->
    if (not llevel.eval_default) || not (llevel.eval_vars v) then e0, env
    else
      (* Variables reducing to EEmpty should not propagate to parent EDefault
         (?) *)
      let env_elt =
        try Env.find v env
        with Var.Map.Not_found _ ->
          error e0 "Variable %a undefined [@[<hv>%a@]]" Print.var_debug v
            Env.print env
      in
      let e, env1 = env_elt.reduced in
      let r, env1 = lazy_eval ctx env1 llevel e in
      env_elt.reduced <- r, env1;
      r, Env.join env env1
  | EAppOp { op = op, opos; args; tys }, m -> (
    if not llevel.eval_default then e0, env
    else
      match op with
      | (Op.Map | Op.Filter | Op.Reduce | Op.Fold | Op.Length) as op -> (
        (* when not llevel.eval_op *)
        (* Distribute collection operations to the terms rather than use their
           runtime implementations *)
        let arr = List.hd (List.rev args) in
        (* All these ops have the array as last arg *)
        let aty = List.hd (List.rev tys) in
        match eval_to_value env arr with
        | (EArray elts, _), env ->
          let eapp f e = EApp { f; args = [e]; tys = [] }, m in
          let empty_condition () =
            (* Is the expression [length(arr) = 0] *)
            let pos = Expr.mark_pos m in
            ( EAppOp
                {
                  op = Op.Eq_int_int, opos;
                  tys = [TLit TInt, pos; TLit TInt, pos];
                  args =
                    [
                      ( EAppOp
                          { op = Op.Length, opos; tys = [aty]; args = [arr] },
                        m );
                      ELit (LInt (Runtime.integer_of_int 0)), m;
                    ];
                },
              m )
          in
          let e, env =
            match op, args, elts with
            | (Op.Map | Op.Filter), _, [] ->
              let e = EArray [], m in
              add_condition ~condition:(empty_condition (), env) e, env
            | (Op.Reduce | Op.Fold), [_; dft; _], [] ->
              add_condition ~condition:(empty_condition (), env) dft, env
            | Op.Map, [f; _], elts -> (EArray (List.map (eapp f) elts), m), env
            | Op.Filter, [f; _], elts ->
              let rev_elts, env =
                List.fold_left
                  (fun (elts, env) e ->
                    let cond = eapp f e in
                    match lazy_eval ctx env value_level cond with
                    | (ELit (LBool true), _), _ ->
                      add_condition ~condition:(cond, env) e :: elts, env
                    | (ELit (LBool false), _), _ -> elts, env
                    | _ -> assert false)
                  ([], env) elts
              in
              (EArray (List.rev rev_elts), m), env
            (* Note: no annots for removed terms, even if the result is empty *)
            | Op.Reduce, [f; _; _], elt0 :: elts ->
              let e =
                List.fold_left
                  (fun acc elt -> EApp { f; args = [acc; elt]; tys = [] }, m)
                  elt0 elts
              in
              e, env
            | Op.Fold, [f; base; _], elts ->
              let e =
                List.fold_left
                  (fun acc elt -> EApp { f; args = [acc; elt]; tys = [] }, m)
                  base elts
              in
              e, env
            | Op.Length, [_], elts ->
              (ELit (LInt (Runtime.integer_of_int (List.length elts))), m), env
            | _ -> assert false
          in
          (* We did a transformation (removing the outer operator), but further
             evaluation may be needed to guarantee that [llevel] is reached *)
          lazy_eval ctx env { llevel with eval_match = true } e
        | _ -> (EAppOp { op = op, opos; args; tys }, m), env)
      | _ -> (
        let env, args =
          List.fold_left_map
            (fun env e ->
              let e, env = lazy_eval ctx env llevel e in
              env, e)
            env args
        in
        let are_zeroes = lazy (List.map (fun x -> x, is_zero env x) args) in
        let are_ones = lazy (List.map (fun x -> x, is_one env x) args) in
        match op, are_zeroes, are_ones with
        (* First handle neutral elements: they are removed from the formula, but
           added as conditions *)
        | ( (Op.Mult_int_int | Op.Mult_rat_rat),
            _,
            (lazy
              ( [(x_neutral, Some (neutral, env)); (not_neutral, None)]
              | [(not_neutral, None); (x_neutral, Some (neutral, env))] )) )
        (* Note: we could add [Op.Mult_mon_rat | Op.Mult_dur_int] here, but that
           would require inserting a conversion operator instead *)
        | ( ( Op.Add_dat_dur _ | Op.Add_dur_dur | Op.Add_int_int
            | Op.Add_mon_mon | Op.Add_rat_rat ),
            (lazy
              ( [(x_neutral, Some (neutral, env)); (not_neutral, None)]
              | [(not_neutral, None); (x_neutral, Some (neutral, env))] )),
            _ )
        | ( ( Op.Sub_dat_dur _ | Op.Sub_dur_dur | Op.Sub_int_int
            | Op.Sub_mon_mon | Op.Sub_rat_rat ),
            (lazy [(not_neutral, None); (x_neutral, Some (neutral, env))]),
            _ ) ->
          let annot = Custom { pos = opos; custom = { conditions = [] } } in
          let condition =
            ( ( EAppOp { op = Op.Eq, opos; args = [x_neutral; neutral]; tys },
                annot ),
              env )
          in
          add_condition ~condition not_neutral, env
        | _ ->
          if not llevel.eval_op then
            (EAppOp { op = op, opos; args; tys }, m), env
          else
            let renv = ref env in
            (* Dirty workaround returning env and conds from
               evaluate_operator *)
            let eval e =
              let e, env = lazy_eval ctx !renv llevel e in
              renv := env;
              e
            in
            let e =
              Interpreter.evaluate_operator eval (op, opos) m Global.En
                (* Default language to English but this should not raise any
                   error messages so we don't care. *)
                args
            in
            e, !renv))
  | EApp { f; args }, m -> (
    if not llevel.eval_default then e0, env
    else
      match eval_to_value env f with
      | (EAbs { binder; _ }, _), env ->
        let vars, body = Bindlib.unmbind binder in
        let env =
          Seq.fold_left2
            (fun env1 var e -> Env.add var e env env1)
            env (Array.to_seq vars) (List.to_seq args)
        in
        let e, env = lazy_eval ctx env llevel body in
        e, env
      | e, _ -> error e "Invalid apply on %a" Expr.format e)
  | (EAbs _ | ELit _ | EEmpty | EPos _), _ -> e0, env (* these are values *)
  | (EStruct _ | ETuple _ | EInj _ | EArray _), _ ->
    if not llevel.eval_struct then e0, env
    else
      let env, e =
        Expr.map_gather ~acc:env ~join:Env.join
          ~f:(fun e ->
            let e, env = lazy_eval ctx env llevel e in
            env, Expr.box e)
          e0
      in
      Expr.unbox e, env
  | EStructAccess { e; name; field }, _ -> (
    if not llevel.eval_default then e0, env
    else
      match eval_to_value env e with
      | (EStruct { name = n; fields }, _), env when StructName.equal name n ->
        let e, env =
          lazy_eval ctx env llevel (StructField.Map.find field fields)
        in
        e, env
      | _ -> e0, env)
  | ETupleAccess { e; index; size }, _ -> (
    if not llevel.eval_default then e0, env
    else
      match eval_to_value env e with
      | (ETuple es, _), env when List.length es = size ->
        lazy_eval ctx env llevel (List.nth es index)
      | e, _ -> error e "Invalid tuple access on %a" Expr.format e)
  | EMatch { e; name; cases }, _ -> (
    if not llevel.eval_match then e0, env
    else
      match eval_to_value env e with
      | (EInj { name = n; cons; e = e1 }, m), env when EnumName.equal name n ->
        let condition = e, env in
        (* FIXME: condition should be "e TEST_MATCH n" but we don't have a
           concise expression to express that *)
        let e1, env =
          lazy_eval ctx env llevel
            ( EApp
                {
                  f = EnumConstructor.Map.find cons cases;
                  args = [e1];
                  tys = [];
                },
              m )
        in
        add_condition ~condition e1, env
      | e, _ -> error e "Invalid match argument %a" Expr.format e)
  | EDefault { excepts; just; cons }, m -> (
    let excs =
      List.filter_map
        (fun e ->
          match eval_to_value env e ~eval_default:false with
          | (EEmpty, _), _ -> None
          | e -> Some e)
        excepts
    in
    match excs with
    | [] -> (
      match eval_to_value env just with
      | (ELit (LBool true), _), _ ->
        let condition = just, env in
        let e, env = lazy_eval ctx env llevel cons in
        add_condition ~condition e, env
      | (ELit (LBool false), _), _ -> (EEmpty, m), env
      (* Note: conditions for empty are skipped *)
      | e, _ -> error e "Invalid exception justification %a" Expr.format e)
    | [(e, env)] ->
      log "@[<hov 5>EVAL %a@]" Expr.format e;
      lazy_eval ctx env llevel e
    | _ :: _ :: _ ->
      Message.error ~pos:(Expr.mark_pos m)
        ~extra_pos:(List.map (fun (e, _) -> "", Expr.pos e) excs)
        "Conflicting exceptions")
  | EPureDefault e, _ -> lazy_eval ctx env llevel e
  | EIfThenElse { cond; etrue; efalse }, m -> (
    match eval_to_value env cond with
    | (ELit (LBool true), _), _ ->
      let condition = cond, env in
      let e, env = lazy_eval ctx env llevel etrue in
      add_condition ~condition e, env
    | (ELit (LBool false), m), _ -> (
      let condition = bool_negation (Expr.mark_pos m) cond, env in
      let e, env = lazy_eval ctx env llevel efalse in
      match efalse with
      (* The negated condition is not added for nested [else if] to reduce
         verbosity *)
      | EIfThenElse _, _ -> e, env
      | _ -> add_condition ~condition e, env)
    | e, _ -> error e "Invalid condition %a" Expr.format e)
  | EErrorOnEmpty e, _ -> (
    match eval_to_value env e ~eval_default:false with
    | ((EEmpty, _) as e'), _ ->
      (* This does _not_ match the eager semantics ! *)
      error e' "This value is undefined %a" Expr.format e
    | e, env -> lazy_eval ctx env llevel e)
  | EAssert e, m -> (
    if noassert then (ELit LUnit, m), env
    else
      match eval_to_value env e with
      | (ELit (LBool true), m), env -> (ELit LUnit, m), env
      | (ELit (LBool false), _), _ ->
        error e "Assert failure (%a)" Expr.format e error e
          "Assert failure (%a)" Expr.format e
      | _ -> error e "Invalid assertion condition %a" Expr.format e)
  | EFatalError err, _ ->
    error e0 "%a" Format.pp_print_text (Runtime.error_message err)
  | EExternal _, _ -> assert false (* todo *)
  | _ -> .

let result_level base_vars =
  {
    value_level with
    eval_struct = true;
    eval_op = false;
    eval_vars = (fun v -> not (Var.Set.mem v base_vars));
  }

let interpret_program (prg : ('dcalc, 'm) gexpr program) (scope : ScopeName.t) :
    ('t, 'm) gexpr * Env.t =
  let ctx = prg.decl_ctx in
  let (all_env, scopes), _ =
    BoundList.fold_left prg.code_items ~init:(Env.empty, ScopeName.Map.empty)
      ~f:(fun (env, scopes) item v ->
        match item with
        | ScopeDef (name, body) ->
          let e = Scope.to_expr ctx body in
          let e = Expr.remove_logging_calls (Expr.unbox e) in
          ( Env.add v (Expr.unbox e) env env,
            ScopeName.Map.add name (v, body.scope_body_input_struct) scopes )
        | Topdef (_, _, _, e) -> Env.add v e env env, scopes)
  in
  let scope_v, _scope_arg_struct = ScopeName.Map.find scope scopes in
  let e, env = (Env.find scope_v all_env).base in
  log "=====================";
  log "%a" (Print.expr ~debug:true ()) e;
  log "=====================";
  (* let m = Mark.get e in *)
  (* let application_arg =
   *   Expr.estruct scope_arg_struct
   *     (StructField.Map.map
   *        (function
   *          | TArrow (ty_in, ty_out), _ ->
   *            Expr.make_abs
   *              [| Var.make "_" |]
   *              (Bindlib.box EEmptyError, Expr.with_ty m ty_out)
   *              ty_in (Expr.mark_pos m)
   *          | ty -> Expr.evar (Var.make "undefined_input") (Expr.with_ty m ty))
   *        (StructName.Map.find scope_arg_struct ctx.ctx_structs))
   *     m
   * in *)
  match e with
  | EAbs { binder; _ }, _ ->
    let _vars, e = Bindlib.unmbind binder in
    let rec get_vars base_vars env = function
      | EApp { f = EAbs { binder; _ }, _; args = [arg] }, _ ->
        let vars, e = Bindlib.unmbind binder in
        let var = vars.(0) in
        let base_vars =
          match Expr.skip_wrappers arg with
          | ELit _, _ -> Var.Set.add var base_vars
          | _ -> base_vars
        in
        let env = Env.add var arg env env in
        get_vars base_vars env e
      | e -> base_vars, env, e
    in
    let base_vars, env, e = get_vars Var.Set.empty env e in
    lazy_eval ctx env (result_level base_vars) e
  | _ -> assert false

let print_value_with_env ctx ppf env expr =
  let already_printed = ref Var.Set.empty in
  let rec aux env ppf expr =
    Print.expr ~debug:true () ppf expr;
    Format.pp_print_cut ppf ();
    let vars = Var.Set.diff (Expr.free_vars expr) !already_printed in
    Var.Set.iter
      (fun v ->
        let e, env = (Env.find v env).reduced in
        let e, env = lazy_eval ctx env (result_level Var.Set.empty) e in
        Format.fprintf ppf "@[<hov 2>%a %a =@ %a =@ %a@]@,@," Print.punctuation
          "»" Print.var_debug v Expr.format
          (fst (lazy_eval ctx env value_level e))
          (aux env) e)
      vars;
    already_printed := Var.Set.union !already_printed vars;
    Format.pp_print_cut ppf ()
  in
  Format.pp_open_vbox ppf 2;
  aux env ppf expr;
  Format.pp_close_box ppf ()

module V = struct
  type t = expr

  let compare a b = Expr.compare a b

  let hash = function
    | EVar v, _ -> Var.hash v
    | EAbs { tys; _ }, _ -> Hashtbl.hash tys
    | e, _ -> Hashtbl.hash e

  let equal a b = Expr.equal a b
  let format = Expr.format
end

module E = struct
  type hand_side = Lhs of string | Rhs of string
  type t = { side : hand_side option; condition : bool; invisible : bool }

  let compare x y =
    match Bool.compare x.condition y.condition with
    | 0 ->
      Option.compare
        (fun x y ->
          match x, y with
          | Lhs s, Lhs t | Rhs s, Rhs t -> String.compare s t
          | Lhs _, Rhs _ -> -1
          | Rhs _, Lhs _ -> 1)
        x.side y.side
    | n -> n

  let default = { side = None; condition = false; invisible = false }
end

module G = Graph.Persistent.Digraph.AbstractLabeled (V) (E)

let op_kind = function
  | Op.Add_int_int | Add_rat_rat | Add_mon_mon | Add_dat_dur _ | Add_dur_dur
  | Sub_int_int | Sub_rat_rat | Sub_mon_mon | Sub_dat_dat | Sub_dat_dur _
  | Sub_dur_dur ->
    `Sum
  | Mult_int_int | Mult_rat_rat | Mult_mon_rat | Mult_dur_int | Div_int_int
  | Div_rat_rat | Div_mon_rat | Div_mon_mon | Div_dur_dur ->
    `Product
  | Round_mon | Round_rat -> `Round
  | Map | Filter | Reduce | Fold -> `Fct
  | _ -> `Other

module GTopo = Graph.Topological.Make (G)

let to_graph ctx env expr =
  let rec aux env g e =
    (* lazy_eval ctx env (result_level base_vars) e *)
    match Expr.skip_wrappers e with
    | ( EAppOp { op = (ToRat_int | ToRat_mon | ToMoney_rat), _; args = [arg]; _ },
        _ ) ->
      aux env g arg
    (* we skip conversions *)
    | ELit l, _ ->
      let v = G.V.create e in
      G.add_vertex g v, v
    | (EVar var, _) as e ->
      let v = G.V.create e in
      let g = G.add_vertex g v in
      let child, env = (Env.find var env).base in
      let g, child_v = aux env g child in
      G.add_edge g v child_v, v
    | EAppOp { op = _; args; _ }, _ ->
      let v = G.V.create e in
      let g = G.add_vertex g v in
      let g, children = List.fold_left_map (aux env) g args in
      List.fold_left (fun g -> G.add_edge g v) g children, v
    | EInj { e; _ }, _ -> aux env g e
    | EStruct { fields; _ }, _ ->
      let v = G.V.create e in
      let g = G.add_vertex g v in
      let args = StructField.Map.values fields in
      let g, children = List.fold_left_map (aux env) g args in
      List.fold_left (fun g -> G.add_edge g v) g children, v
    | _ ->
      Format.eprintf "%a" Expr.format e;
      assert false
  in
  let base_g, _ = aux env G.empty expr in
  base_g

let rec is_const e =
  match Expr.skip_wrappers e with
  | ELit _, _ -> true
  | EInj { e; _ }, _ -> is_const e
  | EStruct { fields; _ }, _ ->
    StructField.Map.for_all (fun _ e -> is_const e) fields
  | EArray el, _ -> List.for_all is_const el
  | _ -> false

let program_to_graph
    options
    (prg : (dcalc, 'm) gexpr program)
    (scope : ScopeName.t) : G.t * expr Var.Set.t * Env.t =
  let ctx = prg.decl_ctx in
  let customize =
    Expr.map_marks ~f:(fun m ->
        Custom { pos = Expr.mark_pos m; custom = { conditions = [] } })
  in
  let (all_env, scopes), _ =
    BoundList.fold_left prg.code_items ~init:(Env.empty, ScopeName.Map.empty)
      ~f:(fun (env, scopes) item v ->
        match item with
        | ScopeDef (name, body) ->
          let e = Scope.to_expr ctx body in
          let e = customize (Expr.unbox e) in
          let e = Expr.remove_logging_calls (Expr.unbox e) in
          let e =
            Renaming.expr
              (Renaming.get_ctx
                 {
                   Renaming.reserved = [];
                   sanitize_varname = Fun.id;
                   skip_constant_binders = false;
                   constant_binder_name = None;
                 })
              (Expr.unbox e)
          in
          ( Env.add (Var.translate v) (Expr.unbox e) env env,
            ScopeName.Map.add name (v, body.scope_body_input_struct) scopes )
        | Topdef (_, _, _, e) ->
          Env.add (Var.translate v) (Expr.unbox (customize e)) env env, scopes)
  in
  let scope_v, _scope_arg_struct = ScopeName.Map.find scope scopes in
  let e, env = (Env.find (Var.translate scope_v) all_env).base in
  let rec find_tested_scope e acc =
    if acc <> None then acc
    else
      match e with
      | ( EApp
            {
              f = EVar vscope, _;
              args = [(EStruct { name; fields }, _)];
              tys = [_in_ty];
            },
          _ ) ->
        Some (vscope, name, fields)
      | e -> Expr.shallow_fold find_tested_scope e acc
  in
  let tested_scope_v, in_struct, in_fields =
    Option.get (find_tested_scope e None)
  in
  log "The specified scope is detected to be testing scope %s"
    (Bindlib.name_of tested_scope_v);
  let e, env = (Env.find tested_scope_v all_env).base in
  let in_var, e =
    match e with
    | EAbs { binder; _ }, _ ->
      let vars, e = Bindlib.unmbind binder in
      vars.(0), e
    | _ -> assert false
  in
  let rec get_vars base_vars env = function
    (* This assumes the scope body starts with the deconstruction and binding of
       its input struct *)
    | ( EApp
          {
            f = EAbs { binder; _ }, _;
            args = [(EStructAccess { name; e = EVar vstruc, _; field; _ }, _)];
            _;
          },
        _ )
      when StructName.equal name in_struct ->
      let vars, body = Bindlib.unmbind binder in
      let var = vars.(0) in
      let base_vars = Var.Set.add var base_vars in
      let env = Env.add var (StructField.Map.find field in_fields) env env in
      get_vars base_vars env body
    | e -> base_vars, env, e
  in
  let base_vars, env, e = get_vars Var.Set.empty env e in
  let e1, env = lazy_eval ctx env (result_level base_vars) e in
  let level =
    {
      value_level with
      eval_struct = false;
      eval_op = false;
      eval_match = true;
      eval_vars = (fun v -> false);
    }
  in
  let rec aux parent (g, var_vertices, env0) e =
    let e, env0 = lazy_eval ctx env0 level e in
    let m = Mark.get e in
    let (Custom { custom = { conditions; _ }; _ }) = m in
    let g, var_vertices, env0 =
      (* add conditions *)
      if not options.with_conditions then g, var_vertices, env0
      else
        match parent with
        | None -> g, var_vertices, env0
        | Some parent ->
          List.fold_left
            (fun (g, var_vertices, env0) (econd, env) ->
              let (g, var_vertices, env), vcond =
                aux (Some parent) (g, var_vertices, env) econd
              in
              ( G.add_edge_e g
                  (G.E.create parent
                     { side = None; condition = true; invisible = false }
                     vcond),
                var_vertices,
                Env.join env0 env ))
            (g, var_vertices, env0) conditions
    in
    let e = Mark.set m (Expr.skip_wrappers e) in
    match e with
    | ( EAppOp
          { op = (ToRat_int | ToRat_mon | ToMoney_rat), _; args = [arg]; tys },
        _ ) ->
      aux parent (g, var_vertices, env0) (Mark.set m arg)
    (* we skip conversions *)
    | ELit l, _ ->
      let v = G.V.create e in
      (G.add_vertex g v, var_vertices, env0), v
    | EVar var, _ -> (
      try (g, var_vertices, env0), Var.Map.find var var_vertices
      with Var.Map.Not_found _ -> (
        try
          let child, env = (Env.find var env0).base in
          let m = Mark.get child in
          let v = G.V.create (Mark.set m e) in
          let g = G.add_vertex g v in
          let (g, var_vertices, env), child_v =
            aux (Some v) (g, var_vertices, Env.join env0 env) child
          in
          let var_vertices =
            (* Duplicates non-base constant var nodes *)
            if Var.Set.mem var base_vars then var_vertices
            else
              let rec is_lit v =
                match G.V.label v with
                | ELit _, _ -> true
                | EVar var, _ when not (Var.Set.mem var base_vars) -> (
                  match G.succ g v with [v] -> is_lit v | _ -> false)
                | _ -> false
              in
              if is_lit child_v then var_vertices
                (* This duplicates constant var nodes *)
              else Var.Map.add var v var_vertices
          in
          (G.add_edge g v child_v, var_vertices, env), v
        with Var.Map.Not_found _ ->
          Message.warning "VAR NOT FOUND: %a" Print.var var;
          let v = G.V.create e in
          let g = G.add_vertex g v in
          (g, var_vertices, env), v))
    | EAppOp { op = (Map | Filter | Reduce | Fold), _; args = _ :: args; _ }, _
      ->
      (* First argument (which is a function) is ignored *)
      let v = G.V.create e in
      let g = G.add_vertex g v in
      let (g, var_vertices, env), children =
        List.fold_left_map (aux (Some v)) (g, var_vertices, env0) args
      in
      ( (List.fold_left (fun g -> G.add_edge g v) g children, var_vertices, env),
        v )
    | EAppOp { op = op, _; args = [lhs; rhs]; _ }, _ ->
      let v = G.V.create e in
      let g = G.add_vertex g v in
      let (g, var_vertices, env), lhs =
        aux (Some v) (g, var_vertices, env0) lhs
      in
      let (g, var_vertices, env), rhs =
        aux (Some v) (g, var_vertices, env) rhs
      in
      let lhs_label, rhs_label =
        match op with
        | Add_int_int | Add_rat_rat | Add_mon_mon | Add_dat_dur _ | Add_dur_dur
          ->
          Some (E.Lhs "⊕"), Some (E.Rhs "⊕")
        | Sub_int_int | Sub_rat_rat | Sub_mon_mon | Sub_dat_dat | Sub_dat_dur _
        | Sub_dur_dur ->
          Some (E.Lhs "⊕"), Some (E.Rhs "⊖")
        | Mult_int_int | Mult_rat_rat | Mult_mon_rat | Mult_dur_int ->
          Some (E.Lhs "⊗"), Some (E.Rhs "⊗")
        | Div_int_int | Div_rat_rat | Div_mon_rat | Div_mon_mon | Div_dur_dur ->
          Some (E.Lhs "⊗"), Some (E.Rhs "⊘")
        | _ -> None, None
      in
      let g =
        G.add_edge_e g
          (G.E.create v
             { side = lhs_label; condition = false; invisible = false }
             lhs)
      in
      let g =
        G.add_edge_e g
          (G.E.create v
             { side = rhs_label; condition = false; invisible = false }
             rhs)
      in
      (g, var_vertices, env), v
    | EAppOp { op = _; args; _ }, _ ->
      let v = G.V.create e in
      let g = G.add_vertex g v in
      let (g, var_vertices, env), children =
        List.fold_left_map (aux (Some v)) (g, var_vertices, env0) args
      in
      ( (List.fold_left (fun g -> G.add_edge g v) g children, var_vertices, env),
        v )
    | EInj { e; _ }, _ -> aux parent (g, var_vertices, env0) e
    | EStruct { fields; _ }, _ ->
      let v = G.V.create e in
      let g = G.add_vertex g v in
      let args = StructField.Map.values fields in
      let (g, var_vertices, env), children =
        List.fold_left_map (aux (Some v)) (g, var_vertices, env0) args
      in
      ( (List.fold_left (fun g -> G.add_edge g v) g children, var_vertices, env),
        v )
    | EArray elts, _ ->
      let v = G.V.create e in
      let g = G.add_vertex g v in
      let (g, var_vertices, env), children =
        List.fold_left_map (aux (Some v)) (g, var_vertices, env0) elts
      in
      ( (List.fold_left (fun g -> G.add_edge g v) g children, var_vertices, env),
        v )
    | EAbs _, _ ->
      (g, var_vertices, env), G.V.create e (* (testing -> ignored) *)
    | EMatch { name; e; cases }, _ -> aux parent (g, var_vertices, env0) e
    | EStructAccess { e; field; _ }, _ ->
      let v = G.V.create e in
      let g = G.add_vertex g v in
      let (g, var_vertices, env), child =
        aux (Some v) (g, var_vertices, env0) e
      in
      (G.add_edge g v child, var_vertices, env), v
    | _ ->
      Format.eprintf "%a" Expr.format e;
      assert false
  in
  let (g, vmap, env), _ = aux None (G.empty, Var.Map.empty, env) e in
  log "BASE: @[<v>%a@]"
    (Format.pp_print_list Print.var)
    (Var.Set.elements base_vars);
  g, base_vars, env

let reverse_graph g =
  G.fold_edges_e
    (fun e g ->
      G.add_edge_e (G.remove_edge_e g e)
        (G.E.create (G.E.dst e) (G.E.label e) (G.E.src e)))
    g g

let subst_by v1 e2 e =
  let rec f = function
    | EVar v, m when Var.equal v v1 -> Expr.box e2
    | e -> Expr.map ~f ~op:Fun.id e
  in
  Expr.unbox (f e)

let map_vertices f g =
  G.fold_vertex
    (fun v g ->
      let v' = G.V.create (f v) in
      let g =
        G.fold_pred_e
          (fun e g -> G.add_edge_e g (G.E.create (G.E.src e) (G.E.label e) v'))
          g v g
      in
      let g =
        G.fold_succ_e
          (fun e g -> G.add_edge_e g (G.E.create v' (G.E.label e) (G.E.dst e)))
          g v g
      in
      G.remove_vertex g v)
    g g

let rec graph_cleanup options g base_vars =
  (* let _g =
   *   let module GCtr = Graph.Contraction.Make (G) in
   *   GCtr.contract
   *     (fun e ->
   *       G.E.label e = None
   *       &&
   *       match G.V.label (G.E.src e), G.V.label (G.E.dst e) with
   *       | (EVar _, _), (EVar _, _) -> true
   *       | ( (EApp { f = EOp { op = op1; _ }, _; args = [_; _] }, _),
   *           (EApp { f = EOp { op = op2; _ }, _; args = [_; _] }, _) ) -> (
   *         match op_kind op1, op_kind op2 with
   *         | `Sum, `Sum -> true
   *         | `Prod, `Prod -> true
   *         | _ -> false)
   *       | _ -> false)
   *     g
   * in *)
  let module GTop = Graph.Topological.Make (G) in
  let module VMap = Map.Make (struct
    include G.V

    let format ppf v = V.format ppf (G.V.label v)
  end) in
  let g, vmap =
    (* Remove separate nodes for variable literal values *)
    G.fold_vertex
      (fun v (g, vmap) ->
        match G.V.label v with
        (* | (ELit _, _), [EVar _, _] -> G.remove_vertex g v *)
        | ELit _, m ->
          ( G.remove_vertex g v,
            (* Forward position of the deleted literal to its parent *)
            List.fold_left
              (fun vmap v ->
                let out =
                  G.succ_e g v
                  |> List.filter (fun e -> not (G.E.label e).condition)
                in
                match out with [_] -> VMap.add v m vmap | _ -> vmap)
              vmap (G.pred g v) )
        | _, _ -> g, vmap)
      g (g, VMap.empty)
  in
  let g =
    map_vertices
      (fun v ->
        match VMap.find_opt v vmap with
        | Some m -> Mark.set m (G.V.label v)
        | None -> G.V.label v)
      g
  in
  let g =
    (* Merge intermediate operations *)
    let g = reverse_graph g in
    GTop.fold (* Variables -> result order *)
      (fun v g ->
        let succ = G.succ g v in
        match G.V.label v, succ, List.map G.V.label succ with
        | (EAppOp _, _), [v2], [(EAppOp _, _)] ->
          let g =
            List.fold_left
              (fun g e ->
                G.add_edge_e g (G.E.create (G.E.src e) (G.E.label e) v2))
              g (G.pred_e g v)
          in
          G.remove_vertex g v
        | _ -> g)
      g g
    |> reverse_graph
  in
  let g, substs =
    (* Remove intermediate variables *)
    GTop.fold (* Result -> variables order *)
      (fun v (g, substs) ->
        let succ_e = G.succ_e g v in
        if List.exists (fun ed -> (G.E.label ed).condition) succ_e then
          g, substs
        else
          let succ = List.map G.E.dst succ_e in
          match G.V.label v, succ, List.map G.V.label succ with
          | (EVar var1, m1), [v2], [(EVar var2, m2)]
            when not (Var.Set.mem var1 base_vars) ->
            let g =
              List.fold_left
                (fun g e ->
                  G.add_edge_e g (G.E.create (G.E.src e) (G.E.label e) v2))
                g (G.pred_e g v)
            in
            ( G.remove_vertex g v,
              fun e -> subst_by var1 (EVar var2, m2) (substs e) )
          | (EVar var1, m1), [v2], [((EApp _, _) as e2)]
            when not (Var.Set.mem var1 base_vars) -> (
            let pred_e = G.pred_e g v in
            match pred_e, List.map (fun e -> G.V.label (G.E.src e)) pred_e with
            | [pred_e], [(EApp _, _)]
              when G.E.src pred_e |> G.out_degree g <= options.merge_level ->
              (* Arbitrary heuristics: don't merge if the child node already has
                 > level parents *)
              let g =
                G.add_edge_e g
                  (G.E.create (G.E.src pred_e) (G.E.label pred_e) v2)
              in
              G.remove_vertex g v, fun e -> subst_by var1 e2 (substs e)
            | _ -> g, substs)
          | _ -> g, substs)
      g (g, G.V.label)
  in
  let g = map_vertices substs g in
  let g =
    (* Merge intermediate operations (again) *)
    let g = reverse_graph g in
    GTop.fold (* Variables -> result order *)
      (fun v g ->
        let succ = G.succ g v in
        match G.V.label v, succ, List.map G.V.label succ with
        | (EAppOp _, _), [v2], [(EAppOp _, _)] ->
          let g =
            List.fold_left
              (fun g e ->
                G.add_edge_e g (G.E.create (G.E.src e) (G.E.label e) v2))
              g (G.pred_e g v)
          in
          G.remove_vertex g v
        | _ -> g)
      g g
    |> reverse_graph
  in
  let g =
    let module EMap = Map.Make (struct
      type t = expr

      let compare = Expr.compare
      let format = Expr.format
    end) in
    (* Merge duplicate nodes *)
    let emap =
      G.fold_vertex
        (fun v expr_map ->
          let e = G.V.label v in
          EMap.update e
            (function None -> Some [v] | Some l -> Some (v :: l))
            expr_map)
        g EMap.empty
    in
    EMap.fold
      (fun expr vs g ->
        match vs with
        | [] | [_] -> g
        | v0 :: vn ->
          let e_in =
            List.map (G.pred_e g) vs
            |> List.flatten
            |> List.map (fun e -> G.E.create (G.E.src e) (G.E.label e) v0)
            |> List.sort_uniq G.E.compare
          in
          let e_out =
            List.map (G.succ_e g) vs
            |> List.flatten
            |> List.map (fun e -> G.E.create v0 (G.E.label e) (G.E.dst e))
            |> List.sort_uniq G.E.compare
          in
          let g = List.fold_left G.remove_vertex g vn in
          let g = List.fold_left G.remove_edge_e g (G.succ_e g v0) in
          let g = List.fold_left G.remove_edge_e g (G.pred_e g v0) in
          let g = List.fold_left G.add_edge_e g e_in in
          let g = List.fold_left G.add_edge_e g e_out in
          g)
      emap g
  in
  let g =
    (* Merge formulas and subsequent variable affectation nodes *)
    G.fold_edges_e
      (fun e g ->
        if (not (G.mem_edge_e g e)) || (G.E.label e).condition then g
        else
          match G.V.label (G.E.src e), G.V.label (G.E.dst e) with
          | ((EVar _, _) as var), ((EAppOp _, m) as expr) ->
            let pos = Expr.pos expr in
            let v' =
              G.V.create
                ( EAppOp
                    {
                      op = Op.Eq, pos;
                      args = [var; expr];
                      tys = [Type.any pos; Type.any pos];
                    },
                  m )
              (* This form is matched and displayed specifically below *)
            in
            let g =
              G.fold_pred_e
                (fun e1 g ->
                  G.add_edge_e g (G.E.create (G.E.src e1) (G.E.label e1) v'))
                g (G.E.src e) g
            in
            let g =
              G.fold_succ_e
                (fun e1 g ->
                  G.add_edge_e g (G.E.create v' (G.E.label e1) (G.E.dst e1)))
                g (G.E.src e) g
            in
            let g =
              G.fold_succ_e
                (fun e1 g ->
                  G.add_edge_e g (G.E.create v' (G.E.label e1) (G.E.dst e1)))
                g (G.E.dst e) g
            in
            G.remove_vertex (G.remove_vertex g (G.E.dst e)) (G.E.src e)
          | _ -> g)
      g g
  in
  g

let expr_to_dot_label0 :
    type a.
    Global.backend_lang ->
    decl_ctx ->
    Env.t ->
    Format.formatter ->
    (a, 't) gexpr ->
    unit =
 fun lang ctx env ->
  let xlang ~en ?(pl = en) ~fr () =
    match lang with Global.Fr -> fr | Global.En -> en | Global.Pl -> pl
  in
  let rec aux_value : type a t. Format.formatter -> (a, t) gexpr -> unit =
   fun ppf e -> Print.UserFacing.value ~fallback lang ppf e
  and fallback : type a t. Format.formatter -> (a, t) gexpr -> unit =
   fun ppf e ->
    let module E = Print.ExprGen (struct
      let var ppf v = String.format ppf (Bindlib.name_of v)
      let lit = Print.UserFacing.lit lang

      let operator : type x. Format.formatter -> x operator -> unit =
       fun ppf o ->
        let open Op in
        let str =
          match o with
          | Eq_boo_boo | Eq_int_int | Eq_rat_rat | Eq_mon_mon | Eq_dur_dur
          | Eq_dat_dat | Eq ->
            "＝"
          | Minus_int | Minus_rat | Minus_mon | Minus_dur | Minus -> "-"
          | ToRat_int | ToRat_mon | ToRat -> ""
          | ToMoney_rat | ToMoney | ToInt | ToInt_rat -> ""
          | Add_int_int | Add_rat_rat | Add_mon_mon | Add_dat_dur _
          | Add_dur_dur | Add ->
            "+"
          | Sub_int_int | Sub_rat_rat | Sub_mon_mon | Sub_dat_dat
          | Sub_dat_dur _ | Sub_dur_dur | Sub ->
            "-"
          | Mult_int_int | Mult_rat_rat | Mult_mon_int | Mult_mon_rat
          | Mult_dur_int | Mult ->
            "×"
          | Div_int_int | Div_rat_rat | Div_mon_mon | Div_mon_int | Div_mon_rat
          | Div_dur_dur | Div ->
            "÷"
          | Lt_int_int | Lt_rat_rat | Lt_mon_mon | Lt_dur_dur | Lt_dat_dat | Lt
            ->
            "<"
          | Lte_int_int | Lte_rat_rat | Lte_mon_mon | Lte_dur_dur | Lte_dat_dat
          | Lte ->
            "≤"
          | Gt_int_int | Gt_rat_rat | Gt_mon_mon | Gt_dur_dur | Gt_dat_dat | Gt
            ->
            ">"
          | Gte_int_int | Gte_rat_rat | Gte_mon_mon | Gte_dur_dur | Gte_dat_dat
          | Gte ->
            "≥"
          | Concat -> "++"
          | Not -> xlang () ~en:"not" ~fr:"non"
          | Length -> xlang () ~en:"length" ~fr:"nombre"
          | GetDay -> xlang () ~en:"day_of_month" ~fr:"jour_du_mois"
          | GetMonth -> xlang () ~en:"month" ~fr:"mois"
          | GetYear -> xlang () ~en:"year" ~fr:"année"
          | FirstDayOfMonth ->
            xlang () ~en:"first_day_of_month" ~fr:"premier_jour_du_mois"
          | LastDayOfMonth ->
            xlang () ~en:"last_day_of_month" ~fr:"dernier_jour_du_mois"
          | Round_rat | Round_mon | Round -> xlang () ~en:"round" ~fr:"arrondi"
          | Log _ -> xlang () ~en:"Log" ~fr:"Journal"
          | And -> xlang () ~en:"and" ~fr:"et"
          | Or -> xlang () ~en:"or" ~fr:"ou"
          | Xor -> xlang () ~en:"xor" ~fr:"ou bien"
          | Map -> xlang () ~en:"on_every" ~fr:"pour_chaque"
          | Map2 -> xlang () ~en:"on_every_2" ~fr:"pour_chaque_2"
          | Reduce -> xlang () ~en:"reduce" ~fr:"réunion"
          | Filter -> xlang () ~en:"filter" ~fr:"filtre"
          | Fold -> xlang () ~en:"fold" ~fr:"pliage"
          | HandleExceptions -> ""
          | ToClosureEnv -> ""
          | FromClosureEnv -> ""
        in
        Format.pp_print_string ppf str

      let pre_map = Expr.skip_wrappers

      let bypass : type a t. Format.formatter -> (a, t) gexpr -> bool =
       fun ppf e ->
        let percent_printer ppf = function
          | ELit (LRat r), m
            when Runtime.(o_lt_rat_rat r (Runtime.decimal_of_float 1.)) ->
            Format.fprintf ppf "%a%%" aux_value
              ( ELit
                  (LRat
                     (Runtime.o_mult_rat_rat r (Runtime.decimal_of_float 100.))),
                m )
          | e -> aux_value ppf e
        in
        match Mark.remove e with
        | ELit _ | EArray _ | ETuple _ | EStruct _ | EInj _ | EEmpty | EAbs _
        | EExternal _ ->
          aux_value ppf e;
          true
        | EAppOp
            { op = (Op.Mult_rat_rat | Op.Mult_mon_rat), _; args = [x1; x2]; _ }
          ->
          Format.fprintf ppf "%a × %a" percent_printer x1 percent_printer x2;
          true
        | EMatch { e; cases; _ } ->
          let cases =
            List.map
              (function
                | cons, (EAbs { binder; _ }, _) ->
                  cons, snd (Bindlib.unmbind binder)
                | cons, e -> cons, e)
              (EnumConstructor.Map.bindings cases)
          in
          if
            List.for_all
              (function _, (ELit (LBool _), _) -> true | _ -> false)
              cases
          then (
            let cases =
              List.filter_map
                (function c, (ELit (LBool true), _) -> Some c | _ -> None)
                cases
            in
            Format.fprintf ppf "%a @<1>%s @[<hov>%a@]" aux_value e "≅"
              (Format.pp_print_list
                 ~pp_sep:(fun ppf () ->
                   Format.fprintf ppf " %t@ " (fun ppf -> operator ppf Or))
                 EnumConstructor.format)
              cases;
            true)
          else false
        | _ -> false
    end) in
    E.expr ppf e
  in
  aux_value

let htmlencode =
  let re = Re.(compile (set "&<>'\"@")) in
  Re.replace re ~f:(fun g ->
      match Re.Group.get g 0 with
      | "&" -> "&amp;"
      | "<" -> "&lt;"
      | ">" -> "&gt;"
      | "'" -> "&apos;"
      | "\"" -> "&quot;"
      | "@" -> "&commat;"
      | _ -> assert false)

let expr_to_dot_label0 lang ctx env ppf e =
  Format.fprintf ppf "%s"
    (htmlencode (Format.asprintf "%a" (expr_to_dot_label0 lang ctx env) e))

let rec expr_to_dot_label (style : Style.theme) lang ctx env ppf e =
  let print_expr ppf = function
    | (EVar _, _) as e ->
      let e, _ = lazy_eval ctx env value_level e in
      expr_to_dot_label0 lang ctx env ppf e
    | e -> expr_to_dot_label0 lang ctx env ppf e
  in
  let e = Expr.skip_wrappers e in
  match e with
  | EVar v, _ ->
    let e, _ = lazy_eval ctx env value_level e in
    Format.fprintf ppf
      "<table border=\"0\" cellborder=\"0\" cellspacing=\"1\"><tr><td \
       align=\"left\"><b>%a</b></td></tr><tr><td align=\"right\"><b>= <font \
       color=\"#007799\">@[<hv>%a@]</font></b></td></tr></table>"
      String.format (Bindlib.name_of v)
      (expr_to_dot_label0 lang ctx env)
      e
  | ( EAppOp { op = Op.Eq, _; args = [(EVar v, _); ((EAppOp _, _) as expr)]; _ },
      _ ) ->
    let value, _ = lazy_eval ctx env value_level expr in
    Format.fprintf ppf
      "<table border=\"0\" cellborder=\"0\" cellspacing=\"1\"><tr><td \
       align=\"left\"><b>%a</b></td></tr><hr/><tr><td \
       align=\"left\">@[<hv>%a@]</td></tr><tr><td align=\"right\"><b>= <font \
       color=\"#0088aa\">@[<hv>%a@]</font></b></td></tr></table>"
      String.format (Bindlib.name_of v)
      (expr_to_dot_label0 lang ctx env)
      expr
      (expr_to_dot_label0 lang ctx env)
      value
  | EStruct { name; fields }, _ ->
    let pr ppf =
      Format.fprintf ppf
        "<table border=\"%f\" cellborder=\"1\" cellspacing=\"0\" \
         bgcolor=\"#%06x\" color=\"#%06x\"><tr><td \
         colspan=\"2\">%a</td></tr><tr><td>%a</td><td>%a</td></tr></table>"
        (float_of_int style.output.stroke)
        style.output.fill style.output.border StructName.format name
        (Format.pp_print_list
           ~pp_sep:(fun ppf () -> Format.pp_print_string ppf " | ")
           (fun ppf fld ->
             StructField.format ppf
               fld (* ; * Format.pp_print_string ppf "<vr/>" *)))
        (StructField.Map.keys fields)
        (Format.pp_print_list
           ~pp_sep:(fun ppf () -> Format.pp_print_string ppf " | ")
           (fun ppf -> function
             | ((EVar _ | ELit _ | EInj { e = (EVar _ | ELit _), _; _ }), _) as
               e ->
               print_expr ppf e (* ; * Format.pp_print_string ppf "\\l" *)
             | _ -> Format.pp_print_string ppf "…"))
        (StructField.Map.values fields)
    in
    Format.pp_print_string ppf (Message.unformat pr)
  | EArray elts, _ ->
    let pr ppf =
      Format.fprintf ppf
        "<table border=\"0\" cellborder=\"1\" \
         cellspacing=\"0\"><tr>%a</tr></table>"
        (Format.pp_print_list (fun ppf -> function
           | ((EVar _ | ELit _), _) as e ->
             Format.fprintf ppf "<td>%a</td>" print_expr e
           | _ -> Format.pp_print_string ppf "<td>…</td>"))
        elts
    in
    Format.pp_print_string ppf (Message.unformat pr)
  | e -> Format.fprintf ppf "%a@," (expr_to_dot_label0 lang ctx env) e

let to_dot lang ppf ctx env base_vars g ~base_src_url ~line_format ~theme =
  let module GPr = Graph.Graphviz.Dot (struct
    include G

    let print_expr env ctx lang ppf e =
      (* let out_funs = Format.pp_get_formatter_out_functions ppf () in
       * Format.pp_set_formatter_out_functions ppf
       *   {
       *     out_funs with
       *     Format.out_newline = (fun () -> out_funs.out_string "<br/>" 0 2);
       *   }; *)
      expr_to_dot_label theme env ctx lang ppf e
    (* ; * Format.pp_print_flush ppf (); * Format.pp_set_formatter_out_functions
       ppf out_funs *)

    let graph_attributes _ =
      [
        `BgcolorWithTransparency (Int32.of_int 0x00);
        (* `Ratio (`Float 0.8); *)
        (* `Concentrate true; *)
        `Ratio `Compress;
        (* `Size (8.3, 11.7); (* A4 in inches..... *) *)
        (* `Rankdir `LeftToRight *)
      ]

    let default_vertex_attributes _ = []

    let vertex_label v =
      let print_expr = print_expr lang ctx env in
      (* match G.V.label v with
       * | (EVar v, _) as e ->
       *   Format.asprintf "%a = %a" String.format (Bindlib.name_of v) print_expr
       *     (fst (lazy_eval ctx env value_level e))
       * | e -> *)
      Format.asprintf "%a" print_expr (G.V.label v)

    let vertex_name v = Printf.sprintf "x%03d" (G.V.hash v)

    let vertex_attributes v =
      let e = V.label v in
      let pos =
        match e with
        | EVar v, _ -> Expr.pos (fst (Env.find v env).reduced)
        | e -> Expr.pos e
      in
      let loc_text =
        Re.replace_string
          Re.(compile (char '\n'))
          ~by:"&#10;"
          (String.concat "\n» " (List.rev (Pos.get_law_info pos)) ^ "\n")
      in
      let url = base_src_url ^ "/" ^ Pos.get_file pos in
      let line_suffix =
        Re.(
          replace_string ~all:true
            (compile (str "NN"))
            ~by:(string_of_int (Pos.get_start_line pos))
            line_format)
      in
      `HtmlLabel (vertex_label v (* ^ "\n" ^ loc_text *))
      :: `Comment loc_text
         (* :: `Url
          *      ("http://localhost:8080/fr/examples/housing-benefits#"
          *      ^ Re.(
          *          replace_string
          *            (compile
          *               (seq [char '/'; rep1 (diff any (char '/')); str "/../"]))
          *            ~by:"/" (Pos.get_file pos))
          *      ^ "-"
          *      ^ string_of_int (Pos.get_start_line pos)) *)
      :: `Url (url ^ line_suffix)
      :: `Fontname "sans"
      ::
      (match G.V.label v with
      | EVar var, _ ->
        if Var.Set.mem var base_vars then
          [
            `Style `Filled;
            `Fillcolor theme.input.fill;
            `Shape `Box;
            `Penwidth (Style.width theme.input.stroke);
            `Color theme.input.border;
            `Fontcolor theme.input.text;
          ]
        else if
          List.exists (fun e -> not (G.E.label e).condition) (G.succ_e g v)
        then
          (* non-constants *)
          [
            `Style `Filled;
            `Fillcolor theme.middle.fill;
            `Shape `Box;
            `Penwidth (Style.width theme.middle.stroke);
            `Color theme.middle.border;
            `Fontcolor theme.middle.text;
          ]
        else
          (* Constants *)
          [
            `Style `Filled;
            `Fillcolor theme.constant.fill;
            `Shape `Box;
            `Penwidth (Style.width theme.middle.stroke);
            `Color theme.constant.border;
            `Fontcolor theme.constant.text;
          ]
      | EAppOp { op = Op.Eq, _; args = [(EVar _, _); (EAppOp _, _)]; _ }, _ ->
        [
          `Style `Filled;
          `Fillcolor theme.middle.fill;
          `Shape `Box;
          `Penwidth (Style.width theme.middle.stroke);
          `Color theme.middle.border;
          `Fontcolor theme.middle.text;
        ]
      | EStruct _, _ | EArray _, _ ->
        [
          `Style `Solid;
          (* `Fillcolor theme.output.fill; *)
          `Shape `Plaintext;
          `Penwidth (Style.width theme.output.stroke);
          `Color theme.output.border;
          `Fontcolor theme.output.text;
        ]
      (* | EAppOp { op = op, _; _ }, _ -> (
       *     match op_kind op with
       *     | `Sum | `Product | _ -> [`Shape `Box; `Fillcolor 0xff0000] (* | _ -> [] *)) *)
      | _ ->
        [
          `Style `Dashed;
          `Style `Filled;
          `Fillcolor theme.condition.fill;
          `Shape `Box;
          `Penwidth (Style.width theme.condition.stroke);
          `Color theme.condition.border;
          `Fontcolor theme.condition.text;
        ])

    let get_subgraph v =
      let is_input =
        match G.V.label v with
        | EVar var, _ -> Var.Set.mem var base_vars
        | _ -> false
      in
      if is_input then
        Some
          {
            Graph.Graphviz.DotAttributes.sg_name = "inputs";
            sg_attributes =
              [
                `Style `Filled;
                `FillcolorWithTransparency (Int32.of_int 0x0);
                `ColorWithTransparency (Int32.of_int 0x0);
              ];
            sg_parent = None;
          }
      else None

    let default_edge_attributes _ = []

    let edge_attributes e =
      match E.label e with
      | { invisible = true; _ } -> [`Style `Invis; `Weight 6]
      | { condition = true; _ } ->
        [
          `Style `Dashed;
          `Penwidth 2.;
          `Color 0xff7700;
          `Arrowhead `Odot;
          `Weight 8;
        ]
      | { side = Some (Lhs s | Rhs s); _ } ->
        [`Color theme.arrows (* `Label s; `Color 0xbb7700 *); `Weight 10]
      | { side = None; _ } ->
        [`Color theme.arrows (* `Minlen 0; `Weight 10 *); `Weight 10]
  end) in
  let g =
    (* Add fake edges from everything towards the inputs to force ordering *)
    G.fold_vertex
      (fun v g ->
        match G.V.label v with
        | EVar var, _ when Var.Set.mem var base_vars ->
          G.fold_vertex
            (fun v0 g ->
              if G.out_degree g v0 > 0 then g
              else
                match G.V.label v0 with
                | EVar var, _ when Var.Set.mem var base_vars -> g
                | _ ->
                  G.add_edge_e g
                    (G.E.create v0
                       { invisible = true; condition = false; side = None }
                       v))
            g g
        | _ -> g)
      g g
  in
  GPr.fprint_graph ppf (reverse_graph g)

(* -- Plugin registration -- *)

let options =
  let open Cmdliner in
  let conditions =
    Arg.(
      value
      & flag
      & info ["conditions"]
          ~doc:
            "Include boolean conditions used to choose the specific formula \
             nodes (with dashed lines) in the resulting graph. Without this, \
             only the nodes contributing to the actual calculation are shown.")
  in
  let no_cleanup =
    Arg.(
      value
      & flag
      & info ["no-cleanup"]
          ~doc:
            "Disable automatic cleanup of intermediate computation nodes. Very \
             verbose but sometimes useful for debugging.")
  in
  let merge_level =
    Arg.(
      value
      & opt int 2
      & info ["merge-level"]
          ~doc:
            "Determines an internal threshold to the heuristics for merging \
             intermediate nodes with as many parents. Higher means more \
             aggressive merges.")
  in
  let format =
    let mkinfo s =
      ( `Convert s,
        Arg.info [s]
          ~doc:
            (Printf.sprintf
               "Outputs a compiled $(b,.%s) file instead of a $(b,.dot) file \
                (requires $(i,graphviz) to be installed)."
               s) )
    in
    Arg.(
      value
      & vflag `Dot
          [
            ( `Dot,
              info ["dot"]
                ~doc:"Output the graph in dot format (this is the default)" );
            mkinfo "svg";
            mkinfo "png";
            mkinfo "pdf";
            mkinfo "html";
          ])
  in
  let theme =
    Arg.(
      value
      & opt (enum ["light", Style.light; "dark", Style.dark]) Style.light
      & info ["theme"] ~doc:"Select the color theme for graphical outputs")
  in
  let show =
    Arg.(
      value
      & opt ~vopt:(Some "xdot") (some string) None
      & info ["show"]
          ~doc:"Opens the resulting graph in the given command immediately.")
  in
  let base_src_url =
    Arg.(
      value
      & opt string
          "https://github.com/CatalaLang/catala-examples/blob/exemple_explication"
      & info ["url-base"] ~docv:"URL"
          ~doc:
            "Base URL that can be used to browse the Catala code. Nodes will \
             link to $(i,URL)/relative/filename.catala_xx")
  in
  let line_format =
    Arg.(
      value
      & opt string "#LNN"
      & info ["line-format"] ~docv:"FORMAT"
          ~doc:
            "Format used to encode line position in URL's suffix. The sequence \
             of characters 'NN' will be expanded using the actual positions. \
             The default value '#LNN' matches github-like positions")
  in
  let inline_module_usages =
    Arg.(
      value
      & flag
      & info ["inline-mod-uses"]
          ~doc:"Attempts to inline existing module usages using a heuristic.")
  in
  let f
      with_conditions
      no_cleanup
      merge_level
      format
      theme
      show
      output
      base_src_url
      line_format
      inline_module_usages =
    {
      with_conditions;
      with_cleanup = not no_cleanup;
      merge_level;
      format;
      theme;
      show;
      output;
      base_src_url;
      line_format;
      inline_module_usages;
    }
  in
  Term.(
    const f
    $ conditions
    $ no_cleanup
    $ merge_level
    $ format
    $ theme
    $ show
    $ Cli.Flags.output
    $ base_src_url
    $ line_format
    $ inline_module_usages)

let inline_used_modules global_options =
  let prg =
    Surface.Parser_driver.parse_top_level_file global_options.Global.input_src
  in
  let used_modules =
    prg.Surface.Ast.program_used_modules
    |> List.map (fun { Surface.Ast.mod_use_name; mod_use_alias; _ } ->
           Mark.remove mod_use_name, Mark.remove mod_use_alias)
  in
  if used_modules = [] then ()
  else
    let find_module_file_in_input_directory mod_name =
      let dir =
        match global_options.Global.input_src with
        | FileName f -> Filename.dirname f
        | _ -> Sys.getcwd ()
      in
      let en_candidate = String.uncapitalize_ascii mod_name ^ ".catala_en" in
      let fr_candidate = String.uncapitalize_ascii mod_name ^ ".catala_fr" in
      Sys.readdir dir
      |> Array.map (Filename.concat dir)
      |> Array.find_map (fun path ->
             let file = Filename.basename path in
             if file = en_candidate then Some path
             else if file = fr_candidate then Some path
             else None)
    in
    let raw_prg, file =
      match global_options.input_src with
      | FileName s ->
        ( Catala_utils.File.(contents (check_file s |> Option.value ~default:"")),
          s )
      | Contents (s, fname) -> s, fname
      | Stdin _ -> Message.error "Cannot inline module usage from stdin"
    in
    let raw_prg =
      (* let's assume it's in english *)
      String.split_on_char '\n' raw_prg
    in
    let contents =
      List.fold_left
        (fun raw_prg (used_module, used_module_alias) ->
          let mod_file_opt = find_module_file_in_input_directory used_module in
          match mod_file_opt with
          | None ->
            Message.error
              "Cannot find corresponding file for module '%s' required for \
               module inlining"
              used_module
          | Some mod_file ->
            let new_content =
              let s =
                Re.(
                  replace_string
                    (compile (str "> Module"))
                    ~by:"< Module" (File.contents mod_file))
              in
              Global.Contents (s, mod_file)
            in
            Surface.Parser_driver.register_included_file_resolver
              ~filename:mod_file ~new_content;
            List.map
              (fun s ->
                let open Re in
                let using_mod_re =
                  compile (str (Format.sprintf "> Using %s" used_module))
                in
                if matches using_mod_re s <> [] then
                  Format.sprintf "> Include: %s" (Filename.basename mod_file)
                else
                  replace_string
                    (compile (str (used_module_alias ^ ".")))
                    ~by:"" ~all:true s)
              raw_prg)
        raw_prg used_modules
    in
    let contents = String.concat "\n" contents in
    Global.enforce_options ~input_src:(Global.Contents (contents, file)) ()
    |> ignore

let run
    (includes : Global.raw_file list)
    optimize
    ex_scope
    explain_options
    global_options =
  let () =
    if explain_options.inline_module_usages then
      inline_used_modules global_options
  in
  let prg, _ =
    Driver.Passes.dcalc global_options ~includes ~optimize
      ~check_invariants:false ~autotest:false ~typed:Expr.typed
  in
  Interpreter.load_runtime_modules prg
    ~hashf:(Hash.finalise ~monomorphize_types:false);
  let scope = Driver.Commands.get_scope_uid prg.decl_ctx ex_scope in
  (* let result_expr, env = interpret_program prg scope in *)
  let g, base_vars, env = program_to_graph explain_options prg scope in
  log "Base variables detected: @[<hov>%a@]"
    (Format.pp_print_list Print.var)
    (Var.Set.elements base_vars);
  let g =
    if explain_options.with_cleanup then
      graph_cleanup explain_options g base_vars
    else g
  in
  let lang =
    Cli.file_lang (Global.input_src_file global_options.Global.input_src)
  in
  let dot_content =
    to_dot lang Format.str_formatter prg.decl_ctx env base_vars g
      ~base_src_url:explain_options.base_src_url
      ~line_format:explain_options.line_format ~theme:explain_options.theme;
    Format.flush_str_formatter ()
    |> Re.(replace_string (compile (seq [bow; str "comment="])) ~by:"tooltip=")
  in
  let with_dot_file =
    match explain_options with
    | { format = `Convert _; _ } | { show = Some _; output = None; _ } ->
      File.with_temp_file "catala-explain" "dot" ~contents:dot_content
    | { output; _ } ->
      let _, with_out = Driver.Commands.get_output global_options output in
      with_out (fun oc -> output_string oc dot_content);
      fun f ->
        f
          (Option.value ~default:"-"
             (Option.map Global.options.path_rewrite output))
  in
  with_dot_file
  @@ fun dotfile ->
  (match explain_options.format with
  | `Convert fmt ->
    let _, with_out =
      Driver.Commands.get_output global_options explain_options.output
    in
    let wrap_html, fmt = if fmt = "html" then true, "svg" else false, fmt in
    with_out (fun oc ->
        if wrap_html then (
          output_string oc "<!DOCTYPE html>\n<html>\n<head>\n  <title>";
          output_string oc (htmlencode ex_scope);
          Printf.fprintf oc
            "  </title>\n\
            \  <style>\n\
            \    body { background-color: #%06x }\n\
            \    svg { max-width: 80rem; height: fit-content; }\n\
            \  </style>\n\
             </head>\n\
             <body>\n"
            explain_options.theme.page_background);
        let contents = File.process_out "dot" ["-T" ^ fmt; dotfile] in
        output_string oc contents;
        if wrap_html then output_string oc "</body>\n</html>\n")
  | `Dot -> ());
  match explain_options.show with
  | None -> ()
  | Some cmd ->
    raise (Cli.Exit_with (Sys.command (cmd ^ " " ^ Filename.quote dotfile)))

let term =
  let open Cmdliner.Term in
  const run
  $ Cli.Flags.include_dirs
  $ Cli.Flags.optimize
  $ Cli.Flags.ex_scope
  $ options

let () =
  Driver.Plugin.register "explain" term
    ~doc:
      "Generates a graph of the formulas that are used for a given execution \
       of a scope"
    ~man:
      [
        `P
          "This command requires a given scope with no inputs (i.e. a test \
           scope). A partial/lazy evaluation will recursively take place to \
           explain intermediate formulas that take place in the computation, \
           from the inputs (specified in the test scope) to the final outputs. \
           The output is a graph, in .dot format (graphviz) by default (see \
           $(b,--svg) and $(b,--show) for other options)";
      ]
