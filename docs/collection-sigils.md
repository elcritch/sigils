# Observable keyed collections

`CollectionSigil[K, T]` adds collection semantics to the familiar Sigil publication
pattern. Items and snapshots remain plain Nim values. The collection owns one
authoritative snapshot and a key index; projections are read-only.

```nim
import std/options
import sigils/collections

type Task = object
  id: int
  title: string

proc taskId(task: Task): int = task.id

let tasks = newCollectionSigil(@[Task(id: 1, title: "Draft")], taskId)
let order = tasks.order       # CollectionValue[seq[int]]
let first = tasks.item(1)     # CollectionValue[Option[Task]]
tasks[1] = Task(id: 1, title: "Ready")
assert first{}.get.title == "Ready"
assert order{} == @[1]
```

- `tasks{}` / `snapshot()` returns the whole value snapshot; `<-` replaces it.
- `tasks[id]` is an indexed lookup by **key**, raising `KeyError` when absent.
  `get(id)` returns `Option[T]`; `contains`, `len`, `items`, and `pairs` are also available.
- `tasks.order` changes only when membership or ordering changes.
- `tasks.item(id)` changes only when that item's value changes. It publishes
  `none(T)` on removal and follows the identity if it is reinserted.
- `tasks[id] = value` replaces an existing item and requires the same key.

Whole snapshots, order, and item projections support Sigils' scoped `{}` reads
and explicit `change` subscriptions. Import `sigils/reactive` for computed values
and reactive helpers.
Read-only projections have no setter; commands publish through the collection,
so they cannot accidentally diverge from the authoritative model.

Publication validates unique keys, builds the new index, and compares observed
items **before mutation**. Every snapshot and projection is updated before the
first notification. A duplicate-key error leaves the collection unchanged.
Synchronous recursive publication raises `ValueError`; schedule dependent writes
after the current publication. Subscriber exceptions do not roll back committed
state or promise delivery to remaining subscribers.

Projections are allocated only on demand. Repeated `item(id)` calls share a live
observation. A projection retains its collection; the collection keeps a
teardown-managed non-owning link back. Dropping projections releases them without
a cycle. Expired item entries are pruned on changed publication and periodically
as new observations are requested. Cache hits are expected O(1); pruning scans
are amortized across newly created projections.

Observation channels use the same signals/slots and scoped read mechanism.
All collection and projection operations belong on one owning thread.
Reference-bearing item fields retain their usual Nim aliasing semantics: use plain values and replacement publication
for observable changes, rather than mutating shared refs behind the collection.

Snapshot replacement is O(n + m), where m is the number of observed identities;
only changed observations notify bindings. Indexed lookup is expected O(1).
Single-item assignment still copies and validates a snapshot; it is not an O(1)
persistent-data-structure update. Undo snapshots, sorting/filtering, and virtualized
table/collection presentation remain controller responsibilities.

Computed expressions retain projections used in their most recent evaluation and
disconnect collection projections that are no longer read. Ordinary `Sigil`
dependencies retain their existing subscription behavior.
Explicit connections use normal Sigils ownership: keep the projection alive while observing it.
