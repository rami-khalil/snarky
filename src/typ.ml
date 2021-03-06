open Core_kernel

type ('var, 'value, 'field) t = ('var, 'value, 'field) Types.Typ.t

type ('var, 'value, 'field) typ = ('var, 'value, 'field) t

module Data_spec = struct
  (** A list of {!type:Type.Typ.t} values, describing the inputs to a checked
      computation. The type [('r_var, 'r_value, 'k_var, 'k_value, 'field) t]
      represents
      - ['k_value] is the OCaml type of the computation
      - ['r_value] is the OCaml type of the result
      - ['k_var] is the type of the computation within the R1CS
      - ['k_value] is the type of the result within the R1CS
      - ['field] is the field over which the R1CS operates.

      This functions the same as OCaml's default list type:
{[
  Data_spec.[typ1; typ2; typ3]

  Data_spec.(typ1 :: typs)

  let open Data_spec in
  [typ1; typ2; typ3; typ4; typ5]

  let open Data_spec in
  typ1 :: typ2 :: typs

]}
      all function as you would expect.
  *)
  type ('r_var, 'r_value, 'k_var, 'k_value, 'f) t =
    | ( :: ) :
        ('var, 'value, 'f) typ * ('r_var, 'r_value, 'k_var, 'k_value, 'f) t
        -> ('r_var, 'r_value, 'var -> 'k_var, 'value -> 'k_value, 'f) t
    | [] : ('r_var, 'r_value, 'r_var, 'r_value, 'f) t

  let size t =
    let rec go : type r_var r_value k_var k_value.
        int -> (r_var, r_value, k_var, k_value, 'f) t -> int =
     fun acc t ->
      match t with
      | [] -> acc
      | {alloc; _} :: t' -> go (acc + Typ_monads.Alloc.size alloc) t'
    in
    go 0 t
end

module T = struct
  open Types.Typ
  open Typ_monads

  let store ({store; _} : ('var, 'value, 'field) t) (x : 'value) :
      ('var, 'field) Store.t =
    store x

  let read ({read; _} : ('var, 'value, 'field) t) (v : 'var) :
      ('value, 'field) Read.t =
    read v

  let alloc ({alloc; _} : ('var, 'value, 'field) t) : ('var, 'field) Alloc.t =
    alloc

  let check (type field) ({check; _} : ('var, 'value, field) t) (v : 'var) :
      (unit, 's, field) Types.Checked.t =
    let do_nothing : (unit, field, _) As_prover0.t = fun _ s -> (s, ()) in
    With_state (do_nothing, (fun () -> do_nothing), check v, Checked.return)

  let unit () : (unit, unit, 'field) t =
    let s = Store.return () in
    let r = Read.return () in
    let c = Checked.return () in
    { store= (fun () -> s)
    ; read= (fun () -> r)
    ; check= (fun () -> c)
    ; alloc= Alloc.return () }

  let field () : ('field Cvar.t, 'field, 'field) t =
    { store= Store.store
    ; read= Read.read
    ; alloc= Alloc.alloc
    ; check= (fun _ -> Checked.return ()) }

  let transport ({read; store; alloc; check} : ('var1, 'value1, 'field) t)
      ~(there : 'value2 -> 'value1) ~(back : 'value1 -> 'value2) :
      ('var1, 'value2, 'field) t =
    { alloc
    ; store= (fun x -> store (there x))
    ; read= (fun v -> Read.map ~f:back (read v))
    ; check }

  let transport_var ({read; store; alloc; check} : ('var1, 'value, 'field) t)
      ~(there : 'var2 -> 'var1) ~(back : 'var1 -> 'var2) :
      ('var2, 'value, 'field) t =
    { alloc= Alloc.map alloc ~f:back
    ; store= (fun x -> Store.map (store x) ~f:back)
    ; read= (fun x -> read (there x))
    ; check= (fun x -> check (there x)) }

  let list ~length
      ({read; store; alloc; check} : ('elt_var, 'elt_value, 'field) t) :
      ('elt_var list, 'elt_value list, 'field) t =
    let store ts =
      let n = List.length ts in
      if n <> length then
        failwithf "Typ.list: Expected length %d, got %d" length n () ;
      Store.all (List.map ~f:store ts)
    in
    let alloc = Alloc.all (List.init length ~f:(fun _ -> alloc)) in
    let check ts = Checked.all_unit (List.map ts ~f:check) in
    let read vs = Read.all (List.map vs ~f:read) in
    {read; store; alloc; check}

  (* TODO-someday: Make more efficient *)
  let array ~length
      ({read; store; alloc; check} : ('elt_var, 'elt_value, 'field) t) :
      ('elt_var array, 'elt_value array, 'field) t =
    let store ts =
      assert (Array.length ts = length) ;
      Store.map ~f:Array.of_list
        (Store.all (List.map ~f:store (Array.to_list ts)))
    in
    let alloc =
      let open Alloc.Let_syntax in
      let%map vs = Alloc.all (List.init length ~f:(fun _ -> alloc)) in
      Array.of_list vs
    in
    let read vs =
      assert (Array.length vs = length) ;
      Read.map ~f:Array.of_list
        (Read.all (List.map ~f:read (Array.to_list vs)))
    in
    let check ts =
      assert (Array.length ts = length) ;
      let open Checked in
      let rec go i =
        if i = length then return ()
        else
          let%map () = check ts.(i) and () = go (i + 1) in
          ()
      in
      go 0
    in
    {read; store; alloc; check}

  let tuple2 (typ1 : ('var1, 'value1, 'field) t)
      (typ2 : ('var2, 'value2, 'field) t) :
      ('var1 * 'var2, 'value1 * 'value2, 'field) t =
    let alloc =
      let open Alloc.Let_syntax in
      let%map x = typ1.alloc and y = typ2.alloc in
      (x, y)
    in
    let read (x, y) =
      let open Read.Let_syntax in
      let%map x = typ1.read x and y = typ2.read y in
      (x, y)
    in
    let store (x, y) =
      let open Store.Let_syntax in
      let%map x = typ1.store x and y = typ2.store y in
      (x, y)
    in
    let check (x, y) =
      let open Checked in
      let%map () = typ1.check x and () = typ2.check y in
      ()
    in
    {read; store; alloc; check}

  let ( * ) = tuple2

  let tuple3 (typ1 : ('var1, 'value1, 'field) t)
      (typ2 : ('var2, 'value2, 'field) t) (typ3 : ('var3, 'value3, 'field) t) :
      ('var1 * 'var2 * 'var3, 'value1 * 'value2 * 'value3, 'field) t =
    let alloc =
      let open Alloc.Let_syntax in
      let%map x = typ1.alloc and y = typ2.alloc and z = typ3.alloc in
      (x, y, z)
    in
    let read (x, y, z) =
      let open Read.Let_syntax in
      let%map x = typ1.read x and y = typ2.read y and z = typ3.read z in
      (x, y, z)
    in
    let store (x, y, z) =
      let open Store.Let_syntax in
      let%map x = typ1.store x and y = typ2.store y and z = typ3.store z in
      (x, y, z)
    in
    let check (x, y, z) =
      let open Checked in
      let%map () = typ1.check x and () = typ2.check y and () = typ3.check z in
      ()
    in
    {read; store; alloc; check}

  let hlist (type k_var k_value)
      (spec0 : (unit, unit, k_var, k_value, 'f) Data_spec.t) :
      ((unit, k_var) H_list.t, (unit, k_value) H_list.t, 'f) t =
    let store xs0 : _ Store.t =
      let rec go : type k_var k_value.
             (unit, unit, k_var, k_value, 'f) Data_spec.t
          -> (unit, k_value) H_list.t
          -> ((unit, k_var) H_list.t, 'f) Store.t =
       fun spec0 xs0 ->
        let open H_list in
        match (spec0, xs0) with
        | [], [] -> Store.return H_list.[]
        | s :: spec, x :: xs ->
            let open Store.Let_syntax in
            let%map y = store s x and ys = go spec xs in
            y :: ys
      in
      go spec0 xs0
    in
    let read xs0 : ((unit, k_value) H_list.t, 'f) Read.t =
      let rec go : type k_var k_value.
             (unit, unit, k_var, k_value, 'f) Data_spec.t
          -> (unit, k_var) H_list.t
          -> ((unit, k_value) H_list.t, 'f) Read.t =
       fun spec0 xs0 ->
        let open H_list in
        match (spec0, xs0) with
        | [], [] -> Read.return H_list.[]
        | s :: spec, x :: xs ->
            let open Read.Let_syntax in
            let%map y = read s x and ys = go spec xs in
            y :: ys
      in
      go spec0 xs0
    in
    let alloc : _ Alloc.t =
      let rec go : type k_var k_value.
             (unit, unit, k_var, k_value, 'f) Data_spec.t
          -> ((unit, k_var) H_list.t, 'f) Alloc.t =
       fun spec0 ->
        let open H_list in
        match spec0 with
        | [] -> Alloc.return H_list.[]
        | s :: spec ->
            let open Alloc.Let_syntax in
            let%map y = alloc s and ys = go spec in
            y :: ys
      in
      go spec0
    in
    let check xs0 : (unit, unit, 'f) Types.Checked.t =
      let rec go : type k_var k_value.
             (unit, unit, k_var, k_value, 'f) Data_spec.t
          -> (unit, k_var) H_list.t
          -> (unit, unit, 'f) Types.Checked.t =
       fun spec0 xs0 ->
        let open H_list in
        let open Checked.Let_syntax in
        match (spec0, xs0) with
        | [], [] -> return ()
        | s :: spec, x :: xs ->
            let%map () = check s x and () = go spec xs in
            ()
      in
      go spec0 xs0
    in
    {read; store; alloc; check}

  (* TODO: Do a CPS style thing instead if it ends up being an issue converting
     back and forth. *)
  let of_hlistable (spec : (unit, unit, 'k_var, 'k_value, 'f) Data_spec.t)
      ~(var_to_hlist : 'var -> (unit, 'k_var) H_list.t)
      ~(var_of_hlist : (unit, 'k_var) H_list.t -> 'var)
      ~(value_to_hlist : 'value -> (unit, 'k_value) H_list.t)
      ~(value_of_hlist : (unit, 'k_value) H_list.t -> 'value) :
      ('var, 'value, 'f) t =
    let {read; store; alloc; check} = hlist spec in
    { read= (fun v -> Read.map ~f:value_of_hlist (read (var_to_hlist v)))
    ; store= (fun x -> Store.map ~f:var_of_hlist (store (value_to_hlist x)))
    ; alloc= Alloc.map ~f:var_of_hlist alloc
    ; check= (fun v -> check (var_to_hlist v)) }
end

include T
