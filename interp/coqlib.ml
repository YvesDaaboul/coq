(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Errors
open Util
open Pp
open Names
open Term
open Libnames
open Globnames
open Nametab
open Smartlocate
open Summary
open Evarutil
open Typeclasses

(************************************************************************)
(* Generic functions to find Coq objects *)

type message = string

let make_dir l = make_dirpath (List.map id_of_string (List.rev l))

let find_reference locstr dir s =
  let sp = Libnames.make_path (make_dir dir) (id_of_string s) in
  try global_of_extended_global (Nametab.extended_global_of_path sp)
  with Not_found -> anomaly (locstr^": cannot find "^(string_of_path sp))

let coq_reference locstr dir s = find_reference locstr ("Coq"::dir) s
let coq_constant locstr dir s = constr_of_global (coq_reference locstr dir s)

let gen_reference = coq_reference
let gen_constant = coq_constant

let has_suffix_in_dirs dirs ref =
  let dir = dirpath (path_of_global ref) in
  List.exists (fun d -> is_dirpath_prefix_of d dir) dirs

let global_of_extended q =
  try Some (global_of_extended_global q) with Not_found -> None

let gen_constant_in_modules locstr dirs s =
  let dirs = List.map make_dir dirs in
  let qualid = qualid_of_string s in
  let all = Nametab.locate_extended_all qualid in
  let all = List.uniquize (List.map_filter global_of_extended all) in
  let these = List.filter (has_suffix_in_dirs dirs) all in
  match these with
    | [x] -> constr_of_global x
    | [] ->
	anomalylabstrm "" (str (locstr^": cannot find "^s^
	" in module"^(if List.length dirs > 1 then "s " else " ")) ++
	prlist_with_sep pr_comma pr_dirpath dirs)
    | l ->
	anomalylabstrm ""
	(str (locstr^": found more than once object of name "^s^
	" in module"^(if List.length dirs > 1 then "s " else " ")) ++
	prlist_with_sep pr_comma pr_dirpath dirs)


(* For tactics/commands requiring vernacular libraries *)

let check_required_library d =
  let d' = List.map id_of_string d in
  let dir = make_dirpath (List.rev d') in
  let mp = (fst(Lib.current_prefix())) in
  let current_dir = match mp with
    | MPfile dp -> dir_path_eq dir dp
    | _ -> false
  in
  if not (Library.library_is_loaded dir) then
    if not current_dir then
(* Loading silently ...
    let m, prefix = List.sep_last d' in
    read_library
     (Loc.ghost,make_qualid (make_dirpath (List.rev prefix)) m)
*)
(* or failing ...*)
      error ("Library "^(string_of_dirpath dir)^" has to be required first.")

(************************************************************************)

(** Signature of a logic. Needs to be completed! *)
type coq_logic = {
  (** The False proposition *)
  log_False : constr;

  (** The True proposition and its unique proof *)
  log_True : constr;
  log_I : constr;

  (** The "minimal sort" containing both True and False *)
  log_bottom_sort : sorts;

  (** Negation *)
  log_not : constr;

  (** Conjunction *)
  log_and : constr;
  log_conj : constr;
  log_iff : constr;
  log_iff_left : constr;
  log_iff_right : constr;

  (** Disjunction *)
  log_or : constr;

  (** Existential quantifier *)
  log_ex : constr
}

type logic_id = sorts

let pos_in_ctxt label ctxt =
  let na = Name(id_of_string label) in
  let ids (id,bd,_) = match bd with None -> Some id | _ -> None in
  (* List.index is based at 1! *)
  List.index na (List.rev (CList.map_filter ids ctxt)) - 1

let full_logic_info = lazy
  (let cls = coq_reference "find_equality" ["Init";"LogicClasses"] "full_logic" in
   let cl = Typeclasses.class_info cls in
   let cl_ctxt = snd cl.cl_context in
   let kind_pos = 0 in
   let build_record args =
     match args with
	 [|kind; _logic;
	   tr; fa; tkind; iff; conj; disj; neg; i; ifflr; iffrl; conjI; _propositional;
           ex; _fo_logic |] ->
	   let tkind =
	     if isSort tkind then destSort tkind else
	       error "Instance of coq_full_logic expects a sort at field trivial_kind." in
	   {log_False=fa;log_True=tr;log_I=i;
	    log_bottom_sort=tkind; log_not=neg; log_and=conj; log_conj=conjI;
	    log_iff=iff; log_iff_left=ifflr; log_iff_right=iffrl; log_or=disj;
	    log_ex=ex }
       | _ -> anomaly "Coqlib.find_logic: typeclass coq_full_logic has wrong arity" in
   (cls,cl_ctxt,build_record,kind_pos))

let find_all_logics () =
  (* Retrieve data about the 'full_logic' class *)
  let (cls,cl_ctxt,build_record,kind_pos) = Lazy.force full_logic_info in
  let inst = Typeclasses.instances cls in
  let env = Global.env() in
  let build i =
    let ty = Retyping.get_type_of env Evd.empty (constr_of_global (instance_impl i)) in
    build_record (snd (destApp ty)) in
  List.map build inst

let search_logic found =
  CList.map_filter
    (fun l -> if found l then Some l else None)
    (find_all_logics())

let find_logic env eid =
  (* Retrieve data about the 'full_logic' class *)
  let (cls,cl_ctxt,build_record,kind_pos) = Lazy.force full_logic_info in
  (* Generate pattern (full_logic _ _ ... _) *)
  let (evd,inst,_) =
    evar_instance_of_context
      Evd.empty (Environ.named_context_val env) cl_ctxt in
  let pb = mkApp(constr_of_global cls,inst) in
  (* If given, try to define the evar corresponding to the 'X' arg *)
  let evd =
    match eid with
	Some k ->
	  (try Evarconv.the_conv_x env inst.(kind_pos) (mkSort k) evd
	   with Reduction.NotConvertible -> raise Not_found)
      | None -> evd in
  (* Perform the proof search. We drop the solution (which contains no
     information anyway).
     We are only interested in solving the evars argument of full_eq_logic. *)
  let (evd,_sol) = resolve_one_typeclass env evd pb in
  (* If some evars remained unsolved, then fail. (Otherwise we may return an eq structure
     containing evars refering to evd, but this evd is not returned to the caller.) *)
  if Evd.has_undefined evd then raise Not_found;
  (* Building the structure out of the raw array of arguments. *)
  build_record (Array.map (nf_evar evd) inst)


(************************************************************************)

(* Equalities *)
type coq_eq_data = {
  eq   : constr;
  ind  : constr;
  refl : constr;
  sym  : constr;
  trans: constr;
  congr: constr }

(* Data needed for discriminate and injection *)
type coq_inversion_data = {
  inv_eq   : constr; (* : forall params, t -> Prop *)
  inv_ind  : constr; (* : forall params P y, eq params y -> P y *)
  inv_congr: constr  (* : forall params B (f:t->B) y, eq params y -> f c=f y *)
}

(* Equalities are propositions, so we also need a logic at hand if we want to
   build compound propositions involving equalities *)
type coq_equality = {
  eq_logic : coq_logic;
  eq_data : coq_eq_data;
  eq_inv : coq_inversion_data delayed
}

(** Equalities are identified by the connective (eq,identity,etc.) *)
type equality_id = constr

(*
let typeclass_search (clslib,cls) =
  let clsrf = coq_reference ("find_class("^cls^")") clslib cls in
  let cl = Typeclasses.class_info cls in
  let cl_ctxt = snd cl.cl_context in
  let (_,lid) = Sign.fold_rel_context
    (fun (na,b,_) (n,l) ->
      match (na,b) with
	| _,Some _ -> (n,l)
	| Anonymous,None -> (n+1,l)
	| Name id,None -> (n+1,(string_of_id id,n))) cl_ctxt ~init:(0,[]) in
  if labels <> lid then
    anomaly ("Class '"^cls^"' does not have the expected parameters.");
  (cl_ctxt,lid)
*)
  
(* Lazily compute relevant info about the full_eq_logic typeclass *)
let full_eq_logic_info = lazy
  (let cls = coq_reference "find_equality" ["Init";"LogicClasses"] "full_eq_logic" in
   let cl = Typeclasses.class_info cls in
   let cl_ctxt = snd cl.cl_context in
   (* Position of 'eq' within the argument list *)
   let eqpos =
     try pos_in_ctxt "eq" cl_ctxt
     with Not_found -> anomaly "Class full_eq_logic should have an argument named 'eq'." in
   (* Building the structure from the list of arguments *)
   let build_record args =
     match args with
	 [|kind; _logic;
	   tr; fa; tkind; iff; conj; disj; neg; i; ifflr; iffrl; conjI; _propositional;
           ex; _fo_logic;
	   eq; ind; refl; sym; trans; congr; _eq_logic|] ->
	   let tkind =
	     if isSort tkind then destSort tkind else
	       error "Instance of coq_full_logic expects a sort at field trivial_kind." in
	   {eq_logic={log_False=fa;log_True=tr;log_I=i;
		      log_bottom_sort=tkind; log_not=neg; log_and=conj; log_conj=conjI;
		      log_iff=iff; log_iff_left=ifflr; log_iff_right=iffrl; log_or=disj;
		      log_ex=ex };
	    eq_data={eq=eq;ind=ind;refl=refl;sym=sym;trans=trans;congr=congr};
	    eq_inv=(fun()->failwith"find_equality: not implemented")}
       | _ -> anomaly "Coqlib.find_equality: typeclass coq_full_logic has wrong arity" in
   (cls,cl_ctxt,build_record,eqpos))

let find_all_equalities () =
  (* Retrieve data about the 'full_eq_logic' class *)
  let (cls,cl_ctxt,build_record,eqpos) = Lazy.force full_eq_logic_info in
  let inst = Typeclasses.instances cls in
  let env = Global.env() in
  let build i =
    let ty = Retyping.get_type_of env Evd.empty (constr_of_global (instance_impl i)) in
    build_record (snd(destApp ty)) in
  List.map build inst

let find_equality env eid =
  (* Retrieve data about the 'full_eq_logic' class *)
  let (cls,cl_ctxt,build_record,eqpos) = Lazy.force full_eq_logic_info in
  (* Generate pattern (full_eq_logic _ _ ... _) *)
  let (evd,inst,_) =
    evar_instance_of_context
      Evd.empty (Environ.named_context_val env) cl_ctxt in
  let pb = mkApp(constr_of_global cls,inst) in
  (* If given, try to define the evar corresponding to the 'eq' arg
     (position 16) *)
  let evd =
    match eid with
	Some eq ->
	  (try Evarconv.the_conv_x env inst.(eqpos) eq evd
	   with Reduction.NotConvertible -> raise Not_found)
      | None -> evd in
  (* Perform the proof search. We drop the solution (which contains no information).
     We are only interested in solving the evars argument of full_eq_logic. *)
  let (evd,_sol) = resolve_one_typeclass env evd pb in
  (* If some evars remained unsolved, then fail. Is it necessary ? *)
  if Evd.has_undefined evd then raise Not_found;
  (* Building the structure out of the raw array of arguments. *)
  build_record (Array.map (nf_evar evd) inst)

(* Alternative def, probably much more efficient, but not as general...
   Also, we may have better control on which instance is tried first. *)
let find_equality_alt eid =
  (* Retrieve data about the 'full_eq_logic' class *)
  let (cls,cl_ctxt,build_record,eqpos) = Lazy.force full_eq_logic_info in
  let inst = Typeclasses.instances cls in
  let env = Global.env() in
  let found =
    match eid with
      | None -> (fun _ -> true)
      | Some eq -> (fun args -> eq_constr args.(eqpos) eq) in
  let rec find l =
    match l with
	[] -> raise Not_found
      | i::l ->
	let ty = Retyping.get_type_of env Evd.empty (constr_of_global (instance_impl i)) in
	let args = snd (destApp ty) in
	if found args then build_record args else find l in
  find inst


let search_equality found =
  CList.map_filter
    (fun e -> if found e then Some e else None)
    (find_all_equalities())

(************************************************************************)
(* Specific Coq objects *)

let init_reference dir s = gen_reference "Coqlib" ("Init"::dir) s

let init_constant dir s = gen_constant "Coqlib" ("Init"::dir) s

let logic_constant dir s = gen_constant "Coqlib" ("Logic"::dir) s

let arith_dir = ["Coq";"Arith"]
let arith_modules = [arith_dir]

let numbers_dir = [ "Coq";"Numbers"]
let parith_dir = ["Coq";"PArith"]
let narith_dir = ["Coq";"NArith"]
let zarith_dir = ["Coq";"ZArith"]

let zarith_base_modules = [numbers_dir;parith_dir;narith_dir;zarith_dir]

let init_dir = ["Coq";"Init"]
let init_modules = [
  init_dir@["Datatypes"];
  init_dir@["Logic"];
  init_dir@["Specif"];
  init_dir@["Logic_Type"];
  init_dir@["Peano"];
  init_dir@["Wf"]
]

let logic_type_module_name = ["Coq";"Init";"Logic_Type"]
let logic_type_module = make_dir logic_type_module_name

let datatypes_module_name = ["Coq";"Init";"Datatypes"]
let datatypes_module = make_dir datatypes_module_name

let arith_module_name = ["Coq";"Arith";"Arith"]
let arith_module = make_dir arith_module_name

(* TODO: temporary hack *)
let make_kn dir id = Globnames.encode_mind dir id
let make_con dir id = Globnames.encode_con dir id

(** Identity *)

let id = make_con datatypes_module (id_of_string "id")
let type_of_id = make_con datatypes_module (id_of_string "ID")

let _ = Termops.set_impossible_default_clause (mkConst id,mkConst type_of_id)

(** Natural numbers *)
let nat_kn = make_kn datatypes_module (id_of_string "nat")
let nat_path = Libnames.make_path datatypes_module (id_of_string "nat")

let glob_nat = IndRef (nat_kn,0)

let path_of_O = ((nat_kn,0),1)
let path_of_S = ((nat_kn,0),2)
let glob_O = ConstructRef path_of_O
let glob_S = ConstructRef path_of_S

(** Booleans *)
let bool_kn = make_kn datatypes_module (id_of_string "bool")

let glob_bool = IndRef (bool_kn,0)

let path_of_true = ((bool_kn,0),1)
let path_of_false = ((bool_kn,0),2)
let glob_true  = ConstructRef path_of_true
let glob_false  = ConstructRef path_of_false

type coq_sigma_data = {
  proj1 : constr;
  proj2 : constr;
  elim  : constr;
  intro : constr;
  typ   : constr }

type coq_bool_data  = {
  andb : constr;
  andb_prop : constr;
  andb_true_intro : constr}

let build_bool_type () =
  { andb =  init_constant ["Datatypes"] "andb";
    andb_prop =  init_constant ["Datatypes"] "andb_prop";
    andb_true_intro =  init_constant ["Datatypes"] "andb_true_intro" }

let build_sigma_type () =
  { proj1 = init_constant ["Specif"] "projT1";
    proj2 = init_constant ["Specif"] "projT2";
    elim = init_constant ["Specif"] "sigT_rect";
    intro = init_constant ["Specif"] "existT";
    typ = init_constant ["Specif"] "sigT" }

let build_prod () =
  { proj1 = init_constant ["Datatypes"] "fst";
    proj2 = init_constant ["Datatypes"] "snd";
    elim = init_constant ["Datatypes"] "prod_rec";
    intro = init_constant ["Datatypes"] "pair";
    typ = init_constant ["Datatypes"] "prod" }

let lazy_init_constant dir id = lazy (init_constant dir id)
let lazy_logic_constant dir id = lazy (logic_constant dir id)


(* Specif *)
let coq_sumbool  = lazy_init_constant ["Specif"] "sumbool"

let build_coq_sumbool () = Lazy.force coq_sumbool

(* The following is less readable but does not depend on parsing *)
let coq_existT_ref  = lazy (init_reference ["Specif"] "existT")



module Std = struct

let logic_module_name = ["Coq";"Init";"Logic"]
let logic_module = make_dir logic_module_name

let jmeq_module_name = ["Coq";"Logic";"JMeq"]
let jmeq_module = make_dir jmeq_module_name

let build_sigma_set () = anomaly "Use build_sigma_type"

let build_sigma () =
  { proj1 = init_constant ["Specif"] "proj1_sig";
    proj2 = init_constant ["Specif"] "proj2_sig";
    elim = init_constant ["Specif"] "sig_rect";
    intro = init_constant ["Specif"] "exist";
    typ = init_constant ["Specif"] "sig" }


(* The False proposition *)
let coq_False  = lazy_init_constant ["Logic"] "False"

(* The True proposition and its unique proof *)
let coq_True   = lazy_init_constant ["Logic"] "True"
let coq_I      = lazy_init_constant ["Logic"] "I"

(* Connectives *)
let coq_not = lazy_init_constant ["Logic"] "not"
let coq_and = lazy_init_constant ["Logic"] "and"
let coq_conj = lazy_init_constant ["Logic"] "conj"
let coq_or = lazy_init_constant ["Logic"] "or"
let coq_ex = lazy_init_constant ["Logic"] "ex"
let coq_iff = lazy_init_constant ["Logic"] "iff"

let coq_iff_left_proj  = lazy_init_constant ["Logic"] "proj1"
let coq_iff_right_proj = lazy_init_constant ["Logic"] "proj2"

let build_coq_True ()  = Lazy.force coq_True
let build_coq_I ()     = Lazy.force coq_I

let build_coq_False () = Lazy.force coq_False
let build_coq_not ()   = Lazy.force coq_not

let build_coq_and ()   = Lazy.force coq_and
let build_coq_conj ()  = Lazy.force coq_conj
let build_coq_iff ()   = Lazy.force coq_iff

let build_coq_iff_left_proj ()  = Lazy.force coq_iff_left_proj
let build_coq_iff_right_proj () = Lazy.force coq_iff_right_proj

let build_coq_or ()    = Lazy.force coq_or
let build_coq_ex ()    = Lazy.force coq_ex

let coq_eq_ref      = lazy (init_reference ["Logic"] "eq")
let coq_identity_ref = lazy (init_reference ["Datatypes"] "identity")
let coq_jmeq_ref     = lazy (gen_reference "Coqlib" ["Logic";"JMeq"] "JMeq")
let coq_eq_true_ref = lazy (gen_reference "Coqlib" ["Init";"Datatypes"] "eq_true")
let coq_existS_ref  = lazy (anomaly "use coq_existT_ref")
let coq_exist_ref  = lazy (init_reference ["Specif"] "exist")
let coq_not_ref     = lazy (init_reference ["Logic"] "not")
let coq_False_ref   = lazy (init_reference ["Logic"] "False")
let coq_sumbool_ref = lazy (init_reference ["Specif"] "sumbool")
let coq_sig_ref = lazy (init_reference ["Specif"] "sig")
let coq_or_ref     = lazy (init_reference ["Logic"] "or")
let coq_iff_ref    = lazy (init_reference ["Logic"] "iff")

let prop_logic() = {
  log_False = build_coq_False();
  log_True = build_coq_True();
  log_I = build_coq_I();
  log_bottom_sort = Prop Null;
  log_not = build_coq_not();
  log_and = build_coq_and();
  log_conj = build_coq_conj();
  log_iff = build_coq_iff();
  log_iff_left = build_coq_iff_left_proj();
  log_iff_right = build_coq_iff_right_proj();
  log_or = build_coq_or();
  log_ex = build_coq_ex()
}

(** Equality *)
let eq_kn = make_kn logic_module (id_of_string "eq")
let glob_eq = IndRef (eq_kn,0)

let identity_kn = make_kn datatypes_module (id_of_string "identity")
let glob_identity = IndRef (identity_kn,0)

let jmeq_kn = make_kn jmeq_module (id_of_string "JMeq")
let glob_jmeq = IndRef (jmeq_kn,0)

(* Leibniz equality on Type *)

let coq_eq_eq = lazy_init_constant ["Logic"] "eq"
let coq_eq_refl = lazy_init_constant ["Logic"] "eq_refl"
let coq_eq_ind = lazy_init_constant ["Logic"] "eq_ind"
let coq_eq_congr = lazy_init_constant ["Logic"] "f_equal"
let coq_eq_sym  = lazy_init_constant ["Logic"] "eq_sym"
let coq_eq_trans  = lazy_init_constant ["Logic"] "eq_trans"
let coq_f_equal2 = lazy_init_constant ["Logic"] "f_equal2"
let coq_eq_congr_canonical =
  lazy_init_constant ["Logic"] "f_equal_canonical_form"

let build_coq_eq_data () =
  let _ = check_required_library logic_module_name in {
  eq = Lazy.force coq_eq_eq;
  ind = Lazy.force coq_eq_ind;
  refl = Lazy.force coq_eq_refl;
  sym = Lazy.force coq_eq_sym;
  trans = Lazy.force coq_eq_trans;
  congr = Lazy.force coq_eq_congr }

let build_coq_eq () = Lazy.force coq_eq_eq
let build_coq_eq_refl () = Lazy.force coq_eq_refl
let build_coq_eq_sym () = Lazy.force coq_eq_sym
let build_coq_f_equal2 () = Lazy.force coq_f_equal2

let build_coq_inversion_eq_data () =
  let _ = check_required_library logic_module_name in {
  inv_eq = Lazy.force coq_eq_eq;
  inv_ind = Lazy.force coq_eq_ind;
  inv_congr = Lazy.force coq_eq_congr_canonical }


(* Equality on Type as a Type *)
let coq_identity_eq = lazy_init_constant ["Datatypes"] "identity"
let coq_identity_refl = lazy_init_constant ["Datatypes"] "identity_refl"
let coq_identity_ind = lazy_init_constant ["Datatypes"] "identity_ind"
let coq_identity_congr = lazy_init_constant ["Logic_Type"] "identity_congr"
let coq_identity_sym = lazy_init_constant ["Logic_Type"] "identity_sym"
let coq_identity_trans = lazy_init_constant ["Logic_Type"] "identity_trans"
let coq_identity_congr_canonical = lazy_init_constant ["Logic_Type"] "identity_congr_canonical_form"

let build_coq_identity_data () =
  let _ = check_required_library datatypes_module_name in {
  eq = Lazy.force coq_identity_eq;
  ind = Lazy.force coq_identity_ind;
  refl = Lazy.force coq_identity_refl;
  sym = Lazy.force coq_identity_sym;
  trans = Lazy.force coq_identity_trans;
  congr = Lazy.force coq_identity_congr }

let build_coq_inversion_identity_data () =
  let _ = check_required_library datatypes_module_name in
  let _ = check_required_library logic_type_module_name in {
  inv_eq = Lazy.force coq_identity_eq;
  inv_ind = Lazy.force coq_identity_ind;
  inv_congr = Lazy.force coq_identity_congr_canonical }


(* Heterogenous equality on Type *)

let coq_jmeq_eq = lazy_logic_constant ["JMeq"] "JMeq"
let coq_jmeq_refl = lazy_logic_constant ["JMeq"] "JMeq_refl"
let coq_jmeq_ind = lazy_logic_constant ["JMeq"] "JMeq_ind"
let coq_jmeq_sym  = lazy_logic_constant ["JMeq"] "JMeq_sym"
let coq_jmeq_congr  = lazy_logic_constant ["JMeq"] "JMeq_congr"
let coq_jmeq_trans  = lazy_logic_constant ["JMeq"] "JMeq_trans"
let coq_jmeq_congr_canonical =
  lazy_logic_constant ["JMeq"] "JMeq_congr_canonical_form"

let build_coq_jmeq_data () =
  let _ = check_required_library jmeq_module_name in {
  eq = Lazy.force coq_jmeq_eq;
  ind = Lazy.force coq_jmeq_ind;
  refl = Lazy.force coq_jmeq_refl;
  sym = Lazy.force coq_jmeq_sym;
  trans = Lazy.force coq_jmeq_trans;
  congr = Lazy.force coq_jmeq_congr }

let join_jmeq_types eq =
  mkLambda(Name (id_of_string "A"),Termops.new_Type(),
  mkLambda(Name (id_of_string "x"),mkRel 1,
  mkApp (eq,[|mkRel 2;mkRel 1;mkRel 2|])))

let build_coq_inversion_jmeq_data () =
  let _ = check_required_library logic_module_name in {
  inv_eq = join_jmeq_types (Lazy.force coq_jmeq_eq);
  inv_ind = Lazy.force coq_jmeq_ind;
  inv_congr = Lazy.force coq_jmeq_congr_canonical }


let build_coq_jmeq_full () =
  { eq_logic = prop_logic();
    eq_data = build_coq_jmeq_data();
    eq_inv = build_coq_inversion_jmeq_data }

(* Equality to true *)
let coq_eq_true_eq = lazy_init_constant ["Datatypes"] "eq_true"
let coq_eq_true_ind = lazy_init_constant ["Datatypes"] "eq_true_ind"
let coq_eq_true_congr = lazy_init_constant ["Logic"] "eq_true_congr"

let build_coq_inversion_eq_true_data () =
  let _ = check_required_library datatypes_module_name in
  let _ = check_required_library logic_module_name in {
  inv_eq = Lazy.force coq_eq_true_eq;
  inv_ind = Lazy.force coq_eq_true_ind;
  inv_congr = Lazy.force coq_eq_true_congr }



end
