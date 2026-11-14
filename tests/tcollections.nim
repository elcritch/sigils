import std/[options, unittest]
import sigils/[collections, reactive]

type Row = object
  id: int
  text: string

proc key(row: Row): int = row.id

suite "keyed collection sigils":
  test "publish coherent projections and track computed values":
    let rows = newCollectionSigil(@[Row(id: 1, text: "one")], key)
    let first = rows.item(1)
    let order = rows.order
    let derived = computedNow[string]:
      discard order{}
      rows.get(1).get(Row()).text & first{}.get(Row()).text
    rows <- @[Row(id: 2), Row(id: 1, text: "new")]
    check derived{} == "newnew"
    check order{} == @[2, 1]
    rows <- @[]
    check first{}.isNone
    rows <- @[Row(id: 1, text: "back")]
    check first{}.get.text == "back"

  test "duplicate keys and invalid replacements leave values unchanged":
    let rows = newCollectionSigil(@[Row(id: 1, text: "one")], key)
    expect ValueError:
      rows <- @[Row(id: 1), Row(id: 1)]
    expect ValueError:
      rows[1] = Row(id: 2)
    check rows[1].text == "one"
    check rows.get(2).isNone

  test "computed retains temporary projections across recomputation":
    let rows = newCollectionSigil(@[Row(id: 1, text: "one")], key)
    let derived = computedNow[string]:
      rows.item(1){}.get(Row()).text
    check derived{} == "one"
    rows[1] = Row(id: 1, text: "two")
    check derived{} == "two"
    rows[1] = Row(id: 1, text: "three")
    check derived{} == "three"

type Watcher = ref object of Agent
  calls: int
  rows: CollectionSigil[int, Row]
  first: CollectionValue[Option[Row]]
  second: CollectionValue[Option[Row]]
  coherent: bool
  recursiveRejected: bool

proc watch(w: Watcher, attrs: set[SigilAttributes]) {.slot.} =
  inc w.calls
  if not w.rows.isNil:
    w.coherent = w.first{}.get(Row()).text == "new" and
      w.second{}.get(Row()).text == "changed" and w.rows[1].text == "new"
    try:
      w.rows <- @[]
    except ValueError:
      w.recursiveRejected = true

