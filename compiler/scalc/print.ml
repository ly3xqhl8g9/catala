(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2022 Inria, contributor:
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

open Catala_utils
open Shared_ast
open Ast

let needs_parens (_e : expr) : bool = false

let format_var_name (fmt : Format.formatter) (v : VarName.t) : unit =
  VarName.format fmt v

let format_func_name (fmt : Format.formatter) (v : FuncName.t) : unit =
  FuncName.format fmt v

let format_type fmt = function
  | TStruct name, _ when StructName.equal name Expr.source_pos_struct ->
    StructName.format fmt name
  | ty -> Print.typ fmt ty

let rec format_expr
    (decl_ctx : decl_ctx)
    ?(debug : bool = false)
    (fmt : Format.formatter)
    (e : expr) : unit =
  let format_expr = format_expr decl_ctx ~debug in
  let format_with_parens (fmt : Format.formatter) (e : expr) =
    if needs_parens e then
      Format.fprintf fmt "%a%a%a" Print.punctuation "(" format_expr e
        Print.punctuation ")"
    else Format.fprintf fmt "%a" format_expr e
  in
  match Mark.remove e with
  | EVar v -> Format.fprintf fmt "%a" format_var_name v
  | EFunc v -> Format.fprintf fmt "%a" format_func_name v
  | EStruct { fields = es; name = s } ->
    Format.fprintf fmt "@[<hov 2>%a@ %a%a%a@]" StructName.format s
      Print.punctuation "{"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
         (fun fmt (struct_field, e) ->
           Format.fprintf fmt "%a%a%a%a %a" Print.punctuation "\""
             StructField.format struct_field Print.punctuation "\""
             Print.punctuation ":" format_expr e))
      (StructField.Map.bindings es)
      Print.punctuation "}"
  | ETuple es ->
    Format.fprintf fmt "@[<hov 2>%a%a%a@]" Print.punctuation "("
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
         (fun fmt e -> Format.fprintf fmt "%a" format_expr e))
      es Print.punctuation ")"
  | EArray es ->
    Format.fprintf fmt "@[<hov 2>%a%a%a@]" Print.punctuation "["
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ";@ ")
         (fun fmt e -> Format.fprintf fmt "%a" format_expr e))
      es Print.punctuation "]"
  | EStructFieldAccess { e1; field; _ } ->
    Format.fprintf fmt "%a%a%a%a%a" format_expr e1 Print.punctuation "."
      Print.punctuation "\"" StructField.format field Print.punctuation "\""
  | ETupleAccess { e1; index; _ } ->
    Format.fprintf fmt "%a%a%a%d%a" format_expr e1 Print.punctuation "."
      Print.punctuation "\"" index Print.punctuation "\""
  | EInj { e1 = e; cons; _ } ->
    Format.fprintf fmt "@[<hov 2>%a@ %a@]" EnumConstructor.format cons
      format_expr e
  | ELit l -> Print.lit fmt l
  | EPosLit -> Format.fprintf fmt "<%s>" (Pos.to_string_shorter (Mark.get e))
  | EAppOp
      {
        op = ((HandleExceptions | Map | Filter) as op), _;
        args = [arg1; arg2];
        _;
      } ->
    Format.fprintf fmt "@[<hov 2>%a@ %a@ %a@]" (Print.operator ~debug) op
      format_with_parens arg1 format_with_parens arg2
  | EAppOp { op = op, _; args = [arg1; arg2]; _ } ->
    Format.fprintf fmt "@[<hov 2>%a@ %a@ %a@]" format_with_parens arg1
      (Print.operator ~debug) op format_with_parens arg2
  | EAppOp { op = Log _, _; args = [arg1]; _ } when not debug ->
    Format.fprintf fmt "%a" format_with_parens arg1
  | EAppOp { op = op, _; args = [arg1]; _ } ->
    Format.fprintf fmt "@[<hov 2>%a@ %a@]" (Print.operator ~debug) op
      format_with_parens arg1
  | EApp { f; args = []; _ } ->
    Format.fprintf fmt "@[<hov 2>%a@ ()@]" format_expr f
  | EApp { f; args; _ } ->
    Format.fprintf fmt "@[<hov 2>%a@ %a@]" format_expr f
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt "@ ")
         format_with_parens)
      args
  | EAppOp { op = op, _; args; _ } ->
    Format.fprintf fmt "@[<hov 2>%a@ %a@]" (Print.operator ~debug) op
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt "@ ")
         format_with_parens)
      args
  | EExternal { modname; name } ->
    Format.fprintf fmt "%a.%s" format_var_name (Mark.remove modname)
      (Mark.remove name)

let rec format_statement
    (decl_ctx : decl_ctx)
    ?(debug : bool = false)
    (fmt : Format.formatter)
    (stmt : stmt Mark.pos) : unit =
  if debug then () else ();
  match Mark.remove stmt with
  | SInnerFuncDef { name; func } ->
    Format.fprintf fmt "@[<hov 2>%a@ %a@ %a@ %a@]@\n@[<v 2>  %a@]" Print.keyword
      "let func" format_var_name (Mark.remove name)
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt "@ ")
         (fun fmt ((name, _), typ) ->
           Format.fprintf fmt "%a%a %a@ %a%a" Print.punctuation "("
             format_var_name name Print.punctuation ":" format_type typ
             Print.punctuation ")"))
      func.func_params Print.punctuation "="
      (format_block decl_ctx ~debug)
      func.func_body
  | SLocalDecl { name; typ } ->
    Format.fprintf fmt "@[<hov 2>%a %a %a@ %a@]" Print.keyword "decl"
      format_var_name (Mark.remove name) Print.punctuation ":" format_type typ
  | SLocalDef { name; expr = naked_expr; _ } ->
    Format.fprintf fmt "@[<hov 2>%a %a@ %a@]" format_var_name (Mark.remove name)
      Print.punctuation "="
      (format_expr decl_ctx ~debug)
      naked_expr
  | SLocalInit { name; typ; expr = naked_expr } ->
    Format.fprintf fmt "@[<hov 2>%a %a %a %a %a@ %a@]" Print.keyword "init"
      format_var_name (Mark.remove name) Print.punctuation ":" format_type typ
      Print.punctuation "="
      (format_expr decl_ctx ~debug)
      naked_expr
  | SFatalError { error; _ } ->
    Format.fprintf fmt "@[<hov 2>%a %a@]" Print.keyword "fatal"
      Print.runtime_error error
  | SIfThenElse { if_expr = e_if; then_block = b_true; else_block = b_false } ->
    Format.fprintf fmt "@[<v 2>%a @[<hov 2>%a@]%a@ %a@]@ @[<v 2>%a%a@ %a@]"
      Print.keyword "if"
      (format_expr decl_ctx ~debug)
      e_if Print.punctuation ":"
      (format_block decl_ctx ~debug)
      b_true Print.keyword "else" Print.punctuation ":"
      (format_block decl_ctx ~debug)
      b_false
  | SReturn ret ->
    Format.fprintf fmt "@[<hov 2>%a %a@]" Print.keyword "return"
      (format_expr decl_ctx ~debug)
      ret
  | SAssert { expr; _ } ->
    Format.fprintf fmt "@[<hov 2>%a %a@]" Print.keyword "assert"
      (format_expr decl_ctx ~debug)
      expr
  | SSwitch { switch_var = v_switch; enum_name = enum; switch_cases = arms; _ }
    ->
    let cons = EnumName.Map.find enum decl_ctx.ctx_enums in
    Format.fprintf fmt "@[<v 0>%a @[<hov 2>%a@]%a@,@]%a" Print.keyword "switch"
      format_var_name v_switch Print.punctuation ":"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt "@\n")
         (fun fmt ((case, _), switch_case_data) ->
           Format.fprintf fmt "@[<v 2>%a %a %a %a@ %a@]" Print.punctuation "|"
             EnumConstructor.format case format_var_name
             switch_case_data.payload_var_name Print.punctuation "→"
             (format_block decl_ctx ~debug)
             switch_case_data.case_block))
      (List.combine (EnumConstructor.Map.bindings cons) arms)
  | _ -> .

and format_block
    (decl_ctx : decl_ctx)
    ?(debug : bool = false)
    (fmt : Format.formatter)
    (block : block) : unit =
  Format.pp_print_list
    ~pp_sep:(fun fmt () ->
      Print.punctuation fmt ";";
      Format.pp_print_space fmt ())
    (format_statement decl_ctx ~debug)
    fmt block

let format_item decl_ctx ?debug ppf def =
  Format.pp_open_hvbox ppf 2;
  Format.pp_open_hovbox ppf 4;
  Print.keyword ppf "let ";
  let () =
    match def with
    | SVar { var; expr; typ = _; visibility = _ } ->
      format_var_name ppf var;
      Print.punctuation ppf " =";
      Format.pp_close_box ppf ();
      Format.pp_print_space ppf ();
      format_expr decl_ctx ?debug ppf expr
    | SScope { scope_body_var = var; scope_body_func = func; _ }
    | SFunc { var; func; visibility = _ } ->
      format_func_name ppf var;
      Format.pp_print_list
        (fun ppf (arg, ty) ->
          Format.fprintf ppf "@ (%a: %a)" format_var_name (Mark.remove arg)
            format_type ty)
        ppf func.func_params;
      Print.punctuation ppf " =";
      Format.pp_close_box ppf ();
      Format.pp_print_space ppf ();
      format_block decl_ctx ?debug ppf func.func_body
  in
  Format.pp_close_box ppf ();
  Format.pp_print_cut ppf ()

let format_program ?debug ppf prg =
  try
    Format.pp_open_vbox ppf 0;
    ModuleName.Map.iter
      (fun m var ->
        Format.fprintf ppf "%a %a = %a@," Print.keyword "module" format_var_name
          var ModuleName.format m)
      prg.ctx.modules;
    Format.pp_print_list
      (format_item prg.ctx.decl_ctx ?debug)
      ppf prg.code_items;
    Format.pp_close_box ppf ()
  with e ->
    let bt = Printexc.get_raw_backtrace () in
    Format.pp_print_newline ppf ();
    Printexc.raise_with_backtrace e bt
