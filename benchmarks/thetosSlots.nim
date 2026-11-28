## Compare regular subscription lookup with boxed and vector Thetos buckets.
import std/[monotimes, times]
import sigils/agents
import thetos/[box, triemap, trievec]

type
  BoxedSlots = Box[seq[Subscription]]
  VectorSlots = TrieVec[Subscription]

  TrieAgent[Bucket] = ref object of Agent
    slots: TrieMap[SigilName, Bucket]
    wildcard: Bucket

  Receiver = ref object of Agent
    calls: int

proc receive(agent: Agent, params: SigilParams) =
  inc Receiver(agent).calls

proc insert(owner: Agent, signal: SigilName, subscription: Subscription) =
  doAssert owner.subcriptions.addSubscriptionSorted(signal, subscription)

proc add(bucket: var BoxedSlots, subscription: Subscription) =
  var entries = bucket.getOrDefault()
  entries.add subscription
  bucket = box.box(move entries)

proc hasSlots(bucket: BoxedSlots): bool {.inline.} =
  not bucket.isEmpty

proc hasSlots(bucket: VectorSlots): bool {.inline.} =
  bucket.len != 0

iterator items(bucket: BoxedSlots): lent Subscription =
  if bucket.hasSlots:
    for subscription in bucket[]:
      yield subscription

proc insert[Bucket](
    owner: TrieAgent[Bucket], signal: SigilName, subscription: Subscription
) =
  if signal == AnySigilName:
    owner.wildcard.add subscription
  else:
    var bucket = owner.slots.getOrDefault(signal)
    bucket.add subscription
    owner.slots[signal] = move(bucket)

iterator matchingSlots(owner: Agent, signal: SigilName): lent Subscription =
  for subscription in owner.getSubscriptions(signal):
    yield subscription

iterator matchingSlots[Bucket](
    owner: TrieAgent[Bucket], signal: SigilName
): lent Subscription =
  let exact =
    if signal != AnySigilName: owner.slots.getOrDefault(signal)
    else: default(Bucket)
  let wildcard = owner.wildcard
  let wildcardFirst = wildcard.hasSlots and compareSigilName(AnySigilName,
      signal) < 0
  if wildcardFirst:
    for subscription in wildcard:
      yield subscription
  for subscription in exact:
    yield subscription
  if not wildcardFirst:
    for subscription in wildcard:
      yield subscription

proc run[Owner: Agent](backend: static string, signals, fanout: int) =
  let ownerCount = min(20_000, 250_000 div (signals * fanout))
  var receivers = newSeq[Receiver](fanout)
  var subscriptions = newSeq[Subscription](fanout)
  for i in 0..<fanout:
    receivers[i] = Receiver()
    subscriptions[i] = Subscription(
      tgt: receivers[i].unsafeWeakRef().asAgent(), packedSlot: receive
    ).prepareSubscription()
  var keys = newSeq[SigilName](signals)
  for i, key in keys.mpairs:
    key = toSigilName("valueChanged" & $i)
  let missing = toSigilName("unconnected")

  var owners = newSeq[Owner](ownerCount)
  defer:
    for owner in owners:
      # These low-level registrations bypass the receiver's listener bookkeeping.
      owner.subcriptions.setLen(0)

  let before = getOccupiedMem()
  let setupStart = getMonoTime()
  for owner in owners.mitems:
    owner = Owner()
    for signal in keys:
      for subscription in subscriptions:
        owner.insert(signal, subscription)
  let setupNs = (getMonoTime() - setupStart).inNanoseconds
  let retainedBytes = getOccupiedMem() - before
  doAssert retainedBytes > 0, "compile with Nim's allocator"

  let lookupStart = getMonoTime()
  let lookups = 4 * (250_000 div max(1, fanout div 4))
  var ownerIndex, keyIndex: int
  for i in 0..<lookups:
    let signal = if (i and 3) == 0: missing else: keys[keyIndex]
    for subscription in owners[ownerIndex].matchingSlots(signal):
      subscription.packedSlot(subscription.tgt[], default(SigilParams))
    inc ownerIndex
    if ownerIndex == ownerCount:
      ownerIndex = 0
    if (i and 3) != 0:
      inc keyIndex
      if keyIndex == signals:
        keyIndex = 0
  let lookupNs = (getMonoTime() - lookupStart).inNanoseconds
  for receiver in receivers:
    doAssert receiver.calls == lookups * 3 div 4
  echo backend,
    " signals=", signals, " fanout=", fanout,
    " setup_ns_per_connection=", setupNs.float / (ownerCount * signals *
        fanout).float,
    " retained_bytes_per_owner=", retainedBytes.float / ownerCount.float,
    " lookup_ns=", lookupNs.float / lookups.float

proc compareStores(signals, fanout: int) =
  run[Agent]("sorted-seq", signals, fanout)
  run[TrieAgent[BoxedSlots]]("trie", signals, fanout)
  run[TrieAgent[VectorSlots]]("trie-vector", signals, fanout)

echo "names=", (when sigilsSigilNameStringEnabled: "string"
  else: "stack")
for signals in [1, 4, 16, 64]:
  for fanout in 1..4:
    compareStores(signals, fanout)
for signals in [1, 16]:
  compareStores(signals, 64)
