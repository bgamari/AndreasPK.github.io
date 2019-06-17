---
title: Taking a look at how GHC creates Unique Ids
tags: Haskell, GHC
---

This post looks at `one of the most hammered bits in the whole compiler`, namely GHC's unique supply.

GHC requires a steady supply of unique identifiers for various reasons.
This is nothing special by itself. But I find the implementation quite interesting especially given how much it is used.

Towards the end there is some speculation about the performance impact of this code.

# The UniqSupply type

```haskell

-- | Unique Supply
--
-- A value of type 'UniqSupply' is unique, and it can
-- supply /one/ distinct 'Unique'.  Also, from the supply, one can
-- also manufacture an arbitrary number of further 'UniqueSupply' values,
-- which will be distinct from the first and from all others.
data UniqSupply
  = MkSplitUniqSupply {-# UNPACK #-} !Int -- make the Unique with this
                   UniqSupply UniqSupply
                                -- when split => these two supplies
```

# Making use of the supply

The principle seems easy. This being Haskell we have an infinite Tree, with
each node containing one unique.
The reason for using a Tree over a list is simple, it allows us to pass a supply
into pure functions without them ever needing to return their final supply.

Taking uniques and splitting the supply when we need to pass one into a function
is done with these two functions (and a small growth of utility wrappers around them).

```haskell
takeUniqFromSupply (MkSplitUniqSupply n s1 _) = (mkUniqueGrimily n, s1)
splitUniqSupply (MkSplitUniqSupply _ s1 s2) = (s1, s2)
```

`mkUniqueGrimily` just wrapps the actual Int in a newtype.

There is one issue here, our Unique space is limited to the Int range.
So if we don't want to half the available uniques with each split how exactly
are we generating our infinite data structure?


# Oh no - IO: Generating the magic Uniq Supply

Here is the code:

```haskell
mkSplitUniqSupply :: Char -> IO UniqSupply
-- ^ Create a unique supply out of thin air. The character given must
-- be distinct from those of all calls to this function in the compiler
-- for the values generated to be truly unique.
mkSplitUniqSupply c
  = case ord c `shiftL` uNIQUE_BITS of
     mask -> let
        -- here comes THE MAGIC:

        -- This is one of the most hammered bits in the whole compiler
        mk_supply :: IO UniqSupply
        mk_supply
          -- NB: Use unsafeInterleaveIO for thread-safety.
          = unsafeInterleaveIO (
                genSym      >>= \ u ->
                mk_supply   >>= \ s1 ->
                mk_supply   >>= \ s2 ->
                return (MkSplitUniqSupply (mask .|. u) s1 s2)
            )
       in
       mk_supply
```

`genSym` is an IO action which generates a new unique integer each time it's run, which we will look at later.


## The boring parts:

The Char argument is stored in the higher order bits for each unique supply and preserved acroos splits.
So we build a mask which get's applied to each integer using logical or.
It encodes where uniques are generated. For example uniques produced by the native backend will use `'n'`.

## `mk_supply`

The actual code to generate an uniqe supply is `mk_supply`.

The first which stands out is `unsafeInterleaveIO`:

`unsafeInterleaveIO allows an IO computation to be deferred lazily. When passed a value of type IO a, the IO will only be performed when the value of the a is demanded`

If we squint really hard this seems like turning UniqSupply into: `MkSplitUniqSupply !Int (IO UniqSupply) (IO UniqSupply)`.
The IO however is hidden with the power of unsafeInterleaveIO.

This means whenever we split an UniqSupply and look at the result what we are really doing is running the mk_supply action:
```haskell
      genSym      >>= \ u ->
      mk_supply   >>= \ s1 ->
      mk_supply   >>= \ s2 ->
      return (MkSplitUniqSupply (mask .|. u) s1 s2)
  ```

This doesn't seem too complicated:  
* We get a new number from genSym
* New (unevaluated) supplies using mk_supply
* And return them inside a new MkSplitUniqSupply.

This is quite handy isn't it!

## genSym

`genSym` is implemented using the C ffi and in fact is very simple:

```C
HsInt genSym(void) {
#if defined(THREADED_RTS)
    if (n_capabilities == 1) {
        GenSymCounter = (GenSymCounter + GenSymInc) & UNIQUE_MASK;
        checkUniqueRange(GenSymCounter);
        if(GenSymCounter % 100 == 0)
          printf("Unique:%ull \n",GenSymCounter);
        return GenSymCounter;
    } else {
        HsInt n = atomic_inc((StgWord *)&GenSymCounter, GenSymInc)
          & UNIQUE_MASK;
        checkUniqueRange(n);
        return n;
    }
#else
    GenSymCounter = (GenSymCounter + GenSymInc) & UNIQUE_MASK;
    checkUniqueRange(GenSymCounter);
    return GenSymCounter;
#endif
}
```

The only complicated part is for the multi threaded case.
Here we rely on atomic increment to avoid two threads getting the same result.

# Does it make sense to optimize this further?

There are always things to improve, but let's figure out if we should bother:

## Some metrics:

We can find out using printf in getSym that GHC generates 170k Uniques for a testfile in 5 seconds.

This means **34000 Uniques/Second**.

For a **speedup by 0.1%** we need to shave off ~0.001 seconds. For my notebook runnint at 2.6GHZ this is **2 600 000 Cycles** or
**~75 Cycles per UniqueSupply creating**.

To make sense of this numbers here are some scales for my desktop CPU:

* L1 cache miss: 12 Cycles
* L2 cache miss: 40 Cycles
* Branch missprediction: 16-20 cycles.

## So is it worth it to try?

I don't think it's worth to try to optimize the current approach. It's pretty much as good as it will get.

One thing that might be worth looking into is turning it i
I think not. It would take a lot of effort to get it that much faster (if possible at all!).
And there are certainly less optimized corners of GHC which would improve things more for less effort.

It still seems like a lot of work is performed for essentially doing a unique = uniqueCounter++ operation.
But it's not obvious how this could expressed better without resorting to very ugly low level hacks.

I did however find a smallish issue with the existing code where it captured a lazy value.
You can see the fix here: https://gitlab.haskell.org/ghc/ghc/merge_requests/1229#