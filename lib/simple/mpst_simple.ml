type ('la,'lb,'va,'vb) label =
  {make_obj: 'va -> 'la;
   call_obj: 'la -> 'va;
   make_var: 'vb -> 'lb}

type ('lr, 'l, 'r) obj_merge =
  {obj_merge: 'l -> 'r -> 'lr;
   obj_splitL: 'lr -> 'l;
   obj_splitR: 'lr -> 'r;
  }

type close = Close

type 'a placeholder =
  {mutable channel: 'a Event.channel}

let create_placeholder () =
  let channel = Event.new_channel () in
  {channel}

let unify p q = q.channel <- p.channel

type _ wrap =
  | WrapSend : ((< .. > as 'obj) option -> 'obj) -> 'obj wrap
  | WrapRecv : ((< .. > as 'obj) option -> 'obj) -> 'obj wrap
  | WrapClose : close wrap
  | WrapGuard : 'a wrap lazy_t -> 'a wrap

exception UnguardedLoop

let rec find_physeq : 'a. 'a list -> 'a -> bool = fun xs y ->
  match xs with
  | x::xs -> if x==y then true else find_physeq xs y
  | [] -> false
        
let rec remove_guards : type t. t wrap lazy_t list -> t wrap lazy_t -> t wrap =
  fun acc w ->
  if find_physeq acc w then
    raise UnguardedLoop
  else begin match Lazy.force w with
       | WrapGuard w' ->
          remove_guards (w::acc) w'
       | w -> w
       end
  
let rec unwrap : type t. t wrap -> t = function
  | WrapSend(obj) -> obj None
  | WrapRecv(obj) -> obj None
  | WrapClose -> Close
  | WrapGuard w ->
     let w' = remove_guards [] w in
     unwrap w'

let rec force_wrap : type t. t wrap -> unit = function
  | WrapSend(obj) -> ignore @@ obj None
  | WrapRecv(obj) -> ignore @@ obj None
  | WrapClose -> ()
  | WrapGuard w ->
     ignore (remove_guards [] w)

let rec unwrap_send : 'a. (< .. > as 'a) wrap -> 'a option -> 'a = function
  | WrapSend(obj) -> obj
  | WrapGuard(w) ->
     let w = remove_guards [] w in
     unwrap_send w
  | _ -> assert false

type _ seq =
  | Cons : 'hd wrap * 'tl seq -> [`cons of 'hd * 'tl] seq
  | ConsGuard : 't seq lazy_t -> 't seq

let rec seq_head : type hd tl. [`cons of hd * tl] seq -> hd wrap =
  function
  | Cons(hd,_) -> hd
  | ConsGuard xs -> WrapGuard(lazy (seq_head (Lazy.force xs)))

let rec seq_tail : type hd tl. [`cons of hd * tl] seq -> tl seq = fun xs ->
  match xs with
  | Cons(_,tl) -> tl
  | ConsGuard xs -> ConsGuard(lazy (seq_tail (Lazy.force xs)))

type (_,_,_,_) lens =
  | Zero  : ('hd0, 'hd1, [`cons of 'hd0 * 'tl] seq, [`cons of 'hd1 * 'tl] seq) lens
  | Succ : ('a, 'b, 'tl0 seq, 'tl1 seq) lens
           -> ('a,'b, [`cons of 'hd * 'tl0] seq, [`cons of 'hd * 'tl1] seq) lens

let rec get : type a b xs ys. (a, b, xs, ys) lens -> xs -> a wrap = fun ln xs ->
  match ln with
  | Zero -> seq_head xs
  | Succ ln' -> get ln' (seq_tail xs)
              
let rec put : type a b xs ys. (a,b,xs,ys) lens -> xs -> b wrap -> ys =
  fun ln xs b ->
  match ln with
  | Zero -> Cons(b, seq_tail xs)
  | Succ ln' -> Cons(seq_head xs, put ln' (seq_tail xs) b)

type ('robj,'rvar,'c,'a,'b,'xs,'ys) role = {label:('robj,'rvar,'c,'c) label; lens:('a,'b,'xs,'ys) lens}

let rec wrap_merge : type s. s wrap -> s wrap -> s wrap = fun l r ->
  match l, r with
  | WrapSend l, WrapSend r -> WrapSend (fun obj -> l (Some (r obj)))
  | WrapRecv l, WrapRecv r -> WrapRecv (fun obj -> l (Some (r obj)))
  | WrapClose, WrapClose -> WrapClose
  | WrapGuard w1, w2 ->
     WrapGuard
       (let rec w =
          (lazy begin
               try
                 let w1 = remove_guards [w] w1 in
                 wrap_merge w1 w2
               with
                 UnguardedLoop -> w2
             end)
        in w)
  | w1, ((WrapGuard _) as w2) -> wrap_merge w2 w1
  | WrapSend _, WrapRecv _ -> assert false
  | WrapRecv _, WrapSend _ -> assert false
        
let rec remove_guards_seq : type t. t seq lazy_t list -> t seq lazy_t -> t seq =
  fun acc w ->
  if find_physeq acc w then
    raise UnguardedLoop
  else begin match Lazy.force w with
       | ConsGuard w' ->
          remove_guards_seq (w::acc) w'
       | w -> w
       end

let rec seq_merge : type t.
    t seq -> t seq -> t seq =
  fun ls rs ->
  match ls, rs with
  | Cons(hd_l,tl_l), Cons(hd_r, tl_r) ->
     Cons(wrap_merge hd_l hd_r,
          seq_merge tl_l tl_r)
  | ConsGuard(xs), Cons(hd_r, tl_r) ->
     Cons(wrap_merge (WrapGuard(lazy (seq_head (Lazy.force xs)))) hd_r,
          seq_merge (ConsGuard(lazy (seq_tail (Lazy.force xs)))) tl_r)
  | (Cons(_,_) as xs), (ConsGuard(_) as ys) ->
     seq_merge ys xs
  | ConsGuard(w1), w2 ->
     ConsGuard
       (let rec w =
          (lazy begin
               try
                 let w1 = remove_guards_seq [w] w1 in
                 seq_merge w1 w2
               with
                 UnguardedLoop -> w2
             end)
        in w)
     
     

let a = {label={make_obj=(fun v->object method role_A=v end);
                call_obj=(fun o->o#role_A);
               make_var=(fun v->(`role_A(v):[`role_A of _]))};
         lens=Zero}
let b = {label={make_obj=(fun v->object method role_B=v end);
                call_obj=(fun o->o#role_B);
               make_var=(fun v->(`role_B(v):[`role_B of _]))};
         lens=Succ Zero}
let c = {label={make_obj=(fun v->object method role_C=v end);
                call_obj=(fun o->o#role_C);
               make_var=(fun v->(`role_C(v):[`role_C of _]))};
         lens=Succ (Succ Zero)}
let d = {label={make_obj=(fun v->object method role_D=v end);
                call_obj=(fun o->o#role_D);
                make_var=(fun v->(`role_D(v):[`role_D of _]))};
         lens=Succ (Succ (Succ Zero))}
let msg =
  {make_obj=(fun f -> object method msg=f end);
   call_obj=(fun o -> o#msg);
   make_var=(fun v -> `msg(v))}
let left =
  {make_obj=(fun f -> object method left=f end);
   call_obj=(fun o -> o#left);
   make_var=(fun v -> `left(v))}
let right =
  {make_obj=(fun f -> object method right=f end);
   call_obj=(fun o -> o#right);
   make_var=(fun v -> `right(v))}
let left_or_right =
  {obj_merge=(fun l r -> object method left=l#left method right=r#right end);
   obj_splitL=(fun lr -> (lr :> <left : _>));
   obj_splitR=(fun lr -> (lr :> <right : _>));
  }
let right_or_left =
  {obj_merge=(fun l r -> object method right=l#right method left=r#left end);
   obj_splitL=(fun lr -> (lr :> <right : _>));
   obj_splitR=(fun lr -> (lr :> <left : _>));
  }
let to_b m =
  {obj_merge=(fun l r -> object method role_B=m.obj_merge l#role_B r#role_B end);
   obj_splitL=(fun lr -> object method role_B=m.obj_splitL lr#role_B end);
   obj_splitR=(fun lr -> object method role_B=m.obj_splitR lr#role_B end);
  }
let b_or_c =
  {obj_merge=(fun l r -> object method role_B=l#role_B method role_C=r#role_C end);
   obj_splitL=(fun lr -> (lr :> <role_B : _>));
   obj_splitR=(fun lr -> (lr :> <role_C : _>));
  }

module type LIN = sig
  type 'a lin
  val mklin : 'a -> 'a lin
  val unlin : 'a lin -> 'a
end


let map_option f = function
  | Some x -> Some (f x)
  | None -> None

let choice_at : 'ep 'ep_l 'ep_r 'g0_l 'g0_r 'g1 'g2.
  (_, _, _, close, < .. > as 'ep, 'g1 seq, 'g2 seq) role ->
  ('ep, < .. > as 'ep_l, < .. > as 'ep_r) obj_merge ->
  (_, _, _, 'ep_l, close, 'g0_l seq, 'g1 seq) role * 'g0_l seq ->
  (_, _, _, 'ep_r, close, 'g0_r seq, 'g1 seq) role * 'g0_r seq ->
  'g2 seq
  = fun r merge (r',g0left) (r'',g0right) ->
  let epL, epR = get r'.lens g0left, get r''.lens g0right in
  let g1left, g1right =
    put r'.lens g0left WrapClose, put r''.lens g0right WrapClose in
  let g1 = seq_merge g1left g1right in
  let g2 = put r.lens g1 (WrapSend (fun obj ->
                     let oleft, oright = unwrap_send epL, unwrap_send epR in
                     merge.obj_merge (oleft (map_option merge.obj_splitL obj)) (oright (map_option merge.obj_splitR obj))))
  in
  g2
  
module MakeGlobal(X:LIN) = struct

  let make_send rB lab (ph: _ placeholder) epA =
    let method_ obj =
      let ph, epA = 
        match obj with
        | None ->
           ignore (force_wrap epA);
           ph, epA
        | Some obj ->
           let ph', epA' = lab.call_obj (rB.label.call_obj obj) in
           let epA' = X.unlin epA' in
           unify ph ph';
           ph, wrap_merge epA epA'
      in
      ph, X.mklin epA
    in
    (* <role_rB : < lab : v -> epA > > *)
    WrapSend (fun obj ->
        rB.label.make_obj (lab.make_obj (method_ obj)))

  let make_recv rA lab ph epB =
    let method_ obj =
      let ev =
        Event.wrap
          (Event.guard (fun () -> Event.receive ph.channel))
          (fun v -> lab.make_var (v, X.mklin (unwrap epB)))
      in
      match obj with
      | None ->
         force_wrap epB;
         ev
      | Some obj ->
         force_wrap epB;
         Event.choose [ev; rA.label.call_obj obj]
    in
    WrapRecv (fun obj ->
        rA.label.make_obj (method_ obj))

  let ( --> ) : 'roleAVar 'labelvar 'epA 'roleBobj 'g1 'g2 'labelobj 'epB 'g0 'v.
    (< .. > as 'roleAvar, _, 'labelvar Event.event, 'epA, 'roleBobj, 'g1, 'g2) role ->
    (< .. > as 'roleBobj, _, 'labelobj,             'epB, 'roleAvar, 'g0, 'g1) role ->
    (< .. > as 'labelobj, [> ] as 'labelvar, 'v placeholder * 'epA wrap X.lin, 'v * 'epB X.lin) label ->
    'g0 -> 'g2
    = fun rA rB label g0 ->
    let ch = create_placeholder ()
    in
    let epB = get rB.lens g0 in
    let ev  = make_recv rA label ch epB in
    let g1  = put rB.lens g0 ev
    in
    let epA = get rA.lens g1 in
    let obj = make_send rB label ch epA in
    let g2  = put rA.lens g1 obj
    in g2
end

let goto : type t. t seq lazy_t -> t seq = fun xs ->
  ConsGuard xs

let finish : ([`cons of close * 'a] as 'a) seq =
  let rec loop = lazy (Cons(WrapClose, ConsGuard(loop))) in
  Lazy.force loop
      
include MakeGlobal(struct type 'a lin = 'a let mklin x = x let unlin x = x end)

let get_ep r g =
  (* force_all g; *)
  let ep = get r.lens g in
  unwrap ep

let send (ph, cont) v = Event.sync (Event.send ph.channel v); unwrap cont
let receive ev = Event.sync ev
let close Close = ()
