## Keyed, observable value collections for GUI-thread models.
## Snapshots and items are plain values. Only observed projections allocate
## reactive objects; projections cannot be written independently of the collection.
import std/[options, tables]
import sigils/[core, reactive]


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
    itemRefs: Table[K, ProjectionLink[Option[T]]]
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

proc get*[K, T](source: CollectionSigil[K, T], key: K): Option[T] =
  let index = source.positions.getOrDefault(key, -1)
  if index >= 0:
    result = some(source.values[index])

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

proc item*[K, T](source: CollectionSigil[K, T], key: K): CollectionValue[Option[T]] =
  ## Observe one identity. Removal publishes none; reinsertion publishes some.
  ## Observations retain the source, which holds only zeroing links back.
  result = (if source.itemRefs.hasKey(key): source.itemRefs[
      key].target else: nil)
  if result.isNil:
    result = CollectionValue[Option[T]](value: source.get(key), owner: source)
    let link = ProjectionLink[Option[T]](target: result)
    result.handle.link = link
    source.itemRefs[key] = link
    # Sweep only after enough new projections to amortize the table scan.
    inc source.newItems
    if source.newItems >= source.pruneAfter:
      var expired: seq[K]
      for id, entry in source.itemRefs:
        if entry.target.isNil:
          expired.add id
      for id in expired:
        source.itemRefs.del(id)
      source.newItems = 0
      source.pruneAfter = max(64, source.itemRefs.len)

proc setValue*[K, T](source: CollectionSigil[K, T], values: seq[T]) =
  ## Validate and index the entire snapshot before mutation. Publish one whole
  ## change, optionally one order change, and only changed observed items.
  ## All reads see the new state before any callback. Recursive writes are rejected.
  if source.publishing:
    raise newException(ValueError, "cannot publish a collection recursively")
  var positions = initTable[K, int]()
  var keys: seq[K]
  for i, value in values:
    let key = source.keyOf(value)
    if positions.hasKey(key):
      raise newException(ValueError, "duplicate collection identity")
    positions[key] = i
    keys.add key
  if source.values == values:
    return
  let order = (if source.orderRef.isNil: nil else: source.orderRef.target)
  let moved = keys != source.keys
  var changed: seq[tuple[observed: CollectionValue[Option[T]], value: Option[T]]]
  var expired: seq[K]
  for key, link in source.itemRefs:
    let observed = link.target
    if observed.isNil:
      expired.add key
    else:
      let index = positions.getOrDefault(key, -1)
      let next =
        if index < 0:
          none(T)
        else:
          some(values[index])
      if observed.value != next:
        # Stage changed observations; update their values after comparison succeeds.
        changed.add (observed, next)
  source.values = values
  source.positions = positions
  source.keys = keys
  for key in expired:
    source.itemRefs.del(key)
  if not order.isNil:
    order.value = keys
  for item in changed:
    item.observed.value = item.value
  source.publishing = true
  defer:
    source.publishing = false
  if moved and not order.isNil:
    emit order.change({Changed})
  for item in changed:
    emit item.observed.change({Changed})
  emit source.change({Changed})

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
  if source.keyOf(value) != key:
    raise newException(ValueError, "replacement must preserve collection identity")
  var next = source.snapshot()
  next[source.positions[key]] = value
  source.setValue(next)
