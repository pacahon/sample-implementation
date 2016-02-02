open Ostap
open GT
open MiniKanren
 
module Term =
  struct

    @type ('var, 'self) t = [`Var of 'var | `App of 'self * 'self | `Lambda of 'var * 'self] with gmap, show, html

    let rec copy (h : Helpers.h) node =
      let (l, r) = h#retrieve node in
      h#reassign
        (transform(t) (fun _ x -> x) (lift (copy h)) (new @t[gmap]) () node)
        l
	r

    class ['self] vertical =
      object (this)
        inherit [string, 'self] @t[show]
        method c_Var _ _ v = Printf.sprintf "x\n%s\n" v.GT.x
        method c_App _ _ x y = 
          Printf.sprintf "@\n%s%s" (x.GT.fx ()) (y.GT.fx ())
        method c_Lambda _ _ v x =
          Printf.sprintf "\\\n%s\n%s" v.GT.x (x.GT.fx ())
      end

    type prio = [`Top | `Abs | `Left of int | `Right of int]

    class ['self] pretty =
      object (this)
        inherit [string, unit, HTMLView.er, 'self, prio, HTMLView.er, prio, HTMLView.er] @t
        method c_Var p _ v = 
	  match p with `Abs -> HTMLView.seq [HTMLView.string " . "; HTMLView.string v.GT.x] | _ -> HTMLView.string v.GT.x
        method c_Lambda p _ v x = 
	  let z = HTMLView.seq [HTMLView.string v.GT.x; x.GT.fx `Abs] in
	  match p with
	  | `Left _ -> HTMLView.seq [HTMLView.string "("; HTMLView.raw "&lambda;"; z; HTMLView.string ")"]
	  | `Abs    -> HTMLView.seq [HTMLView.string " "; z]
	  | _       -> HTMLView.seq [HTMLView.raw "&lambda;"; z]
        method c_App p _ x y =
          let xy = HTMLView.seq [x.GT.fx (`Left 9); HTMLView.string " "; y.GT.fx (`Right 9)] in
	  match p with
	  | `Abs     -> HTMLView.seq [HTMLView.string " . "; xy]
	  | `Right 9 -> HTMLView.seq [HTMLView.string "("; xy; HTMLView.string ")"]
	  | _        -> xy
      end    

    let pretty l = 
      let rec pretty' p l = transform(t) (lift HTMLView.string) pretty' (new pretty) p l in
      pretty' `Top l

    class ['self] abbrev_html cb pretty =
      let w = new Helpers.wrap cb pretty in
      let with_top top node p =
        if top then p else w#wrap node w#bullet
      in
      object (this)
        inherit [string, bool, HTMLView.er, 'self, bool, HTMLView.er, bool, HTMLView.er] @t
        method c_Var top s v = 
          with_top top s.GT.x (HTMLView.tag "tt" (HTMLView.string v.GT.x))
        method c_Lambda top s v x =
          with_top top s.GT.x 
	    (HTMLView.tag "tt" (
               HTMLView.seq [
	         HTMLView.string "\\"; 
	         HTMLView.string v.GT.x; 
	         HTMLView.string "."; 
                 x.GT.fx false
            ]))
        method c_App top s x y =
	  with_top top s.GT.x 
	    (HTMLView.tag "tt" (
               HTMLView.seq [
                 x.GT.fx false;
                 HTMLView.raw " ";
                 y.GT.fx false
            ]))
      end

    class ['var, 'self] html =
      object
        inherit ['var, 'self] @t[html]
        inherit Helpers.cname as helped
	method c_Var    _ _ v   = HTMLView.string v.GT.x
	method c_Lambda _ _ v x =
          HTMLView.seq [
	    HTMLView.raw "&lambda; ";
	    HTMLView.string v.GT.x;
            HTMLView.ul (x.GT.fx ())
	  ]
        method cname name =
          match helped#cname name with
          | "app" -> "@"
          | name  -> name
      end

    module Lexer = Lexer.Make (struct let keywords = ["def"; "in"] end)

    let hparse (h : Helpers.h) s = 
      let ostap (
        lident : n:!(Lexer.ident) =>{let c = n.[0] in c = Char.lowercase c}=> {n};
        uident : n:!(Lexer.ident) =>{let c = n.[0] in c = Char.uppercase c}=> {n};
        key[name]: @(name ^ "\\b" : name);
        def[env] : 
          -key["def"] -x:lident -"=" -e:expr[env] -key["in"] def[(x, `Def e)::env] 
        | expr[env];
        expr[env]: l:($) p:primary[env]+ r:($) {
          h#register
	    (let t::ts = p in 
             List.fold_left (fun acc e -> 
                               let (l, _) = h#retrieve acc in
			       let (_, r) = h#retrieve e   in
			       h#reassign (`App (acc, e)) l r
                            ) 
                            t ts
            )
            (l :> Helpers.loc) 
            (r :> Helpers.loc)
        };
        primary[env]:
          -"(" expr[env] -")"
	| l:($) n:uident r:($) {h#register (`Var n) (l :> Helpers.loc) (r :> Helpers.loc)}
        | l:($) n:lident r:($) {
            try 
	      match List.assoc n env with
              | `Def e -> h#register (copy h e) (l :> Helpers.loc) (r :> Helpers.loc)
	      | `Arg   -> h#register (`Var n)   (l :> Helpers.loc) (r :> Helpers.loc)
	    with Not_found -> raise (Lexer.Error (Ostap.Msg.make "undefined identifier %0" [|"\"" ^ n ^ "\""|] l#loc))
	  }
        | l:($) "\\" ns:lident+ "." e:expr[List.map (fun n -> (n, `Arg)) ns @ env] r:($) {
            List.fold_right (fun n acc -> h#register (`Lambda (n, acc)) (l :> Helpers.loc) (r :> Helpers.loc)) ns e
          }
      ) in
      def [] s

    let parse s =
      let h = Helpers.highlighting () in
      ostap (e:hparse[h] -EOF {e, h}) s

    let rec html_t cb e = 
      HTMLView.li ~attrs:(cb.Helpers.f e)
        (transform(t) 
           (fun _ -> HTMLView.string) 
           (fun _ -> html_t cb) 
           (new html) 
           () 
           e
        )

    let rec vertical e = 
      transform(t) 
	(fun _ x -> x)
        (fun _ -> vertical) 
        (new vertical) 
        () 
        e

    module Semantics =
      struct

	module TopSemantics = Semantics

        module SimpleTyping =
	  struct

	    @type ('var, 'self) typ = [ `V of 'var | `Arr of 'self * 'self] with gmap, show, html

            type gtyp = (string, gtyp) typ
	    type ltyp = (string logic, ltyp) typ logic

	    type glam = (string, glam) t
	    type llam = (int logic, llam) t logic

	    class indexer =
	      object
		val h  = Hashtbl.create 32
		val h' = Hashtbl.create 32
		val i  = ref 0
		method get i = try Hashtbl.find h' i with Not_found -> "?"
		method index s =
		  try Hashtbl.find h s with Not_found -> 
		    let i' = i.contents in 
		    Hashtbl.add h  s  i';
		    Hashtbl.add h' i' s ;
		    incr i;
		    i'
	      end	      	      

	    let glam_to_llam l =
	      let indexer = new indexer in
	      let rec to_logic l = ! (gmap(t) (fun s -> !(indexer#index s)) to_logic l) in
	      to_logic l, indexer

            exception Not_even_a_value 

	    let to_value' = function Value x -> x | _ -> raise Not_even_a_value

	    let llam_to_glam indexer l =
              let rec of_logic x = 
		gmap(t) (fun i -> indexer#get (to_value i)) of_logic (to_value x)
	      in
	      of_logic l

	    let rec gtyp_to_ltyp l = !(gmap(typ) (!) gtyp_to_ltyp l)

            let ltyp_to_gtyp names l =
	      let rec of_logic = function
                | Var   i -> `V (names#get i)
                | Value t -> gmap(typ) (function Var i -> names#get i | Value t -> t) of_logic t
	      in
	      of_logic l

	    let rec html_typ t = 
              transform(typ) (fun _ x -> html string x) (fun _ -> html_typ) 
                (object inherit [string, (string, 'a) typ as 'a] @typ[html] 
                   method c_V   _ _ v  = HTMLView.string v.x
                   method c_Arr _ _ d c = 
                     HTMLView.seq [
                       (fun s -> 
                          match d.x with 
                          | `Arr _ -> HTMLView.seq [HTMLView.string "("; s; HTMLView.string ")"] 
                          | _ -> s
                       ) (d.fx ()); 
                       HTMLView.raw "&#8594;"; 
                       c.fx ()
                     ]
                 end) 
                () 
                t;; 

	    @type ('env, 'lam, 'typ, 'self) tree = [ `Var of 'env * 'lam * 'typ 
                                                   | `App of 'env * 'self * 'self * 'lam * 'typ
			                           | `Abs of 'env * 'self * 'lam * 'typ
                                                   ] with gmap 

            type lenv = (int logic * ltyp) llist logic
	    type env  = (string * gtyp) list

            type ltree = (lenv, llam, ltyp, ltree) tree logic
            type gtree = (env, glam, gtyp, gtree) tree

            let to_env names indexer l = List.map (fun (x, y) -> indexer#get (to_value x), ltyp_to_gtyp names y) (to_list l)

            let html_env e =
              transform(list) 
		(fun _ (x, t) -> HTMLView.seq [HTMLView.string x; HTMLView.string ":"; html_typ t]) 
		(object inherit [string * gtyp, unit, HTMLView.er, bool, HTMLView.er] @list 
		   method c_Nil  _ _      = HTMLView.string ""
		   method c_Cons f _ x xs =
		     (fun s -> if f then s else HTMLView.seq [HTMLView.string "; "; s]) 
		       (HTMLView.seq [x.fx (); xs.fx false])
		 end) 
		true e

            let rec to_tree names indexer t =
              gmap tree (to_env names indexer) (llam_to_glam indexer) (ltyp_to_gtyp names) (to_tree names indexer) (to_value' t)

	    module Tree = TopSemantics.Deterministic.BigStep.Tree

	    type stree = (env, glam, unit, gtyp) Tree.t

            let rec to_stree = function
	    | `Var (env, x, typ)         -> Tree.Node (env, x, (), TopSemantics.Good typ, [], "Var")
	    | `App (env, t1, t2, m, typ) -> Tree.Node (env, m, (), TopSemantics.Good typ, [to_stree t1; to_stree t2], "App")
	    | `Abs (env, t, m, typ)      -> Tree.Node (env, m, (), TopSemantics.Good typ, [to_stree t], "Abs")

            let html_tree t =
              Tree.html 
		"root" 
		(object
		   inherit Tree.html_customizer
		   method show_over   = false
		   method arrow_scale = 1
                   method arrow       = ":"
                   method over_width  = 5
	         end)
		(lift html_env)
		(lift pretty) 
		(fun _ _ -> HTMLView.string "") 
		(lift html_typ) 
		t
	    
	    let infer h expr =
	      let infero expr typ tree =
	        let rec lookupo a g t =
  		  fresh (a' t' tl) 
		    (g === !(a', t')%tl)
		    (conde [
		       (a' === a) &&& (t' === t);
		       (a' =/= a) &&& (lookupo a tl t) 
	            ])  
	        in
	        let rec infero gamma expr typ tree = 
	  	  conde [
		    fresh (x)
		      (expr === !(`Var x))
                      (tree === !(`Var (gamma, !(`Var x), typ)))
		      (lookupo x gamma typ);
		    fresh (m n t tree' tree'')    
		      (expr === !(`App (m, n))) 
                      (tree === !(`App (gamma, tree', tree'', !(`App (m, n)), typ)))
                      (infero gamma m !(`Arr (t, typ)) tree')
                      (infero gamma n t tree'');		  
		    fresh (x l t t' tree') 
		      (expr === !(`Lambda (x, l))) 
		      (typ  === !(`Arr (t, t')))
                      (tree === !(`Abs (gamma, tree', !(`Lambda (x, l)), typ)))
		      (infero (!(x, t)%gamma) l t' tree')
	          ]
	        in
	        infero !Nil expr typ tree      
	      in
              run (fun st -> 
                     let names          = new Helpers.names in
		     let lexpr, indexer = glam_to_llam expr in
		     let inferred, t, d = qr (fun t d st -> infero lexpr t d st, t, d) st in
                     match take ~n:2 inferred with
		     | []   -> html_tree (Tree.Node ([], expr, (), TopSemantics.Bad "no type", [], ""))
                     | [st] -> 
			 let tree = to_stree (to_tree names indexer (fst (refine st d))) in
			 html_tree tree
		  )

	  end
      end

  end

let toplevel =
  Toplevel.make 
    (Term.Lexer.fromString Term.parse)
    (fun (p, h) ->         
       object inherit Toplevel.c
         method ast cb = View.toString (
                           HTMLView.ul ~attrs:"id=\"ast\" class=\"mktree\"" (
                             Term.html_t (Helpers.interval cb h) p
                           )
                         )
         method vertical  = Term.vertical p
         method run cb js =
           Toplevel.Wizard.Page (
             [                             
              HTMLView.Wizard.radio "Type" [HTMLView.raw "simple typing", "typing", "checked=\"true\""] (*; HTMLView.raw "evaluation", "evaluation", ""]; *)
             ],
             [(fun page conf -> true),
              Toplevel.Wizard.Exit 
                (fun conf ->
		   js#results "root" (View.toString (Term.Semantics.SimpleTyping.infer (Helpers.interval cb h) p)) "Lambda_ST"		  
                )                
	     ]
           )
       end
    )
