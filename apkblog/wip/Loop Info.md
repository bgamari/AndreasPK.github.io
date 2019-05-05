Why loop focus?

What is a "loop"? - Natural loops - reduceability

Finding them:

* Intervals
* SCC
* Dominators

Plan of attack: Use existing implementation: dom-li

Pitfalls: Multi bodied loops:

foo:
    switch ... gogo l1; gogo l2; goot l3; ...

l1:
    ...
    goto foo;
l2:
    ...
    goto foo

Should be treated as one loop.





