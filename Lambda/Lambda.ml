open Ostap
open GT
open MiniKanren
 
module Term =
  struct

    @type ('var, 'self) t = [`Var of 'var | `App of 'self * 'self | `Lambda of 'var * 'self] with gmap, show, html, foldl

    type glam = (string, glam) t

    module SS = Set.Make (String)

    class var = object inherit [string, glam, SS.t] @t[foldl]
      method c_Var s _ x = x.fx s
    end

    let rec fv l = 
      transform(t)
        (fun s x -> SS.add x s)
        (lift fv)
        object inherit var   
          method c_Lambda s _ x l = SS.union s (SS.remove x.x (l.fx SS.empty))
        end 
        SS.empty
        l

    let rec subst a x b =
      let fv = fv b in
      let fresh_name s =
	let n = new Helpers.names in
	let rec spin () =
	  let name = n#fresh_name in
	  if SS.mem name s then spin () else name
	in
	spin ()
      in
      let rec inner a x b =
        transform(t) 
          (fun _ x -> x)
          (fun _ a -> inner a x b)
          (object inherit [string, string, glam, glam, glam] @t[gmap]
             method c_Var    _ _ y   = if y.x = x then b   else `Var y.x
             method c_Lambda _ s y a = 
	       if y.x = x 
	       then s.x 
	       else 
		 if SS.mem y.x fv 
		 then let y' = fresh_name (SS.add y.x fv) in
                      `Lambda (y', inner (subst a.x y.x (`Var y')) x b)
		 else `Lambda (y.x, a.fx ())
           end)
           ()
          a
      in
      inner a x b

    type ('a, 'b) env = ('a * 'b) list

    let html_env (a : 'a -> HTMLView.er) (b : 'b -> HTMLView.er) e =
      transform(list) 
        (fun _ (x, t) -> HTMLView.seq [a x; HTMLView.string ":"; b t])
        (object inherit ['a * 'b, unit, HTMLView.er, bool, HTMLView.er] @list 
           method c_Nil  _ _      = HTMLView.string ""
           method c_Cons f _ x xs =
             (fun s -> if f then s else HTMLView.seq [HTMLView.string "; "; s]) 
             (HTMLView.seq [x.fx (); xs.fx false])
         end) 
         true 
         e

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

    type prio = [`Top | `Abs | `Left | `Right of bool]

    class ['self] pretty =
      object (this)
        inherit [string, unit, HTMLView.er, 'self, prio, HTMLView.er, prio, HTMLView.er] @t
        method c_Var p _ v = 
          match p with `Abs -> HTMLView.seq [HTMLView.string " . "; HTMLView.string v.GT.x] | _ -> HTMLView.string v.GT.x
        method c_Lambda p _ v x = 
          let z = HTMLView.seq [HTMLView.string v.GT.x; x.GT.fx `Abs] in
          match p with
          | `Left | `Right true -> HTMLView.seq [HTMLView.string "("; HTMLView.raw "&lambda;"; z; HTMLView.string ")"]
          | `Abs  -> HTMLView.seq [HTMLView.string " "; z]
          | _     -> HTMLView.seq [HTMLView.raw "&lambda;"; z]
        method c_App p _ x y =
          let xy = HTMLView.seq [x.GT.fx `Left; HTMLView.string " "; y.GT.fx (match p with `Left -> `Right true | `Right f -> `Right f | _ -> `Right false)] in
          match p with
          | `Abs     -> HTMLView.seq [HTMLView.string " . "; xy]
          | `Right _ -> HTMLView.seq [HTMLView.string "("; xy; HTMLView.string ")"]
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

        module Core =
          struct

            type left  = glam
            type over  = unit
            type right = glam

            let left_html   = pretty
            let over_html _ = HTMLView.string ""
            let right_html  = pretty
           
	    class html_customizer =
              object
                inherit TopSemantics.Deterministic.BigStep.Tree.html_customizer
                method show_env    = false
                method show_over   = false
                method arrow       = "&rarr;"
                method over_width  = 40
		method arrow_scale = 1
              end            

            let customizer = new html_customizer
  
            module S = Semantics.Deterministic.BigStep

            class virtual ['env] c =
              object 
                inherit [string, 'env, ('env, glam, unit, glam) S.case,
                         glam  , 'env, ('env, glam, unit, glam) S.case,
                                 'env, ('env, glam, unit, glam) S.case
                        ] @t
                method nf (e : 'env) 
                          (lam :  ('env, glam, ('env, glam, GT.unit, glam) S.case,
                                   < self : 'env -> glam -> ('env, glam, GT.unit, glam) S.case;
                                     var  : 'env -> GT.string -> ('env, glam, GT.unit, glam) S.case >
                                ) GT.a
                          ) =
                  match S.unfold (fun (e, l, _) -> lam.f e l) (lam.fx e) with
                  | S.Nothing _ -> true
                  | _ -> false
              end

          end 

	module BigStep =
	  struct

	    module WHR_Core =
	      struct
		include Core

		class html_customizer' =
		  object
                    inherit html_customizer
                    method arrow = "&#x21d3;"
		  end            

		let customizer = new html_customizer'

		type env = unit

		let env_html _ = HTMLView.string ""

		class whr =
		  object inherit [env] c
		    method c_Var    _ s _   = S.Just (s.x, "Var")
		    method c_Lambda _ s _ _ = S.Just (s.x, "Abs")
		    method c_App    _ s m n =
		      S.Subgoals (
                        [(), m.x, ()],
		        (fun [m'] ->
                           match m' with
			   | `Lambda (x, a) -> 
			       S.Subgoals (
			          [(), subst a x n.x, ()], 
			          (fun [m] -> S.Just (m, "")), 
			          "Red"
                               )
                           | _ -> S.Just (`App (m', n.x), "App")
                        ),
		        ""
                      )
		  end

                let rec step' tr _ lam _ =
                  transform(t)
                    (fun _ x -> S.Just (`Var x, "Var"))
                    (fun _ l -> step' tr () l ())
                    tr
                    ()
                    lam             

                let step = step' (new whr)

	      end

	    module HR_Core =
	      struct
		include WHR_Core

		class hr =
		  object inherit whr
		    method c_Lambda _ _ x a =
		      S.Subgoals (
		        [(), a.x, ()],
		        (fun [a'] -> S.Just (`Lambda (x.x, a'), "")),
		        "Abs"		      
		      )
		  end

		let step = step' (new hr)

	      end

	    module NR_Core =
	      struct
		include HR_Core

		class nr = 
		  object inherit hr
		    method c_App _ _ m n =
		      match m.x with
		      | `Lambda (x, a) ->
                         S.Subgoals (
                           [(), subst a x n.x, ()],
                           (fun [m] -> S.Just (m, "Red")),
                           ""
                         )
		      | _ ->
		         S.Subgoals (
		           [(), m.x, ()],
		           (fun [m'] -> 
			      match m' with
			      | `Lambda (x, a) ->
			          S.Subgoals (
                                    [(), subst a x n.x, ()],
			            (fun [m] -> S.Just (m, "App")),
			            ""
                                  )
			      | _ ->
			         S.Subgoals (
			            [(), n.x, ()],
                                    (fun [n'] -> S.Just (`App (m', n'), "Arg")),
			            ""
                                 )
		   	   ),
		           ""
		         )
		  end

		let step = step' (new nr)

	      end

	    module CBV_Core =
	      struct
		include WHR_Core

		class cbv =
		  object inherit whr
		    method c_App _ _ m n =
		      S.Subgoals (
		        [(), m.x, (); (), n.x, ()],
		        (fun [m'; n'] ->
			   match m' with
			   | `Lambda (x, a) -> 
			       S.Subgoals (
			         [(), subst a x n', ()],
                                 (fun [m] -> S.Just (m, "Red")),
			         ""
			      )
			   | _ -> S.Just (`App (m', n'), "App")
			),
			""
                      )
		  end

		let step = step' (new cbv)

	      end

	    module CBN = TopSemantics.Deterministic.BigStep.Tree.Make (WHR_Core)
	    module CBV = TopSemantics.Deterministic.BigStep.Tree.Make (CBV_Core)
	    module HR  = TopSemantics.Deterministic.BigStep.Tree.Make (HR_Core )
	    module NR  = TopSemantics.Deterministic.BigStep.Tree.Make (NR_Core )

	  end

        module SmallStep =
          struct

            module WHR_Core =
              struct
                include Core
            
                type env = unit

                let env_html _ = HTMLView.string ""

                class whr =
                  object inherit [env] c
                    method c_Var e _ x   = S.Nothing ("normal form", "")
                    method c_App e _ m n = 
                      match m.x with
                      | `Lambda (x, a) -> S.Just (subst a x n.x, "Red")
                      | _ ->
                          S.Subgoals (
                            [(), m.x, ()],
                            (fun [m'] -> S.Just (`App (m', n.x), "")),
                            "App"
                          )
                    method c_Lambda e s x m = S.Nothing ("normal form", "")
                  end
        
                let rec step' tr _ lam _ =
                  transform(t)
                    (fun _ x -> S.Just (`Var x, "Var"))
                    (fun _ l -> step' tr () l ())
                    tr
                    ()
                    lam             

                let step = step' (new whr)

                let side_step _ lam _ lam' = 
                  if lam = lam' then None else Some ((), lam', ())

              end

            module HR_Core =
              struct
 
                include WHR_Core

                class hr =
                  object inherit whr
                    method c_Lambda _ _ x m =
                      S.Subgoals (
                        [(), m.x, ()],
                        (fun [m'] -> S.Just (`Lambda (x.x, m'), "")),
                        "Abs"
                      )
                  end

                let step = step' (new hr)

              end

            module CBV_Core =
              struct

                include WHR_Core

                class cbv =
                  object(this) inherit whr
                    method c_App e _ m n =
                      match m.x with
                      | `Lambda (x, m') ->                
                          if this#nf e n
                          then S.Just (subst m' x n.x, "Red")
                          else S.Subgoals (
                                 [(), n.x, ()],
                                 (fun [n'] -> S.Just (`App (m.x, n'), "")),
                                 "Arg"
                               )
                      | _ ->                     
                          if this#nf e m
                          then S.Subgoals (
                                 [(), n.x, ()],
                                 (fun [n'] -> S.Just (`App (m.x, n'), "")),
                                 "Arg"
                               )
                          else S.Subgoals (
                                 [(), m.x, ()],
                                 (fun [m'] -> S.Just (`App (m', n.x), "")),
                                 "App"
                               )
                  end

                let step = step' (new cbv)

              end

            module NR_Core =
              struct

                include HR_Core

                class nr =
                  object(this) inherit hr as hr
                    method c_App i s m n =
                      match m.x with 
                      | `Lambda (_, _) -> hr#c_App i s m n
                      | _ -> 
                          if this#nf i m 
                          then
                            S.Subgoals (
                               [(), n.x, ()],
                               (fun [n'] -> S.Just (`App (m.x, n'), "")),
                               "Arg"
                            )
                           else hr#c_App i s m n
                  end

                let step = step' (new nr)
    
              end

            module CBN = TopSemantics.Deterministic.SmallStep.Make (WHR_Core)
            module HR  = TopSemantics.Deterministic.SmallStep.Make (HR_Core)
            module NR  = TopSemantics.Deterministic.SmallStep.Make (NR_Core)
            module CBV = TopSemantics.Deterministic.SmallStep.Make (CBV_Core)
            module HLR = TopSemantics.Deterministic.SmallStep.Make (
              struct
                include Core

                type env = (string * glam) list * glam list 

		class html_customizer' =
		  object
                    inherit html_customizer
                    method show_env = true
		  end            

		let customizer = new html_customizer'

                let rec step env lam _ = 
                  transform(t) 
                    (fun _ x -> S.Just (`Var x, ""))
                    (fun env lam -> step env lam ()) 
                    (object 
                       inherit [env] c
                       method c_Var (env, _) _ x = 
                         try S.Just (List.assoc x.x env, "B-Var") with
                           Not_found -> S.Nothing ("quasi-normal form", "")                     
                       method c_App (env, st) _ m b =
                         S.Subgoals (
                           [(env, b.x::st), m.x, ()],
                           (fun [p] -> S.Just (`App (p, b.x), "")),
                           "App"
                         ) 
                       method c_Lambda (env, st) _ v m = 
                         match st with
                         | [] -> S.Subgoals (
                                   [(env, st), m.x, ()],
                                   (fun [m'] -> S.Just (`Lambda (v.x, m'), "")),
                                   "Abs-Unbound"
                                 )
                         | b::st -> S.Subgoals (
                                      [((v.x, b)::env,st), m.x, ()],
                                      (fun [m'] -> S.Just (`Lambda (v.x, m'), "Abs")),
                                      "" 
                                    )
                     end
                    ) 
                    env 
                    lam 
 
                let side_step _ lam _ lam' = 
                  if lam = lam' then None else Some (([], []), lam', ())

                let env_html  (e, s) =
		  let hl l e =
		    if List.length l = 0 then HTMLView.raw "&epsilon;" else e
		  in
                  HTMLView.seq [ 
		    hl e (HTMLView.seq [
		            HTMLView.string "["; 
		            html_env HTMLView.string pretty e; 
		            HTMLView.string "]"
                         ]);
                    HTMLView.raw ";&nbsp;";
                    hl s (HTMLView.raw (show(list) (fun x -> View.toString (pretty x)) s))
                  ]
              end
            )
          end

        module SimpleTyping =
          struct

            @type ('var, 'self) typ = [`V of 'var | `Arr of 'self * 'self] with gmap, show, html

            type gtyp = (string, gtyp) typ
            type ltyp = (string logic, ltyp) typ logic
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

            let html_env e = html_env HTMLView.string html_typ e

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
           let depth = ref (-1) in
           Toplevel.Wizard.Page (
             [                             
              HTMLView.Wizard.radio "Type" [
                HTMLView.string "typing"    , "typing"    , "checked=\"true\"";
                HTMLView.string "evaluation", "evaluation", ""
              ] 
             ],
             [(fun page conf -> conf "Type" = "typing"),
              Toplevel.Wizard.Exit 
                (fun conf -> 
                   js#results "root" (View.toString (Term.Semantics.SimpleTyping.infer (Helpers.interval cb h) p)) "Lambda_ST"
                );
              (fun page conf -> conf "Type" = "evaluation"),
              Toplevel.Wizard.Page (
                [
                 HTMLView.Wizard.radio "Semantic Type" [
                   HTMLView.string "Small-Step", "SS", "checked=\"true\"";
                   HTMLView.string "Big-Step"  , "BS", ""
                 ];
                 HTMLView.Wizard.combo "Reduction order" [
                   HTMLView.string "Normal Order"         , "NR" , "selected=\"true\"";
                   HTMLView.string "Call by Name"         , "CBN", "";
                   HTMLView.string "Call by Value"        , "CBV", "";
                   HTMLView.string "Head Reduction"       , "HR" , "";
                   HTMLView.string "Head Linear Reduction", "HLR", ""
                 ];
                 Toplevel.Wizard.div ~default:"-1" "Tree depth"           
                ],
                [(fun page conf -> 
                    let depth'  = conf "Tree depth" in
                    match
                      Term.Lexer.fromString (ostap (s:"-"? n:!(Term.Lexer.literal) -EOF {match s with Some _ -> -(n) | _ -> n})) depth'
                    with
                    | Checked.Ok depth'' -> depth := depth''; true
                    | Checked.Fail [msg] -> js#error page "Tree depth" depth' msg; false
                 ),
                 Toplevel.Wizard.Exit 
                   (fun conf ->
                      let kind = conf "Semantic Type" ^ "_" ^ conf "Reduction order" in
                      let f =
                        List.assoc kind
                          ["SS_CBN", (fun () -> Term.Semantics.SmallStep.CBN.build_html ~limit:depth.contents ()       p () "root");
                           "SS_CBV", (fun () -> Term.Semantics.SmallStep.CBV.build_html ~limit:depth.contents ()       p () "root");
                           "SS_HR" , (fun () -> Term.Semantics.SmallStep.HR .build_html ~limit:depth.contents ()       p () "root");
                           "SS_NR" , (fun () -> Term.Semantics.SmallStep.NR .build_html ~limit:depth.contents ()       p () "root");
                           "SS_HLR", (fun () -> Term.Semantics.SmallStep.HLR.build_html ~limit:depth.contents ([], []) p () "root");

			   "BS_CBN", (fun () -> Term.Semantics.BigStep  .CBN.build_html ~limit:depth.contents ()       p () "root");
			   "BS_CBV", (fun () -> Term.Semantics.BigStep  .CBV.build_html ~limit:depth.contents ()       p () "root");
                           "BS_HR" , (fun () -> Term.Semantics.BigStep  .HR .build_html ~limit:depth.contents ()       p () "root");
                           "BS_NR" , (fun () -> Term.Semantics.BigStep  .NR .build_html ~limit:depth.contents ()       p () "root");
                          ]
                      in
                      js#results "root" (View.toString (f ())) ("Lambda_" ^ kind)
                   )
                 ]
               )               
             ]
           )
       end
    )


