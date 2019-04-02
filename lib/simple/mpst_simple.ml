module Dyncheck = Dyncheck

module LinMonad = LinMonad

type ('la,'lb,'va,'vb) label =
  {make_obj: 'va -> 'la;
   make_var: 'vb -> 'lb}

type ('lr, 'l, 'r) obj_merge =
  {obj_merge: 'l -> 'r -> 'lr}

type close = Close

let close Close = ()

type _ wrap =
  | WrapSend : (< .. > as 'obj) -> 'obj wrap
  | WrapRecv : ([>] as 'var) Event.event -> 'var Event.event wrap
  | WrapClose : close wrap
  | WrapGuard : 'a wrap lazy_t -> 'a wrap

exception UngardedLoop

let rec find_physeq : 'a. 'a list -> 'a -> bool = fun xs y ->
  match xs with
  | x::xs -> if x==y then true else find_physeq xs y
  | [] -> false
        
let rec remove_guards : type t. t wrap lazy_t list -> t wrap lazy_t -> t wrap = fun acc w ->
  if find_physeq acc w then
    raise UngardedLoop
  else begin match Lazy.force w with
       | WrapGuard w' ->
          remove_guards (w'::acc) w'
       | w -> w
       end
  
let rec unwrap : type t. t wrap -> t = function
  | WrapSend(obj) -> obj
  | WrapRecv(ev) -> ev
  | WrapClose -> Close
  | WrapGuard w ->
     let w = remove_guards [] w in
     unwrap w

type _ seq =
  Cons : 'hd wrap * 'tl seq -> ('hd * 'tl) seq
| Nil : unit seq

let seq_head : type hd tl. (hd * tl) seq -> hd wrap =
  fun (Cons(hd,_)) -> hd

let seq_tail : type hd tl. (hd * tl) seq -> tl seq = fun xs ->
  match xs with
  | Cons(_,tl) -> tl

type (_,_,_,_) lens =
  | Zero  : ('hd0, 'hd1, ('hd0 * 'tl) seq, ('hd1 * 'tl) seq) lens
  | Succ : ('a, 'b, 'tl0 seq, 'tl1 seq) lens
           -> ('a,'b, ('hd * 'tl0) seq, ('hd * 'tl1) seq) lens

let rec get : type a b xs ys. (a, b, xs, ys) lens -> xs -> a wrap = fun ln xs ->
  match ln with
  | Zero -> seq_head xs
  | Succ ln' -> get ln' (seq_tail xs)

let rec put : type a b xs ys. (a,b,xs,ys) lens -> xs -> b wrap -> ys =
  fun ln xs b ->
  match ln with
  | Zero -> Cons(b, seq_tail xs)
  | Succ ln' ->
     begin match xs with
     | Cons(a, xs') -> Cons(a, put ln' xs' b)
     end

type ('robj,'rvar,'c,'a,'b,'xs,'ys) role = {label:('robj,'rvar,'c,'c) label; lens:('a,'b,'xs,'ys) lens}


exception RoleNotEnabled

let rec wrap_merge : type s. s wrap -> s wrap -> s wrap = fun l r ->
  match l, r with
  | WrapSend _, WrapSend _ -> raise RoleNotEnabled
  | WrapRecv l, WrapRecv r -> WrapRecv (Event.choose [l; r])
  | WrapClose, WrapClose -> WrapClose
  | WrapGuard w1, w2 ->
     WrapGuard
       (let rec w =
          (lazy begin
               try
                 let w1 = remove_guards [w] w1 in
                 wrap_merge w1 w2
               with
                 UngardedLoop -> w2
             end)
        in w)
  | w1, ((WrapGuard _) as w2) -> wrap_merge w2 w1
  | _ -> assert false
                          
  (* | _, _ -> assert false (\* OCaml typechecker cannot check exhaustiveness in this case *\) *)

let rec seq_merge : type t.
    t seq -> t seq -> t seq =
  fun ls rs ->
  match ls, rs with
  | Cons(hd_l,tl_l), Cons(hd_r, tl_r) ->
     Cons(wrap_merge hd_l hd_r,
          seq_merge tl_l tl_r)
  | Nil, _ -> Nil
            
(* let goto l =
 *   lazy (Lazy.force @@ Lazy.force l) *)

let rec goto2 =fun xs ->
  Cons(WrapGuard(lazy (get Zero (Lazy.force xs))),
  Cons(WrapGuard(lazy (get (Succ Zero) (Lazy.force xs))),
  Nil))

let rec goto3 =fun xs ->
  Cons(WrapGuard(lazy (get Zero (Lazy.force xs))),
  Cons(WrapGuard(lazy (get (Succ Zero) (Lazy.force xs))),
  Cons(WrapGuard(lazy (get (Succ (Succ Zero)) (Lazy.force xs))),
  Nil)))

let rec goto4 =fun xs ->
  Cons(WrapGuard(lazy (get Zero (Lazy.force xs))),
  Cons(WrapGuard(lazy (get (Succ Zero) (Lazy.force xs))),
  Cons(WrapGuard(lazy (get (Succ (Succ Zero)) (Lazy.force xs))),
  Cons(WrapGuard(lazy (get (Succ (Succ (Succ Zero))) (Lazy.force xs))),
  Nil))))

let rec goto5 =fun xs ->
  Cons(WrapGuard(lazy (get Zero (Lazy.force xs))),
  Cons(WrapGuard(lazy (get (Succ Zero) (Lazy.force xs))),
  Cons(WrapGuard(lazy (get (Succ (Succ Zero)) (Lazy.force xs))),
  Cons(WrapGuard(lazy (get (Succ (Succ (Succ Zero))) (Lazy.force xs))),
  Cons(WrapGuard(lazy (get (Succ (Succ (Succ (Succ Zero)))) (Lazy.force xs))),
  Nil)))))
  

let one xs  = Cons(WrapClose, xs)
let nil = Nil

  
let a = {label={make_obj=(fun v->object method role_A=v end);
               make_var=(fun v->(`role_A(v):[`role_A of _]))}; (* explicit annotataion is mandatory *)
         lens=Zero}
let b = {label={make_obj=(fun v->object method role_B=v end);
               make_var=(fun v->(`role_B(v):[`role_B of _]))}; (* explicit annotataion is mandatory *)
         lens=Succ Zero}
let c = {label={make_obj=(fun v->object method role_C=v end);
               make_var=(fun v->(`role_C(v):[`role_C of _]))}; (* explicit annotataion is mandatory *)
         lens=Succ (Succ Zero)}
let msg =
  {make_obj=(fun f -> object method msg=f end);
   make_var=(fun v -> `msg(v))}
let left =
  {make_obj=(fun f -> object method left=f end);
   make_var=(fun v -> `left(v))}
let right =
  {make_obj=(fun f -> object method right=f end);
   make_var=(fun v -> `right(v))}
let left_or_right =
  {obj_merge=(fun l r -> object method left=l#left method right=r#right end)}
let to_b m =
  {obj_merge=(fun l r -> object method role_B=m.obj_merge l#role_B r#role_B end)}
let b_or_c =
  {obj_merge=(fun l r -> object method role_B=l#role_B method role_C=r#role_C end)}

(* let finish =
 *   let rec fini = lazy (Cons(Close, fini)) in
 *   Lazy.from_val (Lazy.force fini) *)

let get_ep r g = unwrap (get r.lens g)

let one xs = Cons(WrapClose, xs)
let nil = Nil

let finish2 = one @@ one @@ nil
let finish3 = one @@ one @@ one @@ nil
let finish4 = one @@ one @@ one @@ one @@ nil
let finish5 = one @@ one @@ one @@ one @@ one @@ nil

module type LIN = sig
  type 'a lin
  val mklin : 'a -> 'a lin
end

let put_ep r g ep = put r.lens g ep

let choice_at : 'ep 'ep_l 'ep_r 'g0_l 'g0_r 'g1 'g2.
  (_, _, _, close, < .. > as 'ep, 'g1 seq, 'g2 seq) role ->
  ('ep, < .. > as 'ep_l, < .. > as 'ep_r) obj_merge ->
  (_, _, _, 'ep_l, close, 'g0_l seq, 'g1 seq) role * 'g0_l seq ->
  (_, _, _, 'ep_r, close, 'g0_r seq, 'g1 seq) role * 'g0_r seq ->
  'g2 seq
  = fun r merge (r',g0left) (r'',g0right) ->
  let oleft, oright = get_ep r' g0left, get_ep r'' g0right in
  let g1left, g1right =
    put_ep r' g0left WrapClose, put_ep r'' g0right WrapClose in
  let g1 = seq_merge g1left g1right in
  let omerge = merge.obj_merge oleft oright in
  put_ep r g1 (WrapSend omerge)

module MakeGlobal(X:LIN) = struct

  let make_send rB lab ch epA =
    let method_ v =
      Event.sync (Event.send ch v);
      X.mklin (unwrap epA)
    in
    (* <role_rB : < lab : v -> epA > > *)
    rB.label.make_obj (lab.make_obj method_)

  let make_recv rA lab ch epB =
    let wrapvar v epB =
      (* [`role_rA of [`lab of v * epB ] ] *)
      rA.label.make_var
        (lab.make_var (v, X.mklin (unwrap epB)))
    in
    Event.wrap
      (Event.receive ch)
      (fun v -> wrapvar v epB)

  let ( --> ) rA rB label g0 =
    let ch = Event.new_channel ()
    in
    let epB = get rB.lens g0 in
    let ev  = make_recv rA label ch epB in
    let g1  = put_ep rB g0 (WrapRecv ev)
    in
    let epA = get rA.lens g1 in
    let obj = make_send rB label ch epA in
    let g2  = put_ep rA g1 (WrapSend obj)
    in g2
end

include MakeGlobal(struct type 'a lin = 'a let mklin x = x end)

module Lin : sig
  val ( --> ) :
    (_,  [>  ] as 'roleAvar, 'labelvar, 'epA, 'roleBobj,             'g1, 'g2) role ->
    (< .. > as 'roleBobj, _, 'labelobj, 'epB, 'roleAvar Event.event, 'g0, 'g1) role ->
    (< .. > as 'labelobj, [> ] as 'labelvar, 'v -> 'epA LinMonad.lin, 'v * 'epB LinMonad.lin) label ->
    'g0 -> 'g2

  type 'g global

  val create_shared : (unit -> 'g seq) -> [>] list -> 'g global

  val connect :
    'g global ->
    (_, _, unit, 's, _, 'g seq, _) role ->
    ('pre, 'pre, 's LinMonad.lin) LinMonad.monad

  open LinMonad

  val send :
    ((< .. > as 'obj) -> 'v data -> 's lin) ->
    'v ->
    ('obj lin, empty, 'pre, 'post) lens ->
    ('pre, 'post, 's lin) monad

  val deleg_send :
    ((< .. > as 'obj) -> 't lin -> 's lin) ->
    ('t lin, empty, 'pre, 'mid) lens ->
    ('obj lin, empty, 'mid, 'post) lens ->
    ('pre, 'post, 's lin) monad

  val receive :
    ('var Event.event lin, empty, 'pre, 'post) lens ->
    ('pre, 'post, 'var lin) monad

  val close :
    (close lin, empty, 'pre, 'post) lens ->
    ('pre, 'post, unit data) monad

end
  = struct
  module L = struct
    type 't lin = 't LinMonad.lin
    let mklin a = {LinMonad.__lindata=a}
  end

  module G = MakeGlobal(L)
  include G

  let stream_tee stream =
    failwith "TODO"

  type 'g global =
    {locals:(Obj.t * 'g seq Stream.t) list}

  let create_shared f rs =
    let st0 = Stream.from (fun _ -> Some (f ())) in
    match rs with
    | [] -> failwith "empty roles"
    | r::rs ->
       let st0, locals =
         List.fold_left
           (fun (st,xs) r ->
             let s1, s2 = stream_tee st in
             s2, (Obj.repr r, s1)::xs)
           (st0,[])
           rs
       in
       {locals=(Obj.repr r,st0)::locals}

  let connect {locals} r =
    {LinMonad.__run=
       fun pre->
       let st = List.assoc (Obj.repr (r.label.make_var ())) locals in
       Stream.next st |> (fun g ->
       (pre, {LinMonad.__lindata=unwrap @@ get r.lens g}))
    }

  let send sel v lens =
    let open LinMonad in
    {__run=
       fun pre ->
       let {__lindata=obj} = lens_get lens pre in
       let s = (sel obj {data=v}).__lindata in
       (lens_put lens pre Empty, {__lindata=s})
    }

  let deleg_send sel lens1 lens0 =
    let open LinMonad in
    {__run=
       fun pre ->
       let t = lens_get lens1 pre in
       let mid = lens_put lens1 pre Empty in
       let {__lindata=obj} = lens_get lens0 mid in
       let s = (sel obj t).__lindata in
       (lens_put lens0 mid Empty, {__lindata=s})
    }

  let receive lens =
    let open LinMonad in
    {__run=
       fun pre ->
       let {__lindata=s} = lens_get lens pre in
       let ls = Event.sync s in
       (lens_put lens pre Empty, {__lindata=ls})
    }

  let close lens =
    let open LinMonad in
    {__run=
       fun pre ->
       let {__lindata=s} = lens_get lens pre in
       let () = close s in
       (lens_put lens pre Empty, {data=()})
    }
end