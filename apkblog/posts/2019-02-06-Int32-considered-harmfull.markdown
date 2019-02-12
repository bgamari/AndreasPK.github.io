---
title: Sized Int/Word variants considered Harmful.
---

Most users are probably aware of the sized Int/Word variants from `Data.Int` and `Data.Word`.  
However there are some pitfulls associated using them in places where we could use regular Int.

We will take a look at the [Int ones](https://hackage.haskell.org/package/base-4.12.0.0/docs/Data-Int.html#t:Int8)
but this will apply for sized Word types as well.

# Why I consider the sized variants harmful

## Pitfall #1: They take up at least as much space as Int does

One might be tempted to change some code to Int8, expecting this to safe memory.
However if we look at the actual implementation it becomes clear Int8/Int take up
the same amount of memory.

```Haskell
------------------------------------------------------------------------
-- type Int8
------------------------------------------------------------------------

-- Int8 is represented in the same way as Int. Operations may assume
-- and must ensure that it holds only values from its logical range.

data {-# CTYPE "HsInt8" #-} Int8 = I8# Int#
-- ^ 8-bit signed integer type
```

Int# stands for unboxed Integer values with 32 or 64bit depending on the machine.  
So each Int8 takes two words. One for the constructor and one for the actual value. Same as regular Int.

## Pitfall #2: They generate worse code

We know Int8 for example is backed by a full machine word. But we want to maintain overflows like we would expect in C.
So when we generate code we have to zero out unused parts of memory for each intermediate result.

This often boils down to inserting an extra instruction (or a special mov) for each intermediate value.
This is not horrible, but it does add up.

## Pitfall #3: Missing Rules

GHC has many rules to optimize common constructs, replacing them with more efficient implementations.
For example there is a more efficient implementation for `[0..n]` when we use Int.  
There are no equivalent rules for the sized variants so these can perform a lot worse.

There is a [ticket](https://ghc.haskell.org/trac/ghc/ticket/15185) about the issue as well.

## Drawback #4: Int64 in particular can be very slow on 32bit.

One would expect certain functions to be translated into only a handfull of assembly instructions.  
However on 32bit systems the 64 bit primitive operations are implemented as function calls, with according overhead.

Here is a [GHC Ticket](https://ghc.haskell.org/trac/ghc/ticket/5444) about the issue.

# When is it ok to use these then?

* They can be helpful to represent FFI APIs as they map nicely to `char`, `short`, ...
* If you need the overflow/value range behaviour of these types they are also a valid choice.
* If you work with unboxed data structures. Like these provided by Data.Vector.  
  They are backed by a bytearray so in theses cases the small variants actually take less space.

# How bad can it be?

As a showcase you can take the code below and run it.

I've defined IT once as `Int8` and once as `Int` and the runtime difference is about 30% on my machine.
I did however NOT check how much of that comes from missing rules and how much from the overhead of zeroing.

```Haskell

import GHC.Exts
import Data.Int
import System.Environment

type IT = Int

foo :: IT -> IT -> IT -> IT
foo x y z = x + y + z

times :: Int -> [IT] -> [IT]
times n xs = concat $ replicate n xs

main = do
  print $ sum $ map (\(x,y,z) -> foo x y z) [(x,y,z) | x <- 10 `times` [0..127]
                                            , y <- 10 `times` [0..127]
                                            , z <- 1  `times` [0..127]]
```