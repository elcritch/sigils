import std/unittest
import sigils/[hom, selectors]
import ./selectorPublicProtocolsFixture as fixture

type Item = ref object of DynamicAgent
  name: string
  active: bool
  children: seq[Item]

protocol ItemProtocol from Item:
  method itemName(self: Item): string =
    self.name

  method isActive(self: Item): bool =
    self.active

  method rename(self: Item, name: string) =
    self.name = name

  method peer(self: Item): Item =
    nil

  method childAt(self: Item, index: int = 0): Item =
    if index in 0 ..< self.children.len:
      self.children[index]
    else:
      nil

  method wrapName(self: Item, prefix: string = "(",
      suffix: string = ")"): string =
    prefix & self.name & suffix

protocol OptionalItemProtocol:
  method optionalLabel(): string {.optional.}

suite "higher-order local messages":
  test "an adoption predicate returns the first explicit adopter":
    let
      absent = Item()
      first = Item(name: "first").withProto()
      second = Item(name: "second").withProto()
    first.adopt(OptionalItemProtocol)
    second.adopt(OptionalItemProtocol)

    check absent.canConformTo(OptionalItemProtocol)
    let items = [Item(nil), absent, first, second]
    proc adopted(item: Item): bool = item.hasAdopted(OptionalItemProtocol)
    let found: Opt[Item] = items.findFirst(adopted)
    check found == Opt.some(first)
    check [Item(nil), absent].findFirst(adopted).isNone

  test "predicate search stops at a match and handles empty input":
    let items = [1, 2, 3, 4]
    var visited: seq[int]
    proc isEven(value: int): bool =
      visited.add value
      value mod 2 == 0

    check items.findFirst(isEven) == Opt.some(2)
    check visited == @[1, 2]
    visited.setLen(0)
    check items.findLast(isEven) == Opt.some(4)
    check visited == @[4]
    let empty: seq[int] = @[]
    check empty.findLast(isEven).isNone

  test "selector search skips false and unhandled replies without routing":
    let
      first = Item(active: true).withProto()
      last = Item(active: true).withProto()
      inactive = Item().withProto()
      missing = Item()
    missing.setNextResponder(first)
    let items = [missing, inactive, first, last, Item(nil)]
    check items.findFirst(isActive(), ()) == Opt.some(first)
    check items.findLast(isActive(), ()) == Opt.some(last)
    check [missing, inactive].findFirst(isActive(), ()).isNone
    check not compiles(items.findFirst(itemName(), ()))

  test "selector search tests handled replies including nil":
    let
      first = Item(name: "draft").withProto()
      last = Item(name: "published").withProto()
      missing = Item()
      items = [missing, first, last]
    proc published(name: string): bool = name == "published"
    proc noPeer(value: Item): bool = value.isNil
    check items.findFirst(itemName(), (), published) == Opt.some(last)
    check items.findLast(itemName(), (), published) == Opt.some(last)
    check items.findFirst(peer(), (), noPeer) == Opt.some(first)
    check [missing].findFirst(peer(), (), noPeer).isNone
    check items.select(itemName(), (), published) == @[last]
    check items.select(peer(), (), noPeer) == @[first, last]

  test "tree searches traverse from opposite ends and stop at a match":
    var visited, expanded: seq[int]
    proc childrenOf(node: int): seq[int] =
      expanded.add node
      case node
      of 1: @[2, 3]
      of 2: @[4]
      else: @[]
    proc matches(node: int): bool =
      visited.add node
      node in [3, 4]

    check 1.findFirst(childrenOf, matches) == Opt.some(4)
    check visited == @[1, 2, 4]
    check expanded == @[1, 2]
    check 1.findFirst(childrenOf, proc(node: int): bool = node == 1) ==
        Opt.some(1)
    check expanded == @[1, 2]

    expanded.setLen(0)
    visited.setLen(0)
    for node in 1.depthFirst(childrenOf):
      visited.add node
    check visited == @[1, 2, 4, 3]
    check expanded == visited

    expanded.setLen(0)
    visited.setLen(0)
    check 1.findLast(childrenOf, matches) == Opt.some(3)
    check visited == @[3]
    check expanded == @[1, 3]

    visited.setLen(0)
    for node in 1.depthFirst(childrenOf, reverse = true):
      visited.add node
    check visited == @[3, 4, 2, 1]

  test "tree selector search visits descendants of unhandled receivers":
    let
      target = Item(name: "target", active: true).withProto()
      group = Item(children: @[Item(nil), target])
      root = Item(children: @[group])
    group.setNextResponder(target)
    proc childrenOf(node: Item): seq[Item] = node.children
    proc matches(name: string): bool = name == "target"

    check root.findFirst(childrenOf, itemName(), (), matches) == Opt.some(target)
    check root.findFirst(childrenOf, isActive(), ()) == Opt.some(target)
    check root.findLast(childrenOf, itemName(), (), matches) == Opt.some(target)
    check root.findLast(childrenOf, isActive(), ()) == Opt.some(target)
    check root.findFirst(childrenOf, proc(node: Item): bool = false).isNone
    check root.findLast(childrenOf, proc(node: Item): bool = false).isNone
    check Item(nil).findLast(childrenOf, isActive(), ()).isNone

  test "tree iterators compose with collection sends and searches":
    let
      first = Item(name: "first", active: true).withProto()
      second = Item(name: "second").withProto()
      root = Item(children: @[first, second])
    proc childrenOf(node: Item): seq[Item] = node.children
    proc matches(name: string): bool = name == "second"

    check root.depthFirst(childrenOf).collect(itemName(), ()) ==
        @[Opt.none(string), Opt.some("first"), Opt.some("second")]
    check root.depthFirst(childrenOf).select(isActive(), ()) == @[first]
    check root.depthFirst(childrenOf).select(itemName(), (), matches) == @[second]
    check root.depthFirst(childrenOf).findFirst(isActive(), ()) == Opt.some(first)
    check root.depthFirst(childrenOf, reverse = true)
      .findFirst(itemName(), (), matches) == Opt.some(second)
    check root.depthFirst(childrenOf).collectSend(wrapName()) ==
        @[Opt.none(string), Opt.some("(first)"), Opt.some("(second)")]
    check root.depthFirst(childrenOf).selectSend(isActive()) == @[first]

  test "selector call syntax binds defaults and named arguments once":
    let
      first = Item(name: "first", active: true).withProto()
      second = Item(name: "second").withProto()
      items = [first, Item(), second]
    var evaluated = 0
    proc openBracket(): string =
      inc evaluated
      "["

    check items.collectSend(wrapName(suffix = "]", prefix = openBracket())) ==
        @[Opt.some("[first]"), Opt.none(string), Opt.some("[second]")]
    check evaluated == 1
    check first.wrapName(suffix = "]") == "(first]"
    check items.collectSend(wrapName(suffix = "]")) ==
        @[Opt.some("(first]"), Opt.none(string), Opt.some("(second]")]
    check items.selectSend(isActive()) == @[first]
    check items.selectSend(wrapName(), proc(value: string): bool =
      value == "(second)") == @[second]
    let renamed = items.collectSend(rename("updated"))
    check renamed[0].isSome
    check renamed[1].isNone
    check second.name == "updated"
    check not compiles(items.collectSend(wrapName(1)))
    check not compiles(items.selectSend(wrapName()))

  test "call syntax supports module-qualified selectors":
    let view = fixture.PublicView(caption: "Caption").withProto()
    check [view].collectSend(fixture.currentCaption()) == @[Opt.some("Caption")]
    discard view.addMethod(fixture.surroundedCaption(),
        fixture.surroundStoredCaption)
    check fixture.surroundedCaption(view, suffix = "!") == "[Caption!"
    check [view].collectSend(fixture.surroundedCaption(suffix = "!")) ==
        @[Opt.some("[Caption!")]

  test "selectWhere keeps original receivers after two local sends":
    let
      active = Item(active: true).withProto()
      inactive = Item().withProto()
      forwarded = Item()
      first = Item(children: @[inactive, active]).withProto()
      second = Item(children: @[active, inactive]).withProto()
      missingPredicate = Item(children: @[inactive, forwarded]).withProto()
      nilReply = Item().withProto()
      missingProjection = Item()
      items = @[missingProjection, first, nilReply, missingPredicate, second]
      root = Item(children: items)
    forwarded.setNextResponder(active)
    missingProjection.setNextResponder(first)
    proc childrenOf(node: Item): seq[Item] = node.children
    var evaluated = 0
    proc chosenIndex(): int =
      inc evaluated
      1

    check items.selectWhere(childAt(index = chosenIndex()), isActive()) == @[first]
    check evaluated == 1
    check items.selectWhere(childAt(), isActive()) == @[second]
    check root.depthFirst(childrenOf).selectWhere(childAt(), isActive()) == @[second]
    check not compiles(items.selectWhere(itemName(), isActive()))
    check not compiles(items.selectWhere(childAt(), itemName()))

  test "collect and select preserve order, missing replies, and nil results":
    let
      first = Item(name: "first", active: true).withProto()
      second = Item(name: "second").withProto()
      missing = Item()
      items = @[first, missing, second, Item(nil)]
    check items.collect(itemName(), ()) ==
      @[Opt.some("first"), Opt.none(string), Opt.some("second"), Opt.none(string)]
    check items.select(isActive(), ()) == @[first]
    let peers = items.collect(peer(), ())
    check peers[0].isSome
    check peers[0].get().isNil
    check peers[1].isNone
    let empty: seq[Item] = @[]
    check empty.collect(itemName(), ()).len == 0
    check not compiles(items.select(itemName(), ()))
    check not compiles(items.collect(itemName(), 123))

  test "local dispatch does not walk the responder chain":
    let
      target = Item(name: "target", active: true).withProto()
      missing = Item()
    missing.setNextResponder(target)
    check missing.trySend(itemName()).get() == "target"
    check @[missing].collect(itemName(), ())[0].isNone
    check [missing].select(isActive(), ()).len == 0

  test "commands and paired arguments report handling":
    let
      first = Item().withProto()
      missing = Item()
      last = Item().withProto()
      items = @[first, missing, last]
    check items.sendEach(rename(), "same") == @[true, false, true]
    check items.collectEach(rename(), ["a", "b", "c"])[1].isNone
    check first.name == "a"
    check last.name == "c"
    expect ValueError:
      discard items.collectEach(rename(), ["unexpected"])
    check first.name == "a"
    items.sendEach(rename(), "applied")
    check first.name == "applied"
    check last.name == "applied"

  test "dispatch snapshots membership before calling handlers":
    let
      original = Item(name: "original").withProto()
      replacement = Item(name: "replacement").withProto()
    var items = @[Item(), original]
    items[0].setForwardInvocation(proc(self: DynamicAgent,
        call: var Invocation): bool =
      items[1] = replacement
      call.setResult("forwarded")
      true
    )
    check items.collect(itemName(), ()) ==
      @[Opt.some("forwarded"), Opt.some("original")]
    check items[1] == replacement

  test "paired dispatch snapshots arguments before calling handlers":
    let last = Item().withProto()
    var labels = @["first", "last"]
    let first = Item()
    first.setForwardInvocation(proc(self: DynamicAgent,
        call: var Invocation): bool =
      labels[1] = "replacement"
      call.setResult(())
      true
    )
    discard [first, last].collectEach(rename(), labels)
    check last.name == "last"

  test "exceptions stop later sends after earlier side effects":
    let first = Item(name: "before").withProto()
    let failing = Item()
    let last = Item(name: "before").withProto()
    failing.setForwardInvocation(proc(self: DynamicAgent,
        call: var Invocation): bool =
      raise newException(ValueError, "failed")
    )
    expect ValueError:
      discard @[first, failing, last].sendEach(rename(), "after")
    check first.name == "after"
    check last.name == "before"