suite "collection notification ownership":
  test "notify only changed projections after all values are committed":
    let rows = newCollectionSigil(@[Row(id: 1, text: "old"), Row(id: 2,
        text: "old")], key)
    let first = rows.item(1)
    let second = rows.item(2)
    let unchanged = rows.item(3)
    let watcher = Watcher(rows: rows, first: first, second: second)
    let other = Watcher()
    connect(first, change, watcher, watch)
    connect(unchanged, change, other, watch)
    rows <- @[Row(id: 1, text: "new"), Row(id: 2, text: "changed")]
    check watcher.calls == 1
    check watcher.coherent
    check watcher.recursiveRejected
    check other.calls == 0
    check rows.len == 2

  test "dropping and rebinding projections releases ownership":
    let rows = newCollectionSigil(@[Row(id: 1)], key)
    let baseline = rows.unsafeGcCount
    for i in 0 ..< 1000:
      let value = rows.item(i)
      check rows.item(i) == value
    check rows.unsafeGcCount == baseline
    let first = rows.item(1)
    check rows.unsafeGcCount == baseline + 1
    discard first

  test "one changed item notifies one of a thousand observers":
    var initial: seq[Row]
    for id in 0 ..< 1000:
      initial.add Row(id: id, text: $id)
    let rows = newCollectionSigil(initial, key)
    var observations: seq[CollectionValue[Option[Row]]]
    var watchers: seq[Watcher]
    for id in 0 ..< 1000:
      let observation = rows.item(id)
      let watcher = Watcher()
      connect(observation, change, watcher, watch)
      observations.add observation
      watchers.add watcher
    rows[500] = Row(id: 500, text: "changed")
    var count = 0
    for watcher in watchers:
      count += watcher.calls
    check count == 1
    check watchers[500].calls == 1
    discard observations

  test "snapshots are independent values":
    let rows = newCollectionSigil(@[Row(id: 1, text: "stored")], key)
    var copy = rows{}
    copy[0].text = "local"
    check rows[1].text == "stored"

  test "computed switches temporary projections without retaining old ones":
    let rows = newCollectionSigil(@[Row(id: 1, text: "one"), Row(id: 2,
        text: "two")], key)
    let selection = newSigil(1)
    let derived = computedNow[string]:
      rows.item(selection{}){}.get(Row()).text
    check derived{} == "one"
    let retained = rows.unsafeGcCount
    for i in 0 ..< 100:
      selection <- (if i mod 2 == 0: 2 else: 1)
      check rows.unsafeGcCount == retained
    selection <- 2
    check derived{} == "two"
    rows[1] = Row(id: 1, text: "changed")
    check derived{} == "two"
    rows[2] = Row(id: 2, text: "updated")
    check derived{} == "updated"

  test "a projection keeps its collection alive":
    var rows = newCollectionSigil(@[Row(id: 1, text: "alive")], key)
    let projection = rows.item(1)
    rows = nil
    check projection{}.get.text == "alive"

  test "switching disconnects externally retained old projections":
    let rows = newCollectionSigil(@[Row(id: 1, text: "one"), Row(id: 2,
        text: "two")], key)
    let old = rows.item(1)
    let selection = newSigil(1)
    var evaluations = 0
    let derived = computedNow[string]:
      inc evaluations
      rows.item(selection{}){}.get(Row()).text
    check evaluations == 1
    selection <- 2
    check derived{} == "two"
    check evaluations == 2
    check not connected(old, change, derived)
    rows[1] = Row(id: 1, text: "changed")
    check evaluations == 2
    rows[2] = Row(id: 2, text: "updated")
    check derived{} == "updated"
    check evaluations == 3

  test "aggregate computed values retain many projections without duplication":
    var initial: seq[Row]
    for id in 0 ..< 1000:
      initial.add Row(id: id, text: $id)
    let rows = newCollectionSigil(initial, key)
    var evaluations = 0
    let derived = computedNow[int]:
      inc evaluations
      var count = 0
      for id in 0 ..< 1000:
        if rows.item(id){}.isSome:
          inc count
      count
    check derived{} == 1000
    let retained = rows.unsafeGcCount
    rows[500] = Row(id: 500, text: "changed")
    check evaluations == 2
    check derived{} == 1000
    check rows.unsafeGcCount == retained

  test "lazy computed disconnects old retained projections when evaluated":
    let rows = newCollectionSigil(@[Row(id: 1, text: "one"), Row(id: 2,
        text: "two")], key)
    let old = rows.item(1)
    let selection = newSigil(1)
    let derived = computed[string]:
      rows.item(selection{}){}.get(Row()).text
    check derived{} == "one"
    selection <- 2
    check derived{} == "two"
    check not connected(old, change, derived)
    rows[1] = Row(id: 1, text: "changed")
    check not derived.isDirty
    rows[2] = Row(id: 2, text: "updated")
    check derived.isDirty
    check derived{} == "updated"

  test "effects switch away from externally retained projections":
    let rows = newCollectionSigil(@[Row(id: 1), Row(id: 2)], key)
    let old = rows.item(1)
    let selection = newSigil(1)
    let internalSigilEffectRegistry = initSigilEffectRegistry()
    var evaluations = 0
    effect:
      inc evaluations
      discard rows.item(selection{}){}
    check evaluations == 1
    selection <- 2
    emit internalSigilEffectRegistry.triggerEffects()
    check evaluations == 2
    rows[1] = Row(id: 1, text: "changed")
    emit internalSigilEffectRegistry.triggerEffects()
    check evaluations == 2
    rows[2] = Row(id: 2, text: "changed")
    emit internalSigilEffectRegistry.triggerEffects()
    check evaluations == 3
    discard old
