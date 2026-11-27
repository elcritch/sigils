## Compare the regular subscription lookup with a signal-keyed Thetos prototype.
import std/[monotimes, times]
import sigils/agents
import thetos/[box, triemap]

type
  TrieAgent = ref object of Agent
    slots: TrieMap[SigilName, Box[seq[Subscription]]]
    wildcard: Box[seq[Subscription]]

  Receiver = ref object of Agent
    calls: int

proc receive(agent: Agent, params: SigilParams) =
  inc Receiver(agent).calls

proc insert(owner: Agent, signal: SigilName, subscription: Subscription) =
  doAssert owner.subcriptions.addSubscriptionSorted(signal, subscription)

proc insert(owner: TrieAgent, signal: SigilName, subscription: Subscription) =
  if signal == AnySigilName:
    var bucket = owner.wildcard.getOrDefault()
    bucket.add subscription
    owner.wildcard = box.box(move bucket)
  else:
    var bucket = owner.slots.getOrDefault(signal).getOrDefault()
    bucket.add subscription
    owner.slots[signal] = box.box(move bucket)

iterator matchingSlots(owner: Agent, signal: SigilName): lent Subscription =
  for subscription in owner.getSubscriptions(signal):
    yield subscription

iterator matchingSlots(owner: TrieAgent, signal: SigilName): lent Subscription =
  let exact =
    if signal != AnySigilName: owner.slots.getOrDefault(signal)
    else: default(Box[seq[Subscription]])
  let wildcard = owner.wildcard
  let wildcardFirst = not wildcard.isEmpty and compareSigilName(AnySigilName,
      signal) < 0
  if wildcardFirst:
    for subscription in wildcard[]:
      yield subscription
  if not exact.isEmpty:
    for subscription in exact[]:
      yield subscription
  if not wildcardFirst and not wildcard.isEmpty:
    for subscription in wildcard[]:
      yield subscription

proc run[Owner: Agent](signals, fanout: int) =
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
  const lookups = 1_000_000
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
  echo (when Owner is TrieAgent: "trie" else: "sorted-seq"),
    " signals=", signals, " fanout=", fanout,
    " setup_ns_per_connection=", setupNs.float / (ownerCount * signals *
        fanout).float,
    " retained_bytes_per_owner=", retainedBytes.float / ownerCount.float,
    " lookup_ns=", lookupNs.float / lookups.float

echo "string_names=", sigilsSigilNameStringEnabled
for signals in [1, 4, 16, 64]:
  for fanout in 1..4:
    run[Agent](signals, fanout)
    run[TrieAgent](signals, fanout)
