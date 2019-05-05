---
title: 2020-02-24 GHC Internals - Case of Case
tags: Windows, Compiler, Assembly, GHC
---

# This post dives into GHC's of the case of case implementation.

I'm currently working on a prototype for [LIKELY pragmas](https://github.com/AndreasPK/ghc-proposals/blob/master/proposals/0000-likelihood-annotations.rst).

For the MOST part how to keep weights sane while optimizing was straight forward.  
However one part involving the simplifier turned out quite tricky so I'm documenting the parts
I worked on here.

We will first quickly cover my problem, then jump into the middle of the simplifier code
and I will try to explain things as they become relevant.

So this is not a guide to the simplifier! But it will cover case of case and some other parts
which might be interesting/helpful.

# The problem:

We want to tell the compiler that we don't expect x to be equal to A so we set weights like this:

~~~ haskell

data T = A | B | C deriving Eq

foo :: T -> Int
foo x
    | A == x =
        {-# LIKELY 0 #-}
        1 :: Int
    | otherwise
    =   {-# LIKELY 100 #-}
        2 :: Int
~~~ 

After the first run through the simplifier we inline the Eq instance, apply some magic and end up with this code.

~~~ haskell
foo
  = \ x_a200 ->
      case case x_a200 of {
             __DEFAULT(Weight: c1000) -> False;
             A(Weight: c1000) -> True
           }
      of {
        False(Weight: u100) -> I# 2#;
        True(Weight: u0) -> I# 1#
      }
-- Which turns into this in the next run of the simplifier:
foo
  = \ x_a200 ->
      case x_a200 of {
        __DEFAULT(Weight: c1000) -> lvl_s226;
        A(Weight: c1000) -> lvl_s227
      }
-- But what we wanted is this:
foo
  = \ x_a200 ->
      case x_a200 of {
        __DEFAULT(Weight: u100) -> lvl_s226;
        A(Weight: u0) -> lvl_s227
      }
~~~


The first part is good. We have the user specified weights prefixed with u (u0/u100), and the default weights prefixed with c (c1000).

However the simplifier eliminates the outer case (that being the one branching on True/False). 
It also just throws away the weight info from these branches.
Even worse they get replaced by weights from the inner case no matter what they were!

So we might end up with wrong information, clearly something we don't want.

## Why does this happen and how?

Generally this transformation is a good thing, as it's easy to realize that here we ended up with a single case instead of two.  
But with the introduction of weights we have to update it to better deal with this information.

So when/why do the weights actually disappear?  
The simplifier does the following in one sweep:

* Inline the outer case into the inner case.
* Apply known constructor to the now inlined case.
* Remove the now redundant inlined case and replac it with the rhs of the True/False alternative.

In terms of code this would look something like this:
~~~ haskell
-- We start of with a case of a case
case case x_a200 of {
        __DEFAULT(Weight: c1000) -> False;
        A(Weight: c1000) -> True
      }
of {
  False(Weight: u100) -> I# 2#;
  True(Weight: u0) -> I# 1#
}

-- Inline the (outer) case, essentially swapping inner with outer.

case case x_a200 of {
        __DEFAULT(Weight: c1000) -> 
            case False of {
                False(Weight: u100) -> I# 2#;
                True(Weight: u0) -> I# 1#
                };
        A(Weight: c1000) -> 
            case True of {
                False(Weight: u100) -> I# 2#;
                True(Weight: u0) -> I# 1#
                }
      }

-- Apply the known Constructor optimization

case case x_a200 of {
        __DEFAULT(Weight: c1000) -> 
                False(Weight: u100) -> I# 2#;
        A(Weight: c1000) -> 
                True(Weight: u0) -> I# 1#
      }

~~~ 

The problem is however that there is only a (very abstract) representation of these steps in the simplifier.  
Let's look at our playground:

## The Simplify Module

This 3,6k LOC Module is at the heart of many of GHC's optimizations.

### rebuildCase

After some digging I found out that case of case is gated by `rebuildCase`.

~~~ haskell
rebuildCase, reallyRebuildCase
   :: SimplEnv
   -> OutExpr          -- ^ Scrutinee
   -> InId             -- ^ Case binder
   -> [InAlt]          -- ^ Alternatives (inceasing order)
   -> SimplCont
   -> SimplM (SimplFloats, OutExpr)
~~~

We will ignore the SimplEnv, it's there to facility subtitutions, think let which doesn't really apply to our issue.

As for the rest we can apply printf debugging to find out the parameters:
~~~ haskell
  -- We branch on our functions parameter x
  scrut x{v a200}[lid]
  -- Irrelevant - we bind the result of the case to wild1
  case_bndr wild1{v i21P}[lid]
  -- Our case alternatives
  alts [(__DEFAULT(Weight: c1000), [], False{(w) v 6d}[gid[DataCon]]),
        (A{d r2}  (Weight: c1000), [], True{(w)  v 6K}[gid[DataCon]])]
  -- The continuation.
  cont' Select ok wild_Xa{v}[lid]
          []
          [(False{(w) d 6c}(Weight: u100), [], lvl_s226{v}[lid]),
           (True{(w) d 6J}(Weight: u0), [], lvl_s227{v}[lid])]
        Stop[BoringCtxt] Int{(w) tc 3u}
~~~

The continuation requires a better explaination.

### SimplCont - Continuations

This is a neat trick. Consider this case statement:

~~~ haskell
case e1 of { A -> e2; B -> e3 }
~~~

The intuitive thing would be to optimize e1 to e1', return that expression
and then return the alternatives.  
However when optimizing e1 we might find out that we don't even have to care about e2/e3 anymore.

So instead we have the data structure SimplCont which represents the code surrounding our expression
and it get's passed along together with the expression. Once we finished optimizing the expression
we call a function `rebuild` that rebuilds the complete expression based on the continuation and expression.

So rebuild would perform the following steps:

* Optimize e1 to e1'
* Look at e1' to determine if the case is still needed.
* Rebuild and optimize the rest of the case if it is required.

This also applies to function applications, ticks, casts, .. but we don't care about these for our problem.

The continuation for cases looks like this:

~~~ haskell
  | Select             -- (Select alts K)[e] = K[ case e of alts ]
      { sc_dup  :: DupFlag        -- See Note [DupFlag invariants]
      , sc_bndr :: InId           -- case binder
      , sc_alts :: [InAlt]        -- Alternatives
      , sc_env  :: StaticEnv      -- See Note [StaticEnv invariant]
      , sc_cont :: SimplCont }
~~~

These can be nested and so on.

So really a complete case expression is then often represented as an Expression for the scrutinee and a continuation which contains
the rest of the case.

This is also the case in our call to rebuildCase! Only the our scrutinee expression also happens to be a case!
If we insert traces we can see it also returns the simplified case with weights removed so let's look at it in detail.

### RebuildCase - Part 2

`rebuildCase` catches multiple cases, most of wich we don't care here:

* Eliminate case for known constructors - relevant later.
* Turn a case into a let for evaluated scrutinees
* Rebuild the case from the expression and continuation.

Our call currently matches the third case which just calls the aptly named `reallyRebuildCase`.

Here is the code with a few explainations applying to the call above:

~~~ haskell
reallyRebuildCase env scrut case_bndr alts cont
  | not (sm_case_case (getMode env))   -- Case of case disabled
  = do -- simplAlts returns a case expression with the alternatives simplified.
       { case_expr <- simplAlts env scrut case_bndr alts
                                (mkBoringStop (contHoleType cont))
       ; rebuild env case_expr cont }
       -- This would reconstruct the outer case.

  | otherwise
  = do
       { (floats, cont') <- mkDupableCaseCont env alts cont
      -- simplAlts does the actual caseOfcase optimization.
       ; case_expr <- simplAlts (env `setInScopeFromF` floats)
                                scrut case_bndr alts cont'
       ; return (floats, case_expr) }
~~~

`mkDupableCaseCont` is rather straight forward. Since the outer case which is stored
in the continuation can be inlined into multiple alternatives we lift expressions out
of the alternatives to avoid duplicating code.

`simplAlts` itself does things like filtering irrelevant alternatives. But for our case what
is interesting is the call to simplAlt for each case alternative.

~~~ haskell
    alts' <- mapM (simplAlt alt_env' (Just scrut') imposs_deflt_cons case_bndr' cont') in_alts
~~~
        
Because `simplAlt` is where the case of case magic happens.

### simplAlt

For simplicity we look only at the default variant of simplAlts, but they all do the same thing.

~~~ haskell
simplAlt :: SimplEnv
         -> Maybe OutExpr  -- scrutinee
         -> [AltCon]       -- These constructors can't be present when
                           -- matching the DEFAULT alternative => 
         -> OutId          -- The case binder
         -> SimplCont
         -> InAlt
         -> SimplM OutAlt
simplAlt env _ imposs_deflt_cons case_bndr' cont' (def@DEFAULT{}, bndrs, rhs)
  = ASSERT( null bndrs )
    do  { let env' = addBinderUnfolding env case_bndr'
                                        (mkOtherCon imposs_deflt_cons)
                -- Record the constructors that the case-binder *can't* be.
        ; rhs' <- simplExprC env' rhs cont'
        ; return (def, [], rhs') }
~~~

While addBinderUnfolding is important, it's irrelevant to our situation.  
This leaves the call to `simplExprC`.

### Simplifiying the RHS

`simplExprC` simplifies a single expression and returns it. In our case the arguments
to it will be `{ rhs = True, cont' ~ OuterCase }`.

The outer case in SimplCont is passed along through the chain below:

* simplExprC calls simplExprF and deals with any things floated out by it.
* simplExprF will call simplIdF, which makes sure the RHS of our inner case can't be further simplified.
* eventually we call rebuild with `{ expr = True, cont ~ OuterCase }` which takes apart the continuation
  and calls into rebuildCase with the kown scrutinee `True`
* rebuildCase then eliminates the case.

## Towards a solution.

Now what I need when looking at the call stack is for rebuildCase to pass back up the information
about which cases where eliminated.  
But there is an issue, simplExprF/C is called **extremely** often. So besides the work of changing the
return type it's just not an option for performance reasons.

### What about continuations.

What we need is simplExprC to "return" the eliminated weights.

We can't actually return the values, but we can just pass enough information
via continuation to achieve the same effects.

So we need:

simplAlts to pack the case + alternatives in a continuation. Let's call that one `OptCase`.

~~~ haskell
OptCase
  { scrut :: _
  , case_bndr :: _
  , optimizedAlts :: [(OutAlt, Maybe WeightInfo)]
  , remainingAlts :: [InAlt]
  , cont :: SimplCont
  }
~~~

simplAlts then fills in these values and instead of mapping simplAlt over the alternatives calls rebuild.

We then add a rebuildAlt function doing essentially what simplAlt did so far, but instead of returning
a case expression directly it updates the continuation and recalls rebuild.  
Once all alternatives have been updated THEN rebuild will return the optimised case expression.

So our control flow is something like this:

* + simplExprF sees it's a case, builds a Select continuation and
  calls simplExprF on the scrutinee.
* + simplExprF sees it's a case, builds a Select continuation and
  calls simplExprF on the scrutinee. (so we have two Select continuations)
* + optimize that scrutinee
* + we call rebuild with the optimized inner scrutinee (which eg is `x` in our example)
* + This calls rebuildCase with the case expression in arguments, only the scrut optimized.
  This removes the inner case continuation.
* + We eliminate the case if possible (applies iff case of case doesn't)
* ~ call simplAlts -> Eliminates the outer case continuation by inlining it.
* ~ mapM simplAlt

Instead after failing to simply eliminate the case we want to:
* Optimize the alternatives rhss.
* Call `rebuild scrut` with a special continuation that contains initially for each alternative
  the continuation (shared between alternatives!)
* 

* rebuild jumps into `rebuildAlts scrut alts` which:
  * if the rhss are not optimized:
    * simplify the rhs of each alt to rhs'
  * call rebuild with rhs' and the continuation.
    * rebuild re

So we encode State in the Continuation.

~~~ haskell
type CoreExprF = (SimplFloats, Expr)

rebuildAlt :: _ -> SimplCont -> CoreExprF
...
  | allAltsOptimized cont
  = determineWeights cont
  | otherwise
  = let alt = unoptimizedAlt cont
        rebuild
    in  rebuild 
~~~