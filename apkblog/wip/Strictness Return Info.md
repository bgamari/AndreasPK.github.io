Tickets: https://ghc.haskell.org/trac/ghc/ticket/10606 - avoid redundant stores to the stack when examining already-tagged data



It's still a bit vague and I want to talk about this in the next call,
but I would appreciate if you could think this over before then.

So the basic idea is that we attach strictness information about return values to functions.
Then at call sites we can make use of this information to avoid redundant evaluations.

For simplicity consider these two functions, and let's for a moment ignore Int unboxing.



{-# NOINLINE foo #-}
foo :: Int -> (Int,Int)
foo x =
let !x1 = x+1
!x2 = x-1
in (x1,x2)



{-# NOINLINE bar #-}
bar :: Int -> Int
bar !x =
let (x1,x2) = foo x
in x1 + x2


foo is subject to CPR so under the hood we return a unboxed tuple, so we actually return the two values directly instead of a tuple of them.
We also know that the values inside the returned tuple have been evaluated because we explicitly did so.

However currently the code for bar looks something like this in pseudo code:

stackCheck
if (!evaluated(x))
    evaluate x;
x1,x2 =  workerFoo x

if(!evaluated(x1)
    evaluate x1
if(!evaluated(x2)
    evaluate x2

heapCheck
return (x1+x2)

The checks in the middle are redundant, we already know that x1/x2 have already been evaluated,
and code like this isn't too uncommon to avoid thunk leaks.

I will spare you the assembly code, but out of 40 instructions inside of bar these checks make up 13. Thats over 30%!

The impact will be lower in production code since inlining get's rid of many of these instances. But it might still be worth it.

Here comes the slightly more vague part for an solution.
Bear with me, and also caution code snippets are in Core Syntax.


For strictness info we can have a (recursive) format:

L[U] -> This binding has unknown evaluation status and we don't know what it will evaluate to. This is always a safe assumption.
L[C](s1,s2,..,sn) -> L when demanded will reduce to Constructor C, with constructor arguments having strictness info [s1,s2,..]
L[[C1 -> (s1..sn), C2 -> s(s1..sn), _ -> U] -> We might not know WHAT constructor a binding will evaluated to, but can still make a statement about it's arguments once we know.
S[C](s1,s2,..,sn) -> The binding represents a Constructor C, already evaluated and applied to arguments with strictness [s1,s2,..]



Now we associate strictness info with each functions return value.

When add this info to all functions as follows:
(Feel free to skip this for now there are examples down below)

Step1: Assume each function we call from the body already annotates the return value with strictness  information.
Step2: Traverse the functions AST
* For each point in the AST we keep a mapping from bindings to their strictness info.
* We map expressions to strictness information as follows:
    * Saturated known calls of the form "f n1 n2 .. ni" have the strictness info associated with f.
    * A fully applied constructor C e1 e2 ... has strictness L[C](info(e1), info(e2), ...)
        * For bindings  info(var) is mapped to the info of the binding
        * For expressions info(e) is made lazy and details are assigned by analyzing e.
    * Variables have the info of their binding.
    * Case statements have as info a map [C1 -> altExpr1, C2 -> altExpr2], ...
    * Lambdas have strictness of the body.
    * Other expressions are treated as Lazy Unknown: L[U]
* Bindings
    * Are mapped to the info of the expression they bind, but with the outermost strictness made lazy.
    * In the rhs we add this info to our strictness info mapping.
* For case statements
    *  We update the info with additional information from the case.
        -- For simplicity for now ignore seq
        * case x:L[U] of _ -> e   [x: L[U]]
        -- Lazy known constructor becomes strict known
        * case x:L[C(..)] of _ -> e   [x: S[C](..)] -> It's strict know!
        -- Lazy set of constructor becomes either strict known constructor or unknown for things not in our map
        * case x:L[[C1-> s1', C2 -> s2'] of
                C1 {} -> e   [x: S[C1](s1')]
                C2 {} -> e   [x: S[C1](s1')]
                C3 {} -> e   [x: L[U])]
                _ -> e [x: L[U])]
        -- Strict known constructors alway stay that way
        * case x:S[C](s') of ... -> e  [x:S[C](s')]
    * Alternatives obviously can also bring bindings in scope. If possible these get info from the scrutinee.
        * case f x :L[C](S[C1],[S[C2]) of
                C p1 p2 -> e : [p1: S[C1], p2: S[C2] ]
        Step3: The strictness info associated with function return is than the info of the rhs with
    the outermost layer made strict.

This would give us for our foo function above (ignoring ww) the Strictness return information:

foo = S[(,)] (S[I#]( S[Int#]() ), S[I#]( S[Int#]() ))
=> Returns a tuple of fully evaluated ints.

This means in the code:
let (x1,x2) = foo x
in x1 + x2
We know x1,x2 are already evaluated and can skip the check for that during codegen, hurray!

Further we can do a bit of compile time evaluation!

Consider a function with return type Either Int (Maybe Double), which will always return Just in the Right case.
case x of
1 -> Left (1,2)
2 -> Right $! Just $! fromIntegral y
With the following call site:
case bla e 5 of
Left i1 -> fromIntegral i1 + n
Right (Just dbl) -> dbl + n
_ -> error "impossible"

Right now GHC both checks if the Maybe value is evaluated AND if it is Nothing.

        Right ds_d3mN ->
          case ds_d3mN of {
            Nothing -> case func1 of wild2_00 { };
            Just dbl_a1uH ->
              case dbl_a1uH of { D# x_a3PZ -> +## x_a3PZ ww1_s4fg }
          }

But using the analysis described above we would know that if we got a Right constructor
then the Maybe value has already been evaluated to Just!

So we could simplify the code to

        Right ds_d3mN ->
          case ds_d3mN of { Just dbl_a1uH ->
          case dbl_a1uH of { D# x_a3PZ -> +## x_a3PZ ww1_s4fg }
          }

This works since we will have the entry [ds_d3mN : S[Just] (..)]

I think the idea as is is quite elegant. We only have to go over the AST once,
and it's trivial to just assume for unknown information for things like unknown calls.


