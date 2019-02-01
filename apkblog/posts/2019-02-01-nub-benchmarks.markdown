---
title: Comparing nub implementations.
---

This post was inspired by [this medium blog post](https://medium.com/permutive/having-your-cake-and-eating-it-9f462bf3f908) and the following [discussion on reddit](https://www.reddit.com/r/haskell/comments/alnkjh/having_your_cake_and_eating_it_pure_mutable_state/).

There was a lot of discussion about big O performance. But zero numbers, which was sad so here we go.

# Recapping the nub function.

```Haskell
nub :: Eq a => [a] -> [a]
```

It's really simple. We take a list and remove any duplicates.

Ideally this is also stable. Meaning if two elements compare as equal
we only keep the first one.

Not all of the implementations play by these rules. Some relax the
requirement to keep the first or don't keep the elements in order at all.

# What/How do we benchmark?

* We could benchmark `Int` performance. But that's boring.
* We could benchmark `Text` fragments. But they don't have a `Grouping` instance.
* So we pretend we never heard of text/bytestring and go with [Char].

In order to get a bunch of strings I took a ghc dump and split it into words.
So the spirit of the code is something like this:

```Haskell
bench words size =
  bench "name" $ whnf (length . nub*) (take size words)
```

`length` is only there to make sure we have evaluated the whole structure of the list.
This avoids the overhead of nf which would be traversing all strings completely which would only distort the results.

I also skipped length in one variant to check the performance in the case of laziness, but it's not that interesting.

# Which nub* variants are we looking at.

## base - Data.List.nub

This is the "worst", but also the most general version as it only requires an Eq instance.

It keeps a list of seen elements, and checks for each new element if it compares as equal.

```
+ Lazy
+ Only Eq required
+ Stable
+ In base
+ Fast for small lists
- TERRIBLE for large lists
- O(n^2) runtime
```

## containers - Data.ListUtils.ordNub

Instead of using a list to keep track of seen elements it uses a Set.
This means lookup only takes `log(n)` time instead of `n` making it a lot better.

```
+ Lazy
+ Only Ord required
+ Stable
+ Still fairly general
+ Decent performance
```

## ST-Based hashing variant from the blog post.

Instead of using a list of seen elements it builds up a hashmap
which then gets collapsed into a list.

The version of gspia is slightly faster but has the same advantages/disadvantages.

```
+ Faster than regular nub
- Strict
~ Requires Hashable
- Disregards element order completely, `(nubSpence ["ZZZ","z"] == ["z","ZZZ"])`
```

### Data.Discriminators

In a true edwardkmett fashin it's very interesting and very undocumented.

He made some (comments here)[https://www.reddit.com/r/haskell/comments/3brce1/why_does_sort_in_datadiscrimination_claim_to_be_on/] explaining
how it works.

I expect that it would perform well for something like Int.
But for this case the runtimes where beyond disappointing.

```
- Requires a `Grouping` instance which isn't common. Eg `Text` doesn't have one.
- Seems to suffer from very high constants for the case tested (String).
```

### Relude functions

A comment on reddit pointed out that relude contains a variety of n*log(n)
nub functions. The benchmark included:

* Stable hash backed variant
* `ordNub` - essentially the containers variant
* Unstable hash map backed version
* A few more

# Results.

## `nubOrd` is a good default.

* It's lazy
* It's among to best for small and large lists
* It's stable
* Ord instances are easy to come by
* You likely won't get around using `containers` anyway

Contraindications:
* All your lists are <20 elements: Just us regular nub.
* All your lists are > 500 elements, AND you will evaluate the whole list: Look into hashbased variants.
* Your lists are Int. I'm sure there are better implementations for [Int].

## Use a hash based version for long hashable lists.

After about 500-1k elements these became generally faster than the ord based ones.
The largest difference I saw was a factor of about 2. Which is a lot, but depending on your code
this might still be acceptable when compared to implementing hashable/additional code.

## Other bits

I would have expected `Data.Discrimination.nub` to do better. Maybe I did something wrong.
Maybe the constants are just pretty high

I did NOT check how these perform in combination with list fusion, so that might matter for some code as well.

* `Data.List.nub` outperformed all others till about 20 elements.
* `Data.Discriminator.nub` was always the worst algorithm up to 20000 elements.
* `Data.Containers.ListUtils.nubOrd` was the fastest between ~30-~500 elements. After that the hash based ones got faster and stayed faster by a factor of about 2x.
* Giving up the order/stable requirements does pay off. But only for very large lists, and only if you are going to evaluate the whole list.
* gspia's adjustment to the code from the blog made it about twice as fast for some problem sizes.

You can also look at the criterion output [here](/resources/report_nubBench.html).

# Disclaimers

While this is titled Bechmarking I would not qualify it as a reliable benchmark by any metric.

* I only looked at Strings.
* All inputs were derived from the same data.
* Only microbenchmarks.
* Only one environment, a noisy one at that.
* Did not consider any list fusion that might be possible for these.

I still think it gives a decent idea, but take it as what it is and not a ultimate judgement.

