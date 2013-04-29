module Quotations =
  struct
    
    generic 'self t = 'self as [> `H | `V]
 
    ostap (
      parse: !(L.Stmt.parse)[expr][stmt] -EOF;
      expr: !(L.Expr.parse)[primary];
      primary[p]:
        x:!(L.Lexer.ident)   {`Var   x}
      | i:!(L.Lexer.literal) {`Const i} 
      | quotation
      | -"(" p -")";      
      quotation: "@-" {`H} | "@|" {`V};
      stmt[p]: quotation
    )
    
  end

module Breaks =
  struct

    module Stmt =
      struct
        
        generic 'self t = 'self as [>
        | `Lambda
        | `Break 
        ]

        let (++) s = function `Lambda -> s | s' -> `Seq (s, s')

        class virtual ['self, 'e, 'f, 'a, 'b] ttt =
          object
            inherit ['self, 'a, 'b] @t
            inherit ['self, 'e, 'f, 'a, 'b] @L.Stmt.t
          end

        class ['self, 'e] interpret =
          object (this)
            inherit ['self, > 'e L.Expr.t, int, ('self * 'self * State.t), State.t] ttt
            method m_Skip (k, b, s) t = t.Generic.g (`Lambda, b, s) k

            method m_Assign env t x e = 
              let k, b, s = env in 
              t.Generic.g (`Lambda, b, State.modify s x (e.Generic.f env)) k

            method m_Read (k, b, s) t x = 
              Printf.printf "%s < " x; 
              flush stdout;
              let y = int_of_string (input_line stdin) in
              t.Generic.g (`Lambda, b, State.modify s x y) k

            method m_Write env t e = 
              let k, b, s = env in
              Printf.printf "> %d\n" (e.Generic.f env); 
              flush stdout;
              t.Generic.g (`Lambda, b, s) k

            method m_If env t e s1 s2 = 
              let k, b, s = env in 
              (if e.Generic.f env = 0 then s2 else s1).Generic.f (k, b, s)

            method m_While env t e s1 = 
              let k, b, s = env in 
              if e.Generic.f env = 0 
              then t.Generic.g (`Lambda, b, s) k
              else s1.Generic.f (t.Generic.x ++ k, k, s) 

            method m_Seq (k, b, s) t s1 s2 =               
              s1.Generic.f (s2.Generic.x ++ k, b, s) 

            method m_Break (k, b, s) t = t.Generic.g (`Lambda, `Lambda, s) b

            method m_Lambda (k, b, s) t = s 
          end

      end

    ostap (
      parse: !(L.Stmt.parse)[L.Program.expr][fun p -> break p] -EOF;
      break[p]: "break" {`Break}
    )

    generic ('self, 'e) stmt = [('self, 'e) L.Stmt.t | 'self Stmt.t]
    
    let interpret s = 
      let fe (_, _, s) e = L.Expr.t.Generic.gcata (new L.Expr.eval) s e in 
      stmt.Generic.gcata fe (new Stmt.interpret) (`Lambda, `Lambda, State.empty) s

    let toplevel source =
      match L.Lexer.fromString parse source with
      | Checked.Ok p -> Checked.Ok (object 
                                      method code    = invalid_arg "Method \"code\" is not supported for this language level."
                                      method run     = interpret p
                                      method compile = invalid_arg "Method \"compile\" is not supported for this language level."
                                      method print   = invalid_arg "Method \"print\" is not supported for this language level."
                                    end)
      | Checked.Fail m -> Checked.Fail m

  end

module Procedures =
  struct

    module Expr =
      struct

        open List

        generic 'self t = 'self as [>
        | `Call of [string] *  ['self t list]
        ]

        class ['self] code =
          object
            inherit ['self, unit, string list] @t
            method m_Call _ expr name args = ["call"; name; string_of_int (length args)] @ flatten (map (expr.Generic.g ()) args)
          end

        open L.Lexer
        open Ostap.Util

        ostap (
          parse[expr]: f:ident "(" a:list[expr] ")" {`Call (f, a)}
        )

      end

    module Stmt =
      struct

        open List

        generic ('self, 'e) t = 'self as [>
        | `Proc of [string] * [string list] * [string list] * ('self, 'e) t
        | `Call of [string] * 'e * ['e list]
        | `Ret  of 'e
        ]

        class ['self, 'e] code =
          object
            inherit ['self, > 'e L.Expr.t, string list, unit, string list] @t
            method m_Proc _ stmt name args locals body = 
              let sl l = string_of_int (length l) :: l in
              ["proc"; name] @ (sl args) @ (sl locals) @ (body.Generic.f ())
            method m_Call _ stmt name phony args = ["call"; name; string_of_int (length args)] @ flatten (map (phony.Generic.g ()) args)
            method m_Ret  _ _ e = "ret" :: (e.Generic.f ())
          end

        open L.Lexer
        open Ostap.Util

        ostap (
          parse[expr][stmt]:
            "proc" name:ident 
                  "(" args:list[ident] ")" 
                  locals:(-"local" list[ident] -";")? 
                  body:stmt {
              `Proc (name, args, (match locals with Some l -> l | None -> []), body)
            }
          | "return" e:expr                           {`Ret e}
          | "call" name:ident "(" args:list[expr] ")" {`Call (name, hd args, args)}   
        )

      end

  end

