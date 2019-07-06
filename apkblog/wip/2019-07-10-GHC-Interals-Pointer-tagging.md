---
title: 2020-02-24 GHC Internals - Pointer Tagging
tags: GHC, CodeGen, Optimization
---

# This post will go over the what and why of pointer tagging

Note: There is also a proper paper on this topic by SPJ: [Faster Laziness Using Dynamic Pointer Tagging](https://www.microsoft.com/en-us/research/wp-content/uploads/2007/10/ptr-tagging.pdf)

The paper is more in depth and imo better written than this post. But it also goes a lot more in depth
so if a 5 Minute read is more your thing keep reading :)

First we need to cover some background.

## Heap objects

*Heap objects* are things we generate at runtime like unevaluated [thunks](https://wiki.haskell.org/Thunk), evaluated values and partial applications.
In GHC these objects share a [common layout in memory](https://gitlab.haskell.org/ghc/ghc/wikis/commentary/rts/storage/heap-objects) which we call their
*closure*. 
The same layout is also used for [static objects](https://gitlab.haskell.org/ghc/ghc/wikis/commentary/rts/storage/heap-objects#static-objects) which are generated
at compile time and stored in the produced object file.

When we deal with actual values we call these *boxed values*, alluding to the fact that they come with a box (their closure) in which we store them.

Having a common layout is especially practical for GC as it allows to runtime to reuse a lot of code when dealing with this objects.
Which not only makes the code simpler but also more performant.

# Closures and laziness

Since Haskell is [lazy](https://wiki.haskell.org/Lazy_evaluation) closures can also represent **unevaluated** values (thunks).

Depending on which camp you are in this might be haskells greatest strength or weakness. No matter where you stand on this issue
one fact is that it has a major impact on how GHC generates code.

## Overheads of lazy evaluation

In strict languages when passing arguments or returning results we either use a value directly (in a register or on the stack) 
or we might pass a pointer to the actual value.

However in Haskell we often deal with *boxed and lifted* types. These are not passed or returned directly, rather we 
use a pointer to a **closure** to represent the value.

This may sound expensive, however GHC can often determine that code does not require us
to be lazy. This allows GHC to play pretend and act like a strict language for parts of the code.
This happens through the demand analyzer and optimizations like *worker/wrapper transformation* and *Constructed Product Result Analysis*.

However for the rest of this post we will focus on cases where these optimizations won't make a difference.

## Impact of laziness on generated code

We will work through this based on the not function:

```haskell

not x = 
  case x of {
    False -> True;
    True -> False
  }

```

In a strict language every call site of not would be required to evaluate the arguments first, then pass them to the function.
This means the called function can always assume all arguments are already evaluated. For our not function in a *strict* language
this would leave us with code that:

* Compares the argument against `False`
* Creates a return value based on the comparison
* Return the result

However in Haskell x might be unevaluated (a thunk) so there is more work to do as we have to check for
this fact and first evaluate the thunk if required.

The logic looks roughly like this:

* Check if argument is evaluated
  * If not evaluate argument
* Extract value from argument closure and continue
* Compare the argument against `False`
* Create a return value based on the result of the comparison
* Return the result

In pseudocode this would look something like this.

```C++

class Bool
{
    private:
      /* ClosureStuff */
      ...
    public:
      bool evaluated;
      bool value;
      Bool* evaluate();
      ...
  
};

Bool* not(Bool* x) {
  //Deal with unevaluated arguments.
  if(!x->isEvaluated)
  {
    x = x->evaluate();
  }

  //Perform the actual work.
  if (x->value == true) {
    return new Bool(false);
  } else {
    return new Bool(true);
  }
}
```

This is reasonable, there is no way around having code which performs some form
of `x->evaluate()` in a lazy language. 
We also don't want to evaluate x twice so checking if the argument is already 
evaluated is also the right thing to do.

And in fact this corresponds very closely to what GHC did in the past.

I won't go into the pros and cons of laziness here, but the point is that the ability
to pass lazy values comes with a small overhead.

# Reducing the overhead with pointer tagging

We can reduce that overhead by taking advantage of an important invariant in GHC's runtime.  
**GHC aligns all objects in the heap to the machine word size.**

Why is this important?

## What is pointer tagging

Enter [tagged pointers](https://en.wikipedia.org/wiki/Tagged_pointer).

Since all heap objects are aligned to WORD boundries all pointers to heap objects point
to addresses which are multiples of 4 (or 8 on 64bit systems).

For example we might place two 8-byte sized objects in memory like this:  
![](/images/Alignment1.png "Alignment example")

Aligning objects on the word boundry means all pointers will look like ".....00" with the last few bits always being zero.

This means we are free to store information in those bits as long as we make sure to zero them
before dereferencing the pointer. Which is exactly what GHC does!

Inside GHC this is refered to as the tag of the pointer, with the bits we are free to set
called the tag bits.  

## Making use of tagged pointers.

Functions get tagged with their arity but we won't cover the details here.  
For data types GHC always stores if an object is already evaluated `(tag != 0)`.
If we have enough tag bits for a certain data type we even store what constructor
the value is built with.  

Building on this we could generate code taking advantage of this which corresponds
something like this in pseudo C++:

```C++

Bool* not(Bool* x) {
  //Deal with unevaluated arguments.
  int tag = x & 0x3;
  if(tag == 0)
  {
    x = x->evaluate();
  }

  //Perform the actual work.
  if (x & 0x3 == 1) { // x == True
    return new Bool(false);
  } else {
    return new Bool(true);
  }
}
```

We can compare this to the Cmm code GHC actual produces by passing -ddump-cmm and compiling the example above.
Below is the code output for these interested. I did rename some of the labels and added comments to 
make it easier to follow.  
Ignoring the verbosity added by things like gotos and explicit stack handling it's very similar.

```
     {offset
       c1bH: //Check if enough stack space is available.
           if ((Sp + -8) < SpLim) (likely: False) goto doGc; else goto enoughStack;
      
       doGc: //If we ran out of stack space run GC and rerun the current function.
           R2 = R2;
           R1 = foo_closure;
           call (stg_gc_fun)(R2, R1) args: 8, res: 0, upd: 8;

       enoughStack:
           //Here we set up things required for "`evaluate()`", why here and not inside `evaluate`
           //is rather complicated. See also ticket #8905
           I64[Sp - 8] = alreadyEvaluated; //Push return address for evaluate onto stack.
           R1 = R2;
           Sp = Sp - 8;
           //Check if the tag is zero/the argument is evaluated
           if (R1 & 7 != 0) goto alreadyEvaluated; else goto evaluate;
       evaluate:
           //essentially x->evaluate(), returns the result in R1
           call (I64[R1])(R1) returns to alreadyEvaluated, args: 8, res: 8, upd: 8;
       alreadyEvaluated:
           // check if argument == True
           if (R1 & 7 != 1) goto returnFalse; else goto returnTrue;
       returnFalse:
           R1 = False_closure+1; //Add tag to the pointer!
           Sp = Sp + 8;
           call (P64[Sp])(R1) args: 8, res: 0, upd: 8;
       returnTrue:
           R1 = True_closure+2; //Add tag to the pointer!
           Sp = Sp + 8;
           call (P64[Sp])(R1) args: 8, res: 0, upd: 8;
     }

```

## How good is it?

If you look closely you might notice that we never dereferenced the argument if it was already evaluated!
This is important because memory access can take (comperativly) very long and pointer tagging allows us to
get away without ever touching x in memory if it's already evaluated and we don't need to access it's fields.

To better understand just **how** much better this is consider the following snippet,
which lists all the instructions executed if we assume the argument was already evaluated and False:

```asm
foo_info:
_c1bH:
        leaq -8(%rbp),%rax
        cmpq %r15,%rax
        jb _c1bI
_c1bJ: 
        movq $block_c1bA_info,-8(%rbp)
        movq %r14,%rbx
        addq $-8,%rbp
        testb $7,%bl
        jne _c1bA
_c1bA:
        andl $7,%ebx
        cmpq $1,%rbx
        jne _c1bF
_c1bE:
        movl $True_closure+2,%ebx
        addq $8,%rbp
        jmp *(%rbp)
```

Let's handwave a lot and be **very** pesimistic.   
We assume the CPU needs one cycle for each of these instructions.
Then we round up and say the whole thing will take 15 cycles to run.

Meanwhile if we need to fetch `x` from eg L3 cache (not even memory!) it can take up to **[42 cycles](https://www.7-cpu.com/cpu/Skylake.html)** until we get the result back.  
But at this point all we did was load `x` and we haven't even done the actual work!

The actual impact will vary a lot depending on the used soft/hardware.
But in practice back when pointer tagging was first introduced the runtimes decreased by 12-14% depending on the hardware used. So it comes with quite a large benefit.

