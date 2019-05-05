---
title: Tracking down "\#11532"
tags: Haskell, GHC
---

# This is an experience report on how I tracked down the issue reported by Mikolaj Konarski

It later turned out the bug I fixed was not the original bug. But still one bug down.

I really want to say how helpful Mikolaj Konarski was in getting this fixed.  
Without his willingness to help us reproduce this I couldn't have fixed this.

In particular he couldn't reproduce the error locally only on CI. So our debug loop was:  
* I recommend flags to try out
* He runs CI
* I look at the logs
* Repeat.


## The problem

´´´ 
[105 of 111] Compiling Game.LambdaHack.Server.PeriodicM ( engine-src/Game/LambdaHack/Server/PeriodicM.hs, /tmp/dist-test.wOfc/LambdaHack-0.9.2.0/dist-newstyle/build/x86_64-linux/ghc-8.4.4/LambdaHack-0.9.2.0/build/Game/LambdaHack/Server/PeriodicM.o )
ghc: panic! (the 'impossible' happened)
  (GHC version 8.4.4 for x86_64-unknown-linux):
	LocalReg's live-in to graph
  cy18M {_B1::P64}
  Call stack:
      CallStack (from HasCallStack):
        callStackDoc, called at compiler/utils/Outputable.hs:1150:37 in ghc:Outputable
        pprPanic, called at compiler/cmm/CmmLive.hs:70:8 in ghc:CmmLive
´´´

## First instincts

I have played around with Cmm - think of it as similar to Llvm bytecode - in the past.  
Often that kind of error happens if a register is used but not initialized.

The possible reasons for that are many but often it's some kind of code movement gone wrong.

So I asked him for the debug output for the Cmm passes. But that produced a log too large for
CI.  
Next thing to try was to disable these passes.

Progress?  
´´´ 
[105 of 111] Compiling Game.LambdaHack.Server.PeriodicM ( engine-src/Game/LambdaHack/Server/PeriodicM.hs, /tmp/dist-test.tXeP/LambdaHack-0.9.2.0/dist-newstyle/build/x86_64-linux/ghc-8.4.4/LambdaHack-0.9.2.0/build/Game/LambdaHack/Server/PeriodicM.o )
ghc: panic! (the 'impossible' happened)
  (GHC version 8.4.4 for x86_64-unknown-linux):
	allocateRegsAndSpill: Cannot read from uninitialized register
  %vI_B1
  Call stack:
      CallStack (from HasCallStack):
        callStackDoc, called at compiler/utils/Outputable.hs:1150:37 in ghc:Outputable
        pprPanic, called at compiler/nativeGen/RegAlloc/Linear/Main.hs:769:20 in ghc:RegAlloc.Linear.Main
´´´ 

This error is analog to the earlier one caused by reading from a register that has not been initialized.

So it seems it's not a Cmm optimisation causing this after all.

## Ruling out Cmm optimizations as the culprint.

So again using different flags we finally managed to look at the faulty code:

´´´C
{
  cy18M:
      _X3a::P64 = R2;
      _sxY78::P64 = R1;
      goto cy18O;
  cy18O:
      _sxY74::P64 = P64[_sxY78::P64 + 7];
      _sxY76::P64 = P64[_sxY78::P64 + 15];
      R3 = _B1::P64;
      R2 = _sxY76::P64;
      R1 = _sxY74::P64;
      call go2_sxY74_info(R3, R2, R1) args: 8, res: 0, upd: 8;
}
´´´

R2 and R1 are global registers and as such always considered live.
However _B1 is not, and is read without having ever been written to.

Using yet another set of flags I also looked at the Cmm code produced before we apply any optimizations
and that was already faulty.

## Going up the pipeline.

Next I looked at the stg code. Which was well over 10k lines long.

In Cmm the error occured in `lvl33_sxY78_entry` which is our encoding of a function/binding
called lvl33_sxY78 in STG so I only had to grep the code.





 optimisations

Reporter

The substitution is performed by substBndr:

```Haskell
substBndr :: CseEnv -> InId -> (CseEnv, OutId)
substBndr env old_id
  = (new_env, new_id)
  where
    new_id = uniqAway (ce_in_scope env) old_id
    no_change = new_id == old_id
    env' = env { ce_in_scope = ce_in_scope env `extendInScopeSet` new_id }
    new_env | no_change = env' { ce_subst = extendVarEnv (ce_subst env) old_id new_id }
            | otherwise = env'
```

`new_id` is unsurprisingly a new unique variable name.
`no_change` checks if new and old id are the same. This happens if the original id was not shadowed so we can keep it around.
`env` is the original environment, only with `new_id` added to the in scope set. So far so good.

We already know that `new_env` is bogus. Looking at the code we can see that:

* If there was **no** change we **add** a substitution from `old_id` to `new_id`.
* If there **was** a change we **don't** add a substitution.

That does not seem right!  
If we replaced x with y in f x = ... x ... then clearly we want to replace both occurences of x!

This bug has been present ever since commit `19d5c731` which added the STG CSE pass.  
So it must be hard to trigger.

For this to be an issue it requires:
* A binding B to be shadowed by another binding B'
* The shadowing binding (B') to be used.
* The two bindings to 
  + either refer to different values
  + B not being directly accessible according to STG rules




Fix faulty substitutions in StgCse (#11532).

`substBndr` should rename bindings which shadow existing ids.
However while it was renaming the bindings it was not adding proper substitutions
for renamed bindings.
Instead of adding a substitution of the form `old -> new` for renamed
bindings it mistakenly added `old -> old` if no replacement had taken
place while adding none if `old` had been renamed.

As a byproduct this should improve performance, as we no longer add
useless substitutions for unshadowed bindings.




