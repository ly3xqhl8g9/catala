(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020 Inria,
   contributors: Emile Rolley <emile.rolley@tuta.io>, Louis Gesbert
   <louis.gesbert@inria.fr>.

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
open Lcalc
open Lcalc.Ast
open Lcalc.To_ocaml
module D = Dcalc.Ast

(** Contains all format functions used to generating the [js_of_ocaml] wrapper
    of the corresponding Catala program. *)
module To_jsoo = struct
  let format_struct_field_name_camel_case
      (ppf : Format.formatter)
      (v : StructField.t) : unit =
    StructField.to_string v
    |> String.to_camel_case
    |> String.uncapitalize_ascii
    |> Format.pp_print_string ppf

  (* Supersedes [To_ocaml.format_struct_name], which can refer to enums from
     other modules: here everything is flattened in the current namespace *)
  let format_struct_name ppf name =
    StructName.to_string name
    |> String.to_id
    |> String.uncapitalize_ascii
    |> String.map (function '.' -> '_' | c -> c)
    |> Format.pp_print_string ppf

  (* Supersedes [To_ocaml.format_enum_name], which can refer to enums from other
     modules: here everything is flattened in the current namespace *)
  let format_enum_name ppf name =
    EnumName.to_string name
    |> String.to_ascii
    |> String.uncapitalize_ascii
    |> String.map (function '.' -> '_' | c -> c)
    |> Format.pp_print_string ppf

  let format_tlit (fmt : Format.formatter) (l : typ_lit) : unit =
    Print.base_type fmt
      (match l with
      | TUnit -> "unit"
      | TInt -> "int"
      | TRat | TMoney -> "Js.number Js.t"
      | TDuration -> "Runtime_jsoo.Runtime.duration Js.t"
      | TBool -> "bool Js.t"
      | TDate -> "Js.js_string Js.t"
      | TPos -> "source_position Js.t")

  let rec format_typ (fmt : Format.formatter) (typ : typ) : unit =
    let format_typ_with_parens (fmt : Format.formatter) (t : typ) =
      if typ_needs_parens t then Format.fprintf fmt "(%a)" format_typ t
      else Format.fprintf fmt "%a" format_typ t
    in
    match Mark.remove typ with
    | TLit l -> Format.fprintf fmt "%a" format_tlit l
    | TStruct s -> Format.fprintf fmt "%a Js.t" format_struct_name s
    | TTuple _ ->
      (* Tuples are encoded as an javascript polymorphic array. *)
      Format.fprintf fmt "Js.Unsafe.any Js.js_array Js.t "
    | TOption t ->
      Format.fprintf fmt "@[<hov 2>(%a)@] Js.opt" format_typ_with_parens t
    | TDefault _ -> assert false
    | TEnum e -> Format.fprintf fmt "%a Js.t" format_enum_name e
    | TArray t1 ->
      Format.fprintf fmt "@[%a@ Js.js_array Js.t@]" format_typ_with_parens t1
    | TVar _ -> Format.fprintf fmt "Js.Unsafe.any Js.t"
    | TForAll tb ->
      let _v, typ = Bindlib.unmbind tb in
      format_typ fmt typ
    | TArrow (t1, t2) ->
      Format.fprintf fmt "(@[<hov 2>unit, @ %a -> %a@]) Js.meth_callback"
        (Format.pp_print_list
           ~pp_sep:(fun fmt () -> Format.pp_print_string fmt " -> ")
           format_typ_with_parens)
        t1 format_typ_with_parens t2
    | TClosureEnv -> Format.fprintf fmt "Js.Unsafe.any Js.t"

  let rec format_to_js fmt typ =
    match Mark.remove typ with
    | TLit TUnit -> ()
    | TLit TBool -> Format.fprintf fmt "Js.bool"
    | TLit TInt -> Format.fprintf fmt "integer_to_int"
    | TLit TRat -> Format.fprintf fmt "Js.number_of_float %@%@ decimal_to_float"
    | TLit TMoney -> Format.fprintf fmt "Js.number_of_float %@%@ money_to_float"
    | TLit TDuration -> Format.fprintf fmt "duration_to_js"
    | TLit TDate -> Format.fprintf fmt "date_to_js"
    | TLit TPos -> Format.fprintf fmt "position_to_js"
    | TEnum ename -> Format.fprintf fmt "%a_to_js" format_enum_name ename
    | TStruct sname -> Format.fprintf fmt "%a_to_js" format_struct_name sname
    | TArray t ->
      Format.fprintf fmt "Js.array %@%@ Array.map (fun x -> %a x)" format_to_js
        t
    | TDefault _ -> assert false
    | TTuple tl ->
      let elts = List.mapi (fun i t -> i, t) tl in
      Format.fprintf fmt "(fun (%a) -> Js.array [|%a|])"
        (Format.pp_print_list
           ~pp_sep:(fun ppf () -> Format.fprintf ppf ",@ ")
           (fun fmt (i, _) -> Format.fprintf fmt "x%d" i))
        elts
        (Format.pp_print_list
           ~pp_sep:(fun ppf () -> Format.fprintf ppf ";@ ")
           (fun fmt (i, t) ->
             Format.fprintf fmt "Js.Unsafe.inject (%a x%d)" format_to_js t i))
        elts
    | TOption t ->
      Format.fprintf fmt
        "(function Optional.Absent () -> Js.null | Optional.Present x -> \
         Js.some (%a x))"
        format_to_js t
    | TVar _ -> Format.fprintf fmt "Js.Unsafe.inject"
    | TForAll tb ->
      let _v, typ = Bindlib.unmbind tb in
      format_to_js fmt typ
    | TArrow _ | TClosureEnv -> ()

  let rec format_of_js fmt typ =
    match Mark.remove typ with
    | TLit TUnit -> ()
    | TLit TBool -> Format.fprintf fmt "Js.to_bool"
    | TLit TInt -> Format.fprintf fmt "integer_of_int"
    | TLit TRat -> Format.fprintf fmt "decimal_of_float %@%@ Js.float_of_number"
    | TLit TMoney ->
      Format.fprintf fmt
        "money_of_decimal %@%@ decimal_of_float %@%@ Js.float_of_number"
    | TLit TDuration -> Format.fprintf fmt "duration_of_js"
    | TLit TDate -> Format.fprintf fmt "date_of_js"
    | TLit TPos -> Format.fprintf fmt "position_of_js"
    | TEnum ename -> Format.fprintf fmt "%a_of_js" format_enum_name ename
    | TStruct sname -> Format.fprintf fmt "%a_of_js" format_struct_name sname
    | TArray t ->
      Format.fprintf fmt "Array.map (fun x -> %a x) %@%@ Js.to_array"
        format_of_js t
    | TDefault _ -> assert false
    | TTuple tl ->
      let pp_sep fmt () = Format.fprintf fmt ",@ " in
      let elts = List.mapi (fun i t -> i, t) tl in
      Format.fprintf fmt "@[<hv 2>(fun t ->@ let t = Js.to_array t in@ %a)@]"
        (Format.pp_print_list ~pp_sep (fun fmt (i, t) ->
             Format.fprintf fmt "%a (Js.Unsafe.coerce t.(%d))" format_of_js t i))
        elts
    | TOption t ->
      Format.fprintf fmt
        "@[<hv 2>(fun o ->@ @[<hv 2>Js.Opt.case o@ (fun () -> Optional.Absent \
         ())@ @[<hov 2>(fun x ->@ @[<hov 2>Optional.Present@ @[<hv 2>(%a@ \
         x)@]@])@]@])@]"
        format_of_js t
    | TVar _ -> Format.fprintf fmt "Js.Unsafe.inject"
    | TForAll tb ->
      let _v, typ = Bindlib.unmbind tb in
      format_of_js fmt typ
    | TArrow _ | TClosureEnv -> Format.fprintf fmt ""

  let format_var_camel_case (fmt : Format.formatter) (v : 'm Var.t) : unit =
    let lowercase_name =
      Bindlib.name_of v
      |> String.to_camel_case
      |> Re.Pcre.substitute ~rex:(Re.Pcre.regexp "\\.") ~subst:(fun _ ->
             "_dot_")
      |> String.uncapitalize_ascii
    in
    if
      List.mem lowercase_name ["handle_default"; "handle_default_opt"]
      || String.begins_with_uppercase (Bindlib.name_of v)
    then Format.fprintf fmt "%s" lowercase_name
    else if lowercase_name = "_" then Format.fprintf fmt "%s" lowercase_name
    else Format.fprintf fmt "%s_" lowercase_name

  let format_ctx
      (type_ordering : TypeIdent.t list)
      (fmt : Format.formatter)
      (ctx : decl_ctx) : unit =
    let format_prop_or_meth fmt (struct_field_type : typ) =
      match Mark.remove struct_field_type with
      | TArrow _ -> Format.fprintf fmt "Js.meth"
      | _ -> Format.fprintf fmt "Js.readonly_prop"
    in
    let format_struct_decl fmt (struct_name, struct_fields) =
      (* if StructName.path struct_name <> [] then () else *)
      let fmt_struct_name fmt _ = format_struct_name fmt struct_name in
      let fmt_module_struct_name fmt _ =
        To_ocaml.format_to_module_name fmt (`Sname struct_name)
      in
      let fmt_to_js fmt _ =
        Format.pp_print_list
          ~pp_sep:(fun fmt () -> Format.fprintf fmt "@\n")
          (fun fmt (struct_field, struct_field_type) ->
            match Mark.remove struct_field_type with
            | TArrow (t1, t2) ->
              let args_names =
                ListLabels.mapi t1 ~f:(fun i _ ->
                    "function_input" ^ string_of_int i)
              in
              Format.fprintf fmt "@[<hov 2>method %a =@ Js.wrap_meth_callback@ "
                format_struct_field_name_camel_case struct_field;
              Format.fprintf fmt "@[<hv 2>(@,fun _ %a ->@ "
                (Format.pp_print_list (fun fmt (arg_i, ti) ->
                     Format.fprintf fmt "(%s: %a)" arg_i format_typ ti))
                (List.combine args_names t1);
              format_to_js fmt t2;
              Format.pp_print_string fmt " (";
              fmt_struct_name fmt ();
              Format.pp_print_char fmt '.';
              format_struct_field_name fmt (None, struct_field);
              Format.pp_print_char fmt ' ';
              Format.pp_print_list
                (fun fmt (i, ti) ->
                  Format.fprintf fmt "@[<hv 2>(%a@ %a)@]" format_of_js ti
                    Format.pp_print_string i)
                fmt
                (List.combine args_names t1);
              Format.fprintf fmt "))@]@]"
            | _ ->
              Format.fprintf fmt "@[<hov 2>val %a =@ %a %a.%a@]"
                format_struct_field_name_camel_case struct_field format_to_js
                struct_field_type fmt_struct_name () format_struct_field_name
                (None, struct_field))
          fmt
          (StructField.Map.bindings struct_fields)
      in
      let fmt_of_js fmt _ =
        Format.pp_print_list
          ~pp_sep:(fun fmt () -> Format.fprintf fmt ";@\n")
          (fun fmt (struct_field, struct_field_type) ->
            match Mark.remove struct_field_type with
            | TArrow _ ->
              Format.fprintf fmt
                "%a = failwith \"The function '%a' translation isn't yet \
                 supported...\""
                format_struct_field_name (None, struct_field)
                format_struct_field_name (None, struct_field)
            | _ ->
              Format.fprintf fmt
                "@[<hv 2>%a =@ @[<hov 2>%a@ @[<hov>%a@,##.%a@]@]@]"
                format_struct_field_name (None, struct_field) format_of_js
                struct_field_type fmt_struct_name ()
                format_struct_field_name_camel_case struct_field)
          fmt
          (StructField.Map.bindings struct_fields)
      in
      let fmt_conv_funs fmt _ =
        Format.fprintf fmt
          "@[<hov 2>let %a_to_js@ (%a@ : %a.t)@ : %a Js.t =@ @[<hv 2>object%%js@\n\
           %a@\n\
           @]@]end@\n\
           @[<hov 2>let %a_of_js@ @[<hov 2>(%a@ : %a Js.t)@] :@ %a.t =@ @[<hv \
           2>{@,\
           %a@]@\n\
           }@]"
          fmt_struct_name () fmt_struct_name () fmt_module_struct_name ()
          fmt_struct_name () fmt_to_js () fmt_struct_name () fmt_struct_name ()
          fmt_struct_name () fmt_module_struct_name () fmt_of_js ()
      in

      if StructField.Map.is_empty struct_fields then
        Format.fprintf fmt
          "class type %a =@ object end@\n\
           let %a_to_js (_ : %a.t) : %a Js.t = object%%js end@\n\
           let %a_of_js (_ : %a Js.t) : %a.t = ()" fmt_struct_name ()
          fmt_struct_name () fmt_module_struct_name () fmt_struct_name ()
          fmt_struct_name () fmt_struct_name () fmt_module_struct_name ()
      else
        Format.fprintf fmt
          "@[<hv 2>class type %a =@ @[<hov 2>object@ %a@]@,end@\n%a@]@\n"
          fmt_struct_name ()
          (Format.pp_print_list
             ~pp_sep:(fun fmt () -> Format.fprintf fmt "@\n")
             (fun fmt (struct_field, struct_field_type) ->
               Format.fprintf fmt "@[<hov 2>method %a:@ %a %a@]"
                 format_struct_field_name_camel_case struct_field format_typ
                 struct_field_type format_prop_or_meth struct_field_type))
          (StructField.Map.bindings struct_fields)
          fmt_conv_funs ()
    in
    let format_enum_decl fmt (enum_name, (enum_cons : typ EnumConstructor.Map.t))
        =
      if
        (* EnumName.path enum_name <> [] || *)
        EnumName.equal enum_name Expr.option_enum
      then ()
      else
        let fmt_enum_name fmt _ = format_enum_name fmt enum_name in
        let fmt_module_enum_name fmt () =
          To_ocaml.format_to_module_name fmt (`Ename enum_name)
        in
        let fmt_to_js fmt _ =
          Format.fprintf fmt "%a"
            (Format.pp_print_list
               ~pp_sep:(fun fmt () -> Format.fprintf fmt "@\n")
               (fun fmt (cname, typ) ->
                 Format.fprintf fmt
                   "@[<v 2>@[<v 4>| %a arg -> object%%js@\n\
                    val kind = Js.string \"%a\"@\n\
                    val payload = Js.Unsafe.coerce (Js.Unsafe.inject (%a \
                    arg))@]@\n\
                    end@]"
                   format_enum_cons_name cname format_enum_cons_name cname
                   format_to_js typ))
            (EnumConstructor.Map.bindings enum_cons)
        in
        let fmt_of_js fmt _ =
          Format.fprintf fmt
            "@[<hov 2>match@ %a##.kind@ |> Js.to_string@ with@]@\n\
             @[<hv>%a@\n\
             @[<hv 2>| cons ->@ @[<hov 2>failwith@ @[<hov 2>(Printf.sprintf@ \
             \"Unexpected '%%s' kind for the enumeration '%a.t'\"@ \
             cons)@]@]@]@]"
            fmt_enum_name ()
            (Format.pp_print_list
               ~pp_sep:(fun fmt () -> Format.fprintf fmt "@\n")
               (fun fmt (cname, typ) ->
                 match Mark.remove typ with
                 | TTuple _ ->
                   Message.error ~pos:(Mark.get typ)
                     "Tuples aren't yet supported in the conversion to JS..."
                 | TLit TUnit ->
                   Format.fprintf fmt "@[<hv 2>| \"%a\" ->@ %a.%a ()@]"
                     format_enum_cons_name cname fmt_module_enum_name ()
                     format_enum_cons_name cname
                 | _ ->
                   Format.fprintf fmt
                     "| \"%a\" ->@\n%a.%a (%a (Js.Unsafe.coerce %a##.payload))"
                     format_enum_cons_name cname fmt_module_enum_name ()
                     format_enum_cons_name cname format_of_js typ fmt_enum_name
                     ()))
            (EnumConstructor.Map.bindings enum_cons)
            fmt_module_enum_name ()
        in

        let fmt_conv_funs fmt _ =
          Format.fprintf fmt
            "@[<hov 2>let %a_to_js@ : %a.t -> %a Js.t@ = function@\n\
             %a@]@\n\
             @\n\
             @[<hov 2>let %a_of_js@ @[<hov 2>(%a@ : %a Js.t)@]@ : %a.t =@ %a@]@\n"
            fmt_enum_name () fmt_module_enum_name () fmt_enum_name () fmt_to_js
            () fmt_enum_name () fmt_enum_name () fmt_enum_name ()
            fmt_module_enum_name () fmt_of_js ()
        in
        Format.fprintf fmt
          "@[<v 2>class type %a =@ @[<v 2>object@ @[<hov 2>method kind :@ \
           Js.js_string Js.t Js.readonly_prop@\n\
           @[<v 2>(** Expects one of:@\n\
           %a *)@]@]@\n\
           @\n\
           @[<hov 2>method payload :@ Js.Unsafe.any Js.t Js.readonly_prop@]@]@\n\
           end@]@\n\
           @\n\
           %a@\n"
          format_enum_name enum_name
          (Format.pp_print_list
             ~pp_sep:(fun fmt () -> Format.fprintf fmt "@\n")
             (fun fmt (enum_cons, _) ->
               Format.fprintf fmt "- \"%a\"" format_enum_cons_name enum_cons))
          (EnumConstructor.Map.bindings enum_cons)
          fmt_conv_funs ()
    in
    let is_in_type_ordering s =
      List.exists
        (fun struct_or_enum ->
          match struct_or_enum with
          | TypeIdent.Enum _ -> false
          | TypeIdent.Struct s' -> s = s')
        type_ordering
    in
    let scope_structs =
      List.map
        (fun (s, _) -> TypeIdent.Struct s)
        (StructName.Map.bindings
           (StructName.Map.filter
              (fun s _ -> not (is_in_type_ordering s))
              ctx.ctx_structs))
    in
    List.iter
      (fun struct_or_enum ->
        match struct_or_enum with
        | TypeIdent.Struct s ->
          Format.fprintf fmt "%a@\n" format_struct_decl
            (s, StructName.Map.find s ctx.ctx_structs)
        | TypeIdent.Enum e ->
          Format.fprintf fmt "%a@\n" format_enum_decl
            (e, EnumName.Map.find e ctx.ctx_enums))
      (type_ordering @ scope_structs)

  let fmt_input_struct_name fmt (scope_body : 'a expr scope_body) =
    format_struct_name fmt scope_body.scope_body_input_struct

  let fmt_output_struct_name fmt (scope_body : 'a expr scope_body) =
    format_struct_name fmt scope_body.scope_body_output_struct

  let format_scopes_to_fun
      (_ctx : decl_ctx)
      (fmt : Format.formatter)
      (scopes : 'e code_item_list) =
    ignore
    @@ BoundList.iter
         ~f:(fun var code_item ->
           match code_item with
           | Topdef _ -> ()
           | ScopeDef (_name, body) ->
             let fmt_fun_call fmt _ =
               Format.fprintf fmt
                 "@[<hv>@[<hv 2>execute_or_throw_error@ (@[<hv 2>fun () ->@ \
                  %a@ |> %a_of_js@ |> %a@ |> %a_to_js@])@]@]"
                 fmt_input_struct_name body fmt_input_struct_name body
                 format_var var fmt_output_struct_name body
             in
             Format.fprintf fmt
               "@\n@\n@[<hov 2>let %a@ (%a : %a Js.t)@ : %a Js.t =@\n%a@]@\n"
               format_var var fmt_input_struct_name body fmt_input_struct_name
               body fmt_output_struct_name body fmt_fun_call ())
         scopes

  let format_scopes_to_callbacks
      (_ctx : decl_ctx)
      (fmt : Format.formatter)
      (scopes : 'e code_item_list) : unit =
    ignore
    @@ BoundList.iter
         ~f:(fun var code_item ->
           match code_item with
           | Topdef _ -> ()
           | ScopeDef (_name, body) ->
             let fmt_meth_name fmt _ =
               Format.fprintf fmt "method %a : (%a Js.t -> %a Js.t) Js.callback"
                 format_var_camel_case var fmt_input_struct_name body
                 fmt_output_struct_name body
             in
             Format.fprintf fmt "@,@[<hov 2>%a =@ Js.wrap_callback@ %a@]@,"
               fmt_meth_name () format_var var)
         scopes

  let format_program
      (fmt : Format.formatter)
      (module_name : string option)
      (prgm : 'm Lcalc.Ast.program)
      (type_ordering : TypeIdent.t list) =
    let fmt_lib_name fmt _ =
      Format.fprintf fmt "%sLib"
        (Option.fold ~none:""
           ~some:(fun name ->
             name
             |> String.split_on_char '_'
             |> List.map String.capitalize_ascii
             |> String.concat "")
           module_name)
    in

    Format.fprintf fmt
      "(** This file has been generated by the Catala compiler, do not edit! *)@\n\
       @\n\
       open Runtime_ocaml.Runtime@\n\
       open Runtime_jsoo.Runtime@\n\
       open Js_of_ocaml@\n\
       %s@\n\
       @\n\
       [@@@@@@ocaml.warning \"-4-26-27-32-41-42\"]@\n\
       @\n\
       (* Generated API *)@\n\
       @\n\
       %a@\n\
       %a@\n\
       @\n\
       @[<v 2>let () =@ @[<hov 2> Js.export \"%a\"@\n\
       @[<v 2>(object%%js@ %a@]@\n\
       end)@]@]@?"
      (Option.fold ~none:"" ~some:(fun name -> "open " ^ name) module_name)
      (format_ctx type_ordering) prgm.decl_ctx
      (format_scopes_to_fun prgm.decl_ctx)
      prgm.code_items fmt_lib_name ()
      (format_scopes_to_callbacks prgm.decl_ctx)
      prgm.code_items
end

let run
    includes
    output
    optimize
    check_invariants
    closure_conversion
    keep_special_ops
    monomorphize_types
    _options =
  let options =
    Global.enforce_options ~trace:(Some (lazy Format.std_formatter)) ()
  in
  let prg, type_ordering, _ =
    Driver.Passes.lcalc options ~includes ~optimize ~check_invariants
      ~autotest:false ~closure_conversion ~keep_special_ops ~typed:Expr.typed
      ~monomorphize_types ~expand_ops:false
      ~renaming:(Some Lcalc.To_ocaml.renaming)
  in
  Driver.Commands.get_output_format options ~ext:"api_web.ml" output
    (fun jsoo_output_file fmt ->
      Message.debug "Writing JSOO API code to %s..."
        (Option.value ~default:"stdout" jsoo_output_file);
      let modname =
        match prg.module_name with
        | Some (m, _) -> ModuleName.to_string m
        | None ->
          String.capitalize_ascii
            Filename.(
              basename
                (remove_extension
                   (Global.input_src_file options.Global.input_src)))
      in
      To_jsoo.format_program fmt (Some modname) prg type_ordering)

let term =
  let open Cmdliner.Term in
  const run
  $ Cli.Flags.include_dirs
  $ Cli.Flags.output
  $ Cli.Flags.optimize
  $ Cli.Flags.check_invariants
  $ Cli.Flags.closure_conversion
  $ Cli.Flags.keep_special_ops
  $ Cli.Flags.monomorphize_types

let () =
  Driver.Plugin.register "api_web" term
    ~doc:
      "Catala plugin for generating web APIs. It generates OCaml code before \
       the associated [js_of_ocaml] wrapper."