module Arrays =
  struct

    module Expr =
      struct

        open List

        generic 'self t = 'self as [>
        | `Array of ['self t list] 
        | `Elem  of 'self t * 'self t
        ]

        generic 'self p = ['self L.Expr.t | 'self t | 'self Procedures.Expr.t]  

        class ['self] code =
          object (self)
            inherit ['self, unit, string list] @t
            method m_Array _ t l = ["{}"; string_of_int (length l)] @ flatten (map (t.Generic.g ()) l) 
            method m_Elem  _ _ a i = ["[]"] @ a.Generic.f () @ i.Generic.f ()
          end

        class ['self] gcode =
          object (self)
            inherit ['self] L.Expr.code
            inherit ['self] Procedures.Expr.code
            inherit ['self] code
          end

        let code e = p.Generic.gcata (new gcode) () e

      end
   
    module Stmt =
      struct

        generic ('self, 'e) t = 'self as [>
          `ArrayAssn of 'e * 'e * 'e
        ]

        class ['self, 'e] code =
          object (self)
            inherit ['self, 'e, string list, unit, string list] @t
            method m_ArrayAssn _ _ x i y = ["[]="] @ x.Generic.f () @ i.Generic.f () @ y.Generic.f ()
          end

        class ['self, 'e] gcode =
          object (self)
            inherit ['self, 'e Expr.p] L.Stmt.code
            inherit ['self, 'e Expr.p] Procedures.Stmt.code
            inherit ['self, 'e Expr.p] code
          end

        ostap (
          parse: !(L.Stmt.parse)[expr][fun p -> arrassn expr p] -EOF;
          arrassn[expr][p]: 
            !(Procedures.Stmt.parse)[expr][p]
          | x:!(L.Lexer.ident) e:xboct[`Var x][expr] ":=" e3:expr { 
              match e with 
              | `Elem (e1, e2) -> `ArrayAssn (e1, e2, e3) 
              | `Var x -> `Assign (x, e3)
              | _ -> invalid_arg ""
          };
          expr : !(L.Expr.parse) [primary];
          primary[p]:
            !(Procedures.Expr.parse)[expr]
          |  -x:!(L.Lexer.ident) xboct[`Var x][p]
          | i:!(L.Lexer.literal) {`Const i}
          | -"{" -h:p -t:(-"," p)* -"}" xboct[`Array (h::t)][p]
          | -"(" -x:p -")" xboct[x][p];
          xboct[x][p]: -"[" -i:p -"]" xboct[`Elem(x, i)][p] | !(Ostap.Combinators.empty) {x}
        )

        generic ('self, 'e) stmt = [ ('self, 'e) L.Stmt.t | ('self, 'e) t | ('self, 'e) Procedures.Stmt.t ]

        let code s = 
          stmt.Generic.gcata (fun _ e -> Expr.code e) (new gcode) () s

        let toplevel source =
          match L.Lexer.fromString parse source with
          | Checked.Ok p -> Checked.Ok (object 
                                          method code    = code p
                                          method run     = invalid_arg "Method \"run\" is not supported for this language level."
                                          method compile = invalid_arg "Method \"compile\" is not supported for this language level."
                                          method print   = invalid_arg "Method \"print\" is not supported for this language level."
                                        end)
          | Checked.Fail m -> Checked.Fail m

      end

  end