import std/unittest
import sigils/[hom, selectors]

type Item = ref object of DynamicAgent
  name: string
  active: bool

protocol ItemProtocol from Item:
  method itemName(self: Item): string =
    self.name

  method isActive(self: Item): bool =
    self.active

  method rename(self: Item, name: string) =
    self.name = name

  method peer(self: Item): Item =
    nil

protocol OptionalItemProtocol:
  method optionalLabel(): string {.optional.}

suite "higher-order local messages":
  test "find returns the first explicit adopter with its concrete type":
    let
      absent = Item()
      first = Item(name: "first").withProto()
      second = Item(name: "second").withProto()
    first.adopt(OptionalItemProtocol)
    second.adopt(OptionalItemProtocol)

    check absent.canConformTo(OptionalItemProtocol)
    let found: Opt[Item] = [Item(nil), absent, first, second]
      .findAdopting(OptionalItemProtocol)
    check found == Opt.some(first)
    check [Item(nil), absent].findAdopting(OptionalItemProtocol).isNone

  test "collect and select preserve order, missing replies, and nil results":
    let
      first = Item(name: "first", active: true).withProto()
      second = Item(name: "second").withProto()
      missing = Item()
      items = @[first, missing, second, Item(nil)]
    check items.collectLocal(itemName(), ()) ==
      @[Opt.some("first"), Opt.none(string), Opt.some("second"), Opt.none(string)]
    check items.selectLocal(isActive(), ()) == @[first]
    let peers = items.collectLocal(peer(), ())
    check peers[0].isSome
    check peers[0].get().isNil
    check peers[1].isNone
    let empty: seq[Item] = @[]
    check empty.collectLocal(itemName(), ()).len == 0
    check not compiles(items.selectLocal(itemName(), ()))
    check not compiles(items.collectLocal(itemName(), 123))

  test "local dispatch does not walk the responder chain":
    let
      target = Item(name: "target").withProto()
      missing = Item()
    missing.setNextResponder(target)
    check missing.trySend(itemName()).get() == "target"
    check @[missing].collectLocal(itemName(), ())[0].isNone

  test "commands and paired arguments report handling":
    let
      first = Item().withProto()
      missing = Item()
      last = Item().withProto()
      items = @[first, missing, last]
    check items.sendEachLocal(rename(), "same") == @[true, false, true]
    check items.collectEachLocal(rename(), ["a", "b", "c"])[1].isNone
    check first.name == "a"
    check last.name == "c"
    expect ValueError:
      discard items.collectEachLocal(rename(), ["unexpected"])
    check first.name == "a"

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
    check items.collectLocal(itemName(), ()) ==
      @[Opt.some("forwarded"), Opt.some("original")]
    check items[1] == replacement

  test "exceptions stop later sends after earlier side effects":
    let first = Item(name: "before").withProto()
    let failing = Item()
    let last = Item(name: "before").withProto()
    failing.setForwardInvocation(proc(self: DynamicAgent,
        call: var Invocation): bool =
      raise newException(ValueError, "failed")
    )
    expect ValueError:
      discard @[first, failing, last].sendEachLocal(rename(), "after")
    check first.name == "after"
    check last.name == "before"
