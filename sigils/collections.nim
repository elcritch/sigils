## Keyed, observable value collections for GUI-thread models.
## Snapshots and items are plain values. Only observed projections allocate
## reactive objects; projections cannot be written independently of the collection.
import std/tables
import results
import sigils/[core, reactive]

export results.Opt, results.get, results.isSome, results.isNone, results.some,
    results.none, results.`==`


type
  CollectionSource* = ref object of SigilBase

  ProjectionLink[T] = ref object
    target {.cursor.}: CollectionValue[T]

  ProjectionHandle[T] = object
    link: ProjectionLink[T]

  CollectionValue*[T] = ref object of CollectionSource
    value: T
    owner: CollectionSource
    handle: ProjectionHandle[T]

  CollectionSigil*[K, T] = ref object of CollectionSource
    values: seq[T]
    positions: Table[K, int]
    keys: seq[K]
    keyOf: proc(value: T): K {.nimcall.}
    orderRef: ProjectionLink[seq[K]]
    itemRefs: Table[K, ProjectionLink[Opt[T]]]
    publishing: bool
    newItems: int
    pruneAfter: int

proc `=destroy`[T](handle: ProjectionHandle[T]) =
  if not handle.link.isNil:
    handle.link.target = nil
  `=destroy`(handle.link)

proc `=copy`[T](dest: var ProjectionHandle[T], src: ProjectionHandle[T]) {.error.}


proc snapshot*[K, T](source: CollectionSigil[K, T]): seq[T] =
  ## Return a value snapshot. Reference-bearing items retain their normal Nim
  ## aliasing semantics: publish replacements rather than mutating shared refs.
  source.values

proc snapshot*[T](source: CollectionValue[T]): T =
  source.value

template `{}`*(source: CollectionSource): untyped =
  ## Participate in Sigils' scoped read tracking, like Sigil[T].
  block:
    let input = source
    when enableSigilBinding[^1]:
      mixin getInternalSigilIdent
      when input is CollectionValue and compiles(retainSource(
          getInternalSigilIdent(), input)):
        input.connect(change, SigilBase(getInternalSigilIdent()), recompute)
        retainSource(getInternalSigilIdent(), input)
      else:
        input.connect(change, getInternalSigilIdent(), recompute)
    input.snapshot()

proc len*[K, T](source: CollectionSigil[K, T]): int =
  source.values.len

proc contains*[K, T](source: CollectionSigil[K, T], key: K): bool =
  source.positions.hasKey(key)

proc `[]`*[K, T](source: CollectionSigil[K, T], key: K): T =
  ## Required lookup by stable key, not sequence position. Raises KeyError.
  source.values[source.positions[key]]

proc get*[K, T](source: CollectionSigil[K, T], key: K): T =
  ## Return the item for key. Raises KeyError when the key is absent.
  source[key]

proc lookupProjection[K, T](values: seq[T], positions: Table[K, int],
    key: K): Opt[T] =
  let index = positions.getOrDefault(key, -1)
  if index >= 0:
    Opt.some(values[index])
  else:
    Opt.none(T)

iterator items*[K, T](source: CollectionSigil[K, T]): T =
  for value in source.values:
    yield value

iterator pairs*[K, T](source: CollectionSigil[K, T]): (K, T) =
  for i, value in source.values:
    yield (source.keys[i], value)

proc order*[K, T](source: CollectionSigil[K, T]): CollectionValue[seq[K]] =
  ## Observe membership/order without waking on item-only changes.
  result = (if source.orderRef.isNil: nil else: source.orderRef.target)
  if result.isNil:
    result = CollectionValue[seq[K]](value: source.keys, owner: source)
    source.orderRef = ProjectionLink[seq[K]](target: result)
    result.handle.link = source.orderRef

proc item*[K, T](source: CollectionSigil[K, T], key: K): CollectionValue[Opt[T]] =
  ## Observe one identity. A missing key publishes none. A present key publishes
  ## some, including when the item is a nil ref.
  ## Observations retain the source, which holds only zeroing links back.
  result = (if source.itemRefs.hasKey(key): source.itemRefs[
      key].target else: nil)
  if result.isNil:
    let value = lookupProjection(source.values, source.positions, key)
    result = CollectionValue[Opt[T]](value: value, owner: source)
    let link = ProjectionLink[Opt[T]](target: result)
    result.handle.link = link
    source.itemRefs[key] = link
    # Sweep only after enough new projections to amortize the table scan.
    inc source.newItems
    if source.newItems >= source.pruneAfter:
      var expired: seq[K]
      for id, entry in tables.pairs(source.itemRefs):
        if entry.target.isNil:
          expired.add id
      for id in expired:
        source.itemRefs.del(id)
      source.newItems = 0
      source.pruneAfter = max(64, source.itemRefs.len)

proc beginPublication[K, T](source: CollectionSigil[K, T]) =
  if source.publishing:
    raise newException(ValueError, "cannot publish a collection recursively")
  source.publishing = true

proc publish[K, T](source: CollectionSigil[K, T], values: seq[T]) =
  var positions = initTable[K, int]()
  var keys: seq[K]
  for i, value in values:
    let key = source.keyOf(value)
    if positions.hasKey(key):
      raise newException(ValueError, "duplicate collection identity")
    positions[key] = i
    keys.add key
  let order = (if source.orderRef.isNil: nil else: source.orderRef.target)
  let moved = keys != source.keys
  let snapshotChanged = moved or source.values != values
  var updates: seq[tuple[observed: CollectionValue[Opt[T]], value: Opt[T], notify: bool]]
  var expired: seq[K]
  for key, link in tables.pairs(source.itemRefs):
    let observed = link.target
    if observed.isNil:
      expired.add key
    else:
      let next = lookupProjection(values, positions, key)
      # Stage every live projection and use equality to decide which ones notify.
      let notify = observed.value != next
      updates.add (observed, next, notify)
  source.values = values
  source.positions = positions
  source.keys = keys
  for key in expired:
    source.itemRefs.del(key)
  if not order.isNil:
    order.value = keys
  for update in updates.mitems:
    update.observed.value = move(update.value)
  if moved and not order.isNil:
    emit order.change({Changed})
  for update in updates:
    if update.notify:
      emit update.observed.change({Changed})
  if snapshotChanged:
    emit source.change({Changed})

proc setValue*[K, T](source: CollectionSigil[K, T], values: seq[T]) =
  ## Validate and index the snapshot, commit all projections, then notify changes.
  ## Recursive writes to this collection raise ValueError.
  source.beginPublication()
  defer: source.publishing = false
  source.publish(values)

proc `<-`*[K, T](source: CollectionSigil[K, T], values: seq[T]) =
  source.setValue(values)

proc newCollectionSigil*[K, T](
    values: seq[T], keyOf: proc(value: T): K {.nimcall.}
): CollectionSigil[K, T] =
  if keyOf.isNil:
    raise newException(ValueError, "collection key getter cannot be nil")
  result = CollectionSigil[K, T](keyOf: keyOf, pruneAfter: 64)
  result.setValue(values)

proc `[]=`*[K, T](source: CollectionSigil[K, T], key: K, value: T) =
  ## Replace an existing item without changing its identity; publish once.
  source.beginPublication()
  defer: source.publishing = false
  if source.keyOf(value) != key:
    raise newException(ValueError, "replacement must preserve collection identity")
  var next = source.snapshot()
  next[source.positions[key]] = value
  source.publish(next)
