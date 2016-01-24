(* OCamlScript compiler
 * Copyright (C) 2015-2016 Bloomberg Finance L.P.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(* Author: Hongbo Zhang  *)



module E = J_helper.Exp 
module S = J_helper.Stmt

class count  var = object (self : 'self)
  val mutable appears = 0
  inherit Js_fold.fold as super
  method! ident  x =
    (if Ident.same x var then
      appears <- appears + 1); 
    self
  method get_appears = appears 
end

(* rewrite return for current block, but don't go into
   inner function, mostly for inlinning
 *)
class rewrite_return ?return_value ()=
  let mk_return  = 
    match return_value with 
    | None -> fun e -> S.exp e 
    | Some ident -> fun e -> S.define ~kind:Variable ident e in
  object (self : 'self)
    inherit Js_map.map as super
    method! statement x =
      match x.statement_desc with 
      | Return {return_value = e} -> 
          mk_return e 
      | _ -> super#statement x 
    method! expression x = x (* don't go inside *)
  end  

(* 
    HERE we are using an object , so make sure to clean it up, 
    remove stale cache
 *)
let mark_dead = object (self)
  inherit Js_fold.fold as super

  val mutable name = ""

  val mutable ident_use_stats : (Ident.t , [`Info of J.ident_info | `Recursive]) Hashtbl.t
      = Hashtbl.create 17
  
  val mutable export_set : Ident_set.t = Ident_set.empty    

  method mark_not_dead ident =
    match Hashtbl.find ident_use_stats ident with
    | exception Not_found -> (* First time *)
        Hashtbl.add ident_use_stats ident `Recursive 
        (* recursive identifiers *)
    | `Recursive
      -> ()
    | `Info x ->  Js_op_util.update_used_stats x Used 

  method scan b ident (ident_info : J.ident_info) = 
    let is_export = Ident_set.mem ident export_set in
    let () = 
      if is_export (* && false *) then 
        Js_op_util.update_used_stats ident_info Exported 
    in
    match Hashtbl.find ident_use_stats ident with
    | `Recursive -> 
        Js_op_util.update_used_stats ident_info Used; 
        Hashtbl.replace ident_use_stats ident (`Info ident_info)
    | `Info _ ->  
        (** check [camlinternlFormat,box_type] inlined twice 
            FIXME: seems we have redeclared identifiers
         *)
        Ext_log.warn __LOC__ "@[%s$%d in %s@]@." ident.name ident.stamp name
        (* assert false *)
    | exception Not_found ->  (* First time *)
        Hashtbl.add ident_use_stats ident (`Info ident_info);
        Js_op_util.update_used_stats ident_info 
          (if b then Scanning_pure else Scanning_non_pure)
  method promote_dead = 
    Hashtbl.iter (fun _id (info : [`Info of J.ident_info  | `Recursive]) ->
      match info  with 
      | `Info ({used_stats = Scanning_pure} as info) -> 
          Js_op_util.update_used_stats info Dead_pure
      | `Info ({used_stats = Scanning_non_pure} as info) -> 
          Js_op_util.update_used_stats info Dead_non_pure
      | _ -> ())
      ident_use_stats;
    Hashtbl.clear ident_use_stats (* clear to make it re-entrant *)

  method! program x = 
    export_set <- x.export_set ; 
    name <- x.name;
    super#program x 

  method! ident x = 
    self#mark_not_dead x ; self 

  method! variable_declaration vd =  
    match vd with 
    | { ident_info = {used_stats = Dead_pure } ; _}
      -> self
    | { ident_info = {used_stats = Dead_non_pure } ; value } -> 
      begin match value with
      | None -> self
      | Some x -> self#expression x 
      end
    | {ident; ident_info ; value ; _} -> 
      let pure = 
        match value with 
        | None  -> false 
        | Some x -> ignore (self#expression x); J_helper.no_side_effect x in
      self#scan pure ident ident_info; self
end

let mark_dead_code js = 
  let _ =  (mark_dead#program js) in 
  mark_dead#promote_dead;
  js
        
(*
   when we do optmizations, we might need track it will break invariant 
   of other optimizations, especially for [mutable] meta data, 
   for example, this pass will break [closure] information, 
   it should be done before closure pass (even it does not use closure information)

   Take away, it is really hard to change the code while collecting some information..
   we should always collect info in a single pass
 *)
let subst_map = object (self)
  inherit Js_map.map as super

  val mutable substitution = Hashtbl.create 17 

  method get_substitution = substitution

  method add_substitue (ident : Ident.t) (e:J.expression) = 
    Hashtbl.replace  substitution ident e

  method! statement v = 
    match v.statement_desc with 
    | Variable ({ident; ident_info = {used_stats = Dead_pure } ; _}) -> 
      {v with statement_desc = Block []}
    | Variable ({ident; ident_info = {used_stats = Dead_non_pure } ; value = None}) -> 
      {v with statement_desc = Block []}
    | Variable ({ident; ident_info = {used_stats = Dead_non_pure } ; value = Some x}) -> 
      {v with statement_desc =  (Exp x)}

    | Variable ({ ident ; 
                  property = Immutable;
                  value = Some ({expression_desc = (Array ( _:: _ :: _ as ls, Immutable))} as array)
                } as variable) -> 
      (** If we do this, we should prevent incorrect inlning to inline it into an array :) 
          do it only when block size is larger than one
      *)
      let bindings = ref [] in
      let e = List.mapi (fun i (x : J.expression) ->
          match x.expression_desc with
          | J.Var _ | Number _ | Str _ -> x
          | _ ->
            (* tradeoff, 
                when the block is small, it does not make 
                sense too much -- 
                bottomline, when the block size is one, no need to do 
                this
            *)
            let v' = self#expression x in
            let match_id =
              Ext_ident.create
                (Printf.sprintf "%s_%03d"
                   ident.name i) in
            bindings := (match_id , v') :: !bindings;
            E.var match_id
        ) ls in
      let e = {array with expression_desc = Array(e, Immutable)} in
        let () = self#add_substitue ident e in
        let bindings =  !bindings in
        let original_statement = {v with statement_desc = 
           Variable {variable with value =  Some   e }
        } in
        begin match bindings with 
        | [] -> 
            original_statement
        | _ ->  
            self#add_substitue ident e ;
            S.block @@
              (Ext_list.rev_map_acc [original_statement] (fun (id,v) -> 
                S.define ~kind:Strict id v)  bindings  )
        end
    | _ -> super#statement v 

  method! expression x =
    match x.expression_desc with 
    | Access ({expression_desc = Var (Id (id))}, 
              {expression_desc = Number (Int {i; _})}) -> 
      begin match Hashtbl.find self#get_substitution id with 
        | {expression_desc = Array (ls, Immutable) } 
          -> 
          begin match List.nth ls i with 
            | {expression_desc = J.Var _ | Number _ | Str _ } as x 
              -> x 
            | _ -> 
              (** we can do here, however, we should 
                  be careful that it can only be done 
                  when it's accessed once and the array is not escaped,
                  otherwise, we redo the computation,
                  or even better, we re-order

                  {[
                    var match = [/* tuple */0,Pervasives.string_of_int(f(1,2,3)),f3(2),arr];

                        var a = match[1];

                          var b = match[2];

                  ]}

                  --->

                  {[
                    var match$1 = Pervasives.string_of_int(f(1,2,3));
                        var match$2 = f3(2);
                            var match = [/* tuple */0,match$1,match$2,arr];
                                var a = match$1;
                                  var b = match$2;
                                    var arr = arr; 
                  ]}

                  --> 
                  since match$1 (after match is eliminated) is only called once 
                  {[
                    var a = Pervasives.string_of_int(f(1,2,3));
                    var b = f3(2);
                    var arr = arr; 
                  ]}

              *)
              super#expression x 
          end
        | _ -> super#expression x 
        | exception Not_found -> super#expression x 
      end
    | _ -> super#expression x
end 

(* Top down or bottom up ?*)
(* A pass to support nullary argument in JS 
    Nullary information can be done in one pass, 
    there is no need to add another pass
 *)

let program  js = 
  js 
  |> subst_map#program
  |> mark_dead_code
  (* |> mark_dead_code *)
  (* mark dead code twice does have effect in some cases, however, we disabled it 
    since the benefit is not obvious
   *)