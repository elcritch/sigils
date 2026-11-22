# The Objective-C road through Smalltalk: programming whole collections

What if Objective-C had grown by giving programmers more control over message sends? For collections, there are working answers. In 2003, F-Script could send a message across two arrays and express which elements should meet. In 2005, Marcel Weiher and Stéphane Ducasse showed how an Objective-C library could capture a message, arguments and all, and decide which objects should receive it. Both experiments predate Swift. Writing just after Swift’s introduction, Michael Tsai made a related case for adding comprehensions to Objective-C. [F-Script paper][oopal] · [Higher Order Messaging paper][hom] · [Michael Tsai's 2014 essay][tsai]

## Smalltalk gave the collection a say

Suppose an editor has three files open and wants the names of those with unsaved changes. In Smalltalk, assuming the file objects implement `isModified` and `name`, two collection operations express the query.

```smalltalk
(files select: [ :file | file isModified ])
    collect: [ :file | file name ]
```

`select:` keeps the original file objects whose block answers true. `collect:` builds a collection from the answers to a second block. The file knows whether it has changed. The collection knows how to visit its members. An editor can use the same query with different file classes because each file answers those messages for itself. [Working with collections in Pharo][pharo]

Pharo adds a small twist. A symbol such as `#isModified` can stand in for a one-argument block. When asked for its value on an object, the symbol sends that object the message it names. The query becomes `(files select: #isModified) collect: #name`. This also works on the live program itself. Try `Collection withAllSubclasses select: #isAbstract` in Pharo and the answer contains actual class objects, ready for another query. The same collection vocabulary that searches documents can search the class hierarchy in a running image. [Pharo examples of blocks, symbols, and class queries][pharo]

## Objective-C could intercept the next message

Weiher and Ducasse's *Higher Order Messaging* (HOM) took a different route to that short query. Here is the idea in their Objective-C library notation, with a selection and a projection shown separately.

```objc
[[files select] isModified];  // the modified file objects
[[files collect] name];       // the names of all the files
```

Read the brackets from the inside out. In the second line, `[files collect]` returns a proxy. Sending `name` to that proxy lets Objective-C's forwarding machinery package the send as an `NSInvocation`. The collection can invoke it on each file and gather the returned names. With `select`, the answer from each file decides whether the collection keeps that file. The library supplies `select` and `collect`. It can process a new application-specific message without anyone teaching the library its name. Weiher's *Simple HOM* blog post shows the category on `NSArray` and the forwarding code side by side. [DLS 2005 paper, §§2–4][hom] · [Simple HOM, 2009][simple] · [Objective-C implementation][hom-code]

The feature that goes beyond a concise `map` is **iteration over message arguments**. Suppose `stems` contains `@"draft"` and `@"photo"`, and `extensions` contains `@".md"` and `@".png"`. MPWFoundation lets the caller choose a fixed or a varying extension.

```objc
[[stems collect] stringByAppendingString:@".bak"];           // draft.bak, photo.bak
[[stems collect] stringByAppendingString:[extensions each]]; // draft.md, photo.png
```

The string method takes one string in both cases. The first send reuses one argument. In the second, `each` marks an argument that advances alongside the receiver. MPWFoundation stops when the first input runs out. A class author who writes a useful two-object operation has thereby supplied the element operation for a whole family of bulk operations. [Higher Order Messaging, §4.1, especially figure 5][hom]

Objective-C's type checker sees the element method's declared return type. Here `name` may be declared to return an `NSString *`, while the expression involving `collect` produces an array. Applying `select` to a Boolean-returning method changes the result type even more dramatically. Weiher's small `collect` implementation also assumes it can put each return value into an `NSMutableArray`. Scalars, `void`, and `nil` require an explicit policy. Swift's `Sequence.map` expresses the result type directly in its signature. A transform that returns a string produces an array of strings. [Simple HOM and its discussion][simple] · [Swift's map signature][swift-map]

## F-Script made the shape of a send programmable

Philippe Mougin and Stéphane Ducasse combined Smalltalk messaging with APL's array programming in F-Script, a scripting language for Cocoa. In the paper's dialect, suppose X holds `{2, 3}` and Y holds `{10, 20}`. In each expression below, the individual numbers receive the same multiplication message. What changes is **who receives which argument**. [OOPAL, §§3–5][oopal]

| F-Script expression | Sends performed | Result |
| --- | --- | --- |
| `X * 10` | Each member of X receives the same argument | `{20, 30}` |
| `X * Y` | Corresponding members are paired | `{20, 60}` |
| `X @1*@2 Y` | Each member of X is paired with every member of Y | `{{20, 40}, {30, 60}}` |

The numbers on the `@` signs specify nesting levels. They describe an outer and inner loop independently of the method being sent. Multiplication makes the result easy to check, but the rule applies to messages on application objects too. For example, the same arrangement could ask each candidate venue whether it can host each proposed event and produce a table of answers. [OOPAL, §5, figure 6][oopal]

F-Script also has recursive message patterns for arrays nested inside arrays. For `X = {{1, 2}, {3}}`, `X @class` asks the two inner arrays for their classes. `X @@class` applies the first pattern to the second and asks the numbers for their classes, preserving the nested result shape. The repeated `@` specifies how many levels to descend. The numbered patterns in the table specify which inputs share a loop. [OOPAL, §§5.2–5.3][oopal]

Another example from the paper is `P at: P salary > 3000`, where `P` holds pilots. `P salary` gathers salaries, `> 3000` produces a Boolean array, and `at:` uses that array to select the original pilots. The caller can reuse that Boolean array as a mask to select the same positions from a second, aligned array. One detail matters when reading such expressions. For implicit sends, F-Script first checks whether the array itself implements the method. An explicit message pattern lets the programmer direct a send to the elements. [OOPAL, §§5 and 7.1][oopal]

## What Apple shipped, and what people wanted next

Objective-C 2.0's collection feature was fast enumeration. A custom collection implementing `NSFastEnumeration` could participate in `for (id file in files)`. Subsequent work added blocks, collection literals, and subscripting. Foundation also had its own form of whole-collection programming in **key-value coding** (KVC). This example uses later literal syntax to build the input. [Apple on fast enumeration][fast-enum] · [Clang's Objective-C literal specification][literals] · [Chris Lattner on the language's evolution][lattner]

```objc
NSArray *invoices = @[@{@"total": @12}, @{@"total": @18}];
NSNumber *sum = [invoices valueForKeyPath:@"@sum.total"];  // 30
```

The key path says both what to read and how to combine the values. Foundation understands a documented vocabulary including `@sum`, `@avg`, and `@distinctUnionOfObjects`. In HOM, a new method on an invoice immediately becomes a candidate for a bulk send. With F-Script, the caller can additionally choose the pairing between invoices and arguments. [Apple's guide to KVC collection operators][kvc] · [Higher Order Messaging][hom] · [OOPAL][oopal]

- **A contemporary wish.** In *Hypothetical Objective-C 3.0* (2014), Michael Tsai explicitly asks what the Swift development effort might have achieved if applied to Objective-C. Two of his own requests were lighter block syntax and Python-style comprehensions. A comprehension would let a programmer write filtering and projection together. HOM instead lets a library author define how the next message is delivered. Those are different answers to the same frustration with collection code. [Tsai's essay][tsai]
- **A language someone built.** Weiher's Objective-Smalltalk takes the Objective-C runtime and C ABI as its base, uses Smalltalk-style syntax, and includes Higher Order Messaging. Its project overview directly addresses “Why not Swift?” This is the closest match to an alternative successor that made the earlier collection experiment part of a broader language design. [About Objective-Smalltalk][objective-st]
- **The decision from inside Apple.** In a 2020 interview, Chris Lattner recalls that continuing to improve Objective-C was a live option. He also describes Swift development feeding improvements back into Objective-C, including ARC. His account explains why the language histories overlap. [Lattner interview][lattner]

For a related route through **syntax macros**, Tim Burks's Nu put a Lisp on the Objective-C runtime. Its multi-list `map` is a function, while `assert` is a macro that can keep the failing expression for diagnostics. A Nu macro receives program forms. A HOM proxy receives a message that is already being sent. That difference determines what a library author can inspect or change. [Burks on Nu macros][nu-macros] · [Nu library source][nu-code]

## A connection to Sigils

Sigils gives selectors typed signatures, and its keyed collections let a caller observe one item's identity across snapshot changes. If a Sigils caller applied a test to every item, what should the result contain? Matching values, stable keys, and a live projection that tracks membership would each give the caller something different. HOM's distinction between collecting answers and selecting receivers explains why these are different contracts. An observable collection also has to specify **when** the answer should change. [Sigils selectors](selectors.md) · [Observable keyed collections](collection-sigils.md)

Merenda offers a place to try the idea on real objects. An accessibility inspector can ask every child view for its label, keep the replies in view order, and let each control supply its own implementation. The [Sigils and Merenda design note](hom-in-sigils-and-merenda.md) works through a headless prototype, including a Smalltalk-like call form and MPWFoundation-style paired arguments.

[oopal]: https://scg.unibe.ch/archive/papers/Moug03aOOPALOOPSLA.pdf
[hom]: https://scg.unibe.ch/archive/papers/Weih05aHigherOrderMessagingOOPSLA2005.pdf
[tsai]: https://mjtsai.com/blog/2014/10/14/hypothetical-objective-c-3-0/
[pharo]: https://book.gtoolkit.com/working-with-collections-in-pharo-w9fc31ubksh9va7i1516z5mt
[simple]: https://blog.metaobject.com/2009/01/simple-hom.html
[hom-code]: https://github.com/mpw/HOM/blob/master/HOM.m
[swift-map]: https://developer.apple.com/documentation/swift/sequence/map%28_%3A%29
[fast-enum]: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjectiveC/Chapters/ocFastEnumeration.html
[literals]: https://clang.llvm.org/docs/ObjectiveCLiterals.html
[lattner]: https://www.hackingwithswift.com/interviews/chris-lattner-could-apple-have-improved-objective-c-instead-of-making-swift
[kvc]: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/KeyValueCoding/CollectionOperators.html
[objective-st]: https://objective.st/About
[nu-macros]: https://programming-nu.github.io/posts/2009/01/02/macros
[nu-code]: https://github.com/programming-nu/nu/blob/master/nu/nu.nu
