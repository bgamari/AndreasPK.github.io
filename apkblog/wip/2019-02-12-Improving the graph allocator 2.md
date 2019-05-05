---
title: Improving GHC's graph register allocator - Spill cost metrics.
tags: Haskell, GHC
---

In a recent post I wrote down the fix for the graph allocator running out of spill slots.

This post quickly goes over how GHC decides which registers to spill and some improvements
I made on that. These changes however don't tackle the fundamental issues leading to potentially [big performance issues](https://ghc.haskell.org/trac/ghc/ticket/7679)
that occure with certain programs.

Also a warning this post probably requires some knowledge about register allocation.

# What is a spill cost function anyway?

Given a set of variables, and a number of registers too small to store all variables
we have to choose which of these variables to spill to the stack.

For this we define a function from variable -> Int and pick the register giving us the lowest value.

## How to define a cost function in practice

We will look at the following values associated with variables:

* Life range - The number of instructions between assignment + after last use of an instruction.
* Uses - Reads or writes to a variable.
* Conflicts - Variables conflict with each other if at any point both values have to be stored.

Let's look again at the toy code from last post.
```C
  v1 = 1; // v1 live              
  v2 = 2; // v1,v2 live           
  v3 = 3; // v1,v2,v3 live        
  v4 = v1 + v2; // v3,v4 live     
  v4 = v4 + v3; // v4 live  
```

For example looking at v4 we get:
* Liferange: 1
  It's only alive for the last instruction after assignment.
* Uses: 3
  It's assigned, then read and assigned again.
* Conflicts: 1
  It overlaps with v4 before the last instruction.

There can be other ones as well but these are easily used within GHC so
we will stick with those.

The spill cost function is now a function from these values to a cost value.  
A common one in literature based on a paper by Chaitin is `uses/conflicts`.

# What is GHCs current metric?

The current cost function is simply `1/liferange`.  
This will always spill the longest liferange.

This works surprisingly well. But it breaks down if a variable is used often throughout a large part of a function.

# Simple Improvements

The register allocator assigns variables to registers.
When we run out of registers we fall back and also use the stack as storage space.

Running out of registers is usually not a huge deal but it's what triggers this bug.
For a simple example consider the naive code below and assume we only have two registers available.

I've added comments with variables live after each statement and a possible register assignment.

```C
  int v1,v2,v3,v4;

  v1 = 1; // v1 live          | registers: (v1,empty)
  v2 = 2; // v1,v2 live       | registers: (v1,v2)
  v3 = 3; // v1,v2,v3 live    | registers: ???
  v4 = v1 + v2; // v3,v4 live | registers: (v4,v3)
  v4 = v4 + v3; // v4 live    | registers: (v4,empty)

  return v4;
```

In the line with the register assignment `???` we run into the issue of having more values
than we can keep in registers.

The solution is rather simple. We *spill* on of the values from a register to the stack (memory). Loading it again before we need it.
How to determine a good choice for WHICH value to move into memory is complicated but not important for this bug.

Skipping over quite a lot of details our assignments might look something like this now if we include spilling:

```C
  int v1,v2,v3,v4;

  v1 = 1; // v1 live              | registers: (v1,empty)     stack: []
  // <spill v1>                   | registers: (empty,empty), stack: [v1]
  v2 = 2; // v1,v2 live           | registers: (empty,v2),    stack: [v1]
  v3 = 3; // v1,v2,v3 live        | registers: (v3,v2),       stack: [v1]
  // <spill v3>                   | registers: (empty,v2),    stack: [v1,v3]
  // <load  v1>                   | registers: (v1,v2),       stack: [v3]
  v4 = v1 + v2; // v3,v4 live     | registers: (v4,empty),    stack: [v3]
  // <load  v3>                   | registers: (v4,v3),       stack: []
  v4 = v4 + v3; // v1,v2,v3 live  | registers: (empty,v4)     stack: []

  return v4;
```

## The actual issue.

Currently, just like we can run out of registers we can run out of stack space.  

The reason is that currently the graph allocator preallocates a certain amount of
stack space (refered to as spill slots) for us to spill variables.

```
-- Construct a set representing free spill slots with maxSpillSlots slots!
    (mkUniqSet [0 .. maxSpillSlots ncgImpl]) 
```

But if we ever try to spill more variables than we have free slots the compiler just gave up and paniced.

```
ghc SHA.hs -fregs-graph -O -fforce-recomp +RTS -s
[1 of 1] Compiling Data.Digest.Pure.SHA ( SHA.hs, SHA.o )
ghc.exe: panic! (the 'impossible' happened)
  (GHC version 8.6.3 for x86_64-unknown-mingw32):
        regSpill: out of spill slots!
     regs to spill = 1525
     slots left    = 1016
  Call stack:
      CallStack (from HasCallStack):
        callStackDoc, called at compiler\utils\Outputable.hs:1160:37 in ghc:Outputable
        pprPanic, called at compiler\nativeGen\RegAlloc\Graph\Spill.hs:59:11 in ghc:RegAlloc.Graph.Spill

Please report this as a GHC bug:  http://www.haskell.org/ghc/reportabug
```

## The fix

The same issue plagued the default (linear) register allocator at some point but has been [fixed](https://git.haskell.org/ghc.git/commitdiff/0b0a41f96cbdaf52aac171c9c58459e3187b0f46)
back in 2012.

We spill to the C stack so we "only" have to bump the stack pointer wenn calling functions and reset it when returning from calls.
It's of course [not](https://ghc.haskell.org/trac/ghc/ticket/16166) so [simple](https://ghc.haskell.org/trac/ghc/ticket/15154) as there are all
kinds of edge cases but most of these got fixed by Phyx already!

So all that remained was to resize the set for available spill slots instead of panicing.
Then we can simply reuse the same machinery the linear allocator uses to make sure there is enough stack space and things work out.

This mostly involved adding a parameter for spill slots used to functions. So the actual work was [not really complicated](https://gitlab.haskell.org/ghc/ghc/merge_requests/219).

And soon no sane code will panic when used from the graph register allocator.
```
$ /e/ghc/inplace/bin/ghc-stage2.exe SHA.hs -fregs-graph -O -fforce-recomp +RTS
[1 of 1] Compiling Data.Digest.Pure.SHA ( SHA.hs, SHA.o )

Andi@Horzube MINGW64 /e/graphTest
```

# Other issues

This does however NOT make the graph allocator unconditionally better.

It's better for most code
but the performance can break down completely under certain conditions.  
These [performance issues](https://ghc.haskell.org/trac/ghc/ticket/7679) have been there for some time
and this won't fix these.  
But now you can at least see if it works better for your code
without running into unfixable panics.

I also have some ideas to improve the performance of the graph allocator. But properly tackling these will be
a another larger project.

