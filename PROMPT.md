# Continuation prompt: Sigils move/sink ownership work

Continue the ownership/move-semantics fix for the Merenda markdown emphasis crash.

## Repository layout

- Merenda worktree: `/Volumes/projects/nims/merenda-fix-markdown-emphasis-crash`
- Sigils repository/worktree: `/Volumes/projects/nims/merenda-fix-markdown-emphasis-crash/deps/sigils`
- Merenda root is also present at `/Volumes/projects/nims/merenda`; do not overwrite unrelated user changes there.
- Current Sigils branch: `fix/sink-payload-ownership`
- Intended base: `main`
- Existing GitHub issue: https://github.com/elcritch/sigils/issues/56
- GitHub identity/origin is `elcritch`; the eventual PR should target `elcritch/sigils:main`.

The user explicitly asked to use a worktree, Docker when useful, and to stop after this prompt is written. Do not continue implementation or testing in this instance.

## Original problem and goal

Merenda originally wrapped the markdown AST in `SharedPtr`. The intended fix is to remove that wrapper and use moves. Sigils tuple packing and Variant delivery exposed ownership bugs, especially for `sink` payloads. The exact Nim primitive is `ensureMove` (not `ensureMoved`). The user also wants explicit ownership tests using custom types with `=destroy`, `=wasMoved`, `=copy`, and/or `=moved` as applicable.

The design should preserve ordinary copy/fanout behavior while making a final/owned delivery move the payload through tuple packing and Variant extraction. Do not assume that a `sink` parameter alone causes all intermediate containers/closures to move correctly.

## History of the investigation

This is the full path that led to the current design. Keep it in mind when evaluating a simpler alternative; several apparently small changes have already been tried and exposed different ownership boundaries.

1. Work started from Merenda branch `fix/markdown-emphasis-crash`, in a dedicated Merenda worktree. The markdown AST had been wrapped in `SharedPtr`; the intended Merenda change was to remove that wrapper and pass/return the AST by value using moves. The Merenda build/CI failure showed that the problem was not confined to the markdown code: Sigils' signal/slot request machinery packed the values into tuples and then into a Variant, so a nominally moved AST could still be copied, consumed too early, or be unavailable when unpacked.
2. The Sigils dependency was intentionally worked on in its own nested worktree/branch rather than modifying an unrelated checkout. The working folders are the two paths listed above. The Merenda root has an unrelated local `merenda.nimble` dependency-line change and it must remain uncommitted while the Sigils PR is prepared.
3. Initial experiments used `sink` payload arguments and added explicit `ensureMove` calls while constructing request tuples, unpacking tuples, putting values into Variants, and forwarding thread messages. The first implementation introduced a parallel move-only callback family (`AgentMoveProc` and related move-slot metadata) and a `callMethodMove` path. This made the immediate sink tests work, but it duplicated callback/dispatch paths and created compatibility problems.
4. The work then added custom ownership probes. These types record copies, destroys, and moved-from transitions through `=copy`, `=destroy`, and `=wasMoved`; they are more useful than checking only the final value because a final value can be correct even when an intermediate copy happened. Tests were added for grouped sink parameters, generic sink parameters, fanout, direct/packed slots, deduplication, retained packed request reuse, closures, and threaded delivery.
5. Docker was used with a Nim 2.2.10 image. The configured `docker1` context did not expose direct volume mounts as expected, so the reliable workflow is a temporary container plus `docker cp`. The earlier Docker run had one `tslotsThread` SIGSEGV in `threadDefault.join`; the same failure was reproducible against the original image snapshot, so it was treated as a pre-existing/flaky runtime issue until rerun against the final tree. The Docker VM was restarted once during the investigation.
6. An Astra high-level review was requested after the ownership paths were understood. The review found the parallel move callback design was too invasive and specifically called out reusable requests, dynamic `callMethod` overrides, endpoint closure environments, typed threaded connection metadata, `Isolated[T]`, and callback identity. The design was consequently folded back into one ordinary callback path with explicit request delivery mode.
7. The current approach therefore does not use a public “move callback” type. It marks a particular packed request as `Copy` or `Consume`; the generated ordinary callback chooses copy unpacking or destructive move unpacking from that mode. Fanout clones earlier deliveries; the final owned delivery is consumed. Public packed-request `emit` is intentionally copy-preserving so the same retained request can be emitted more than once.
8. A later Astra xhigh review (agent `Goodall`) reviewed this simplified design and agreed that the single callback plus explicit ownership boundary is easier to reason about. It also kept the warnings about closure environments, cross-thread receiver-bound closures, `Isolated[T]` fanout, and preserving dynamic dispatch. The review is complete; use its findings as design context, not as a reason to reintroduce the removed parallel API.
9. The user then asked whether `Isolated[ref T]`, a custom wrapper, or internal copyable/movable/not-copyable argument metadata could make this general problem simpler. The conclusion so far is that a wrapper can document or enforce isolation at selected boundaries, but it cannot by itself make tuple packing, cloners, callback generation, Variant extraction, or endpoint transport move-only. Internal metadata is still needed to distinguish copy delivery from consumed delivery. A future public API may expose stronger contracts, but the current patch should stay focused and avoid pretending that a type label is compiler enforcement.
10. The user also asked for a Sigils issue and PR containing all findings, the solution, and limitations. Issue #56 already exists. Do not forget to update it with the final implementation and test evidence after the code is settled.

## Nim syntax and behavior notes

These notes record the behavior relevant to this bug. Verify against the checked-out compiler if a future change depends on a subtle point, but do not lose these distinctions.

- The correct compiler/library helper used at transfer boundaries is `ensureMove`, not `ensureMoved`. Use the call form already used in this tree, for example `ensureMove(req)` or `ensureMove(res)`. Do not invent a similarly named helper.
- `move x` and `sink` are related but not interchangeable design documentation. A `sink` parameter gives the callee an ownership-taking parameter, but it does not automatically prove that every tuple constructor, generic helper, closure environment, Variant constructor, thread message, or fanout branch moved the value. `ensureMove` is used at the exact point where the implementation intentionally transfers the current value.
- A sink parameter can still be forwarded incorrectly if it is first placed in a copyable tuple or passed through a generic function whose argument is not a sink. Track the value through every intermediate representation rather than relying on the final proc signature.
- The ownership hooks used by the tests have Nim backtick names. The relevant forms are conceptually:

  ```nim
  proc `=destroy`(value: var T) = ...
  proc `=copy`(dest: var T; source: T) = ...
  proc `=sink`(dest: var T; source: T) = ...
  proc `=wasMoved`(value: var T) = ...
  ```

  The exact hook set depends on the type and compiler version. The moved-from hook is `=wasMoved`; it is not `=moved`. `=destroy` is called for cleanup, `=copy` records/implements copying, and `=wasMoved` resets or records the source after a move. Do not infer a move solely from the presence of a `sink` formal parameter.
- A custom `=copy` hook generally makes the type copyable. A type with no valid cloner may still be transportable for one consuming delivery if it is moved into owned storage, but fanout/reuse then cannot clone it. The implementation must report or reject the copy path rather than silently copy or leave uninitialized state.
- `Isolated[T]` from `std/isolation` is a special ownership/isolation wrapper. It is not a general “this method argument must be moved” annotation. It can be passed through a specialized `rpcPack(sink Isolated[T])` overload that stores an owned moved value with no cloner, but a generic `rpcPack` that unconditionally asks for `clonerFor(T)` rejects it. The generic `when compiles` experiment was not reliable enough here, so the specialized overload is explicit.
- `Isolated[ref T]` is also not equivalent to moving the object itself: moving a reference-shaped handle and moving the identity-bearing object have different semantics. Do not use it as a substitute for the request's consumed-delivery bit without a compiler-enforced contract and tests.
- `Variant` storage is another ownership boundary. `newOwnedVariant(ensureMove(value))` intentionally transfers the value into the Variant. `takeVariant` is destructive: it extracts the payload and clears the Variant's type/debug metadata. It must only be used on the consumed path. The clone path needs a valid cloner and must not call `takeVariant`.
- Tuple packing is generated by the signal/slot macros. Grouped signal/slot parameters may be represented as a tuple, and generated code must flatten grouped parameters consistently when constructing and unpacking the request. Apply `ensureMove` to each sink payload at the generated ownership-transfer boundary; do not only move the outer tuple and assume nested fields were moved.
- Generated callbacks have to support both copy and consume modes. The current callback is an ordinary `AgentProc`; in consume mode it uses `rpcUnpackMove` after an explicit `ensureMove`, and in copy mode it uses `rpcUnpack`. A runtime `ValueError` is preferable to silently copying a non-copyable sink payload when the copy construction cannot compile.
- `AgentProc`/`callMethod` are existing dynamic dispatch seams. A separate `callMethodMove` implementation can accidentally bypass user overrides or virtual behavior. Keep the ordinary `callMethod` path and pass the delivery mode in `SigilParams` instead.
- Direct slots, packed slots, and receiver-bound closure slots are not interchangeable. Direct slots can use a generated clone wrapper for non-final fanout; packed/endpoint slots need request metadata. Receiver-bound closure slots also carry `envSlot` and `env`; dropping those fields can turn a valid callback into `METHOD_NOT_FOUND` or invoke the wrong target.
- `nimcall`, `gcsafe`, and closure-enabled builds affect which callback types can be stored/transmitted. Keep closure-specific fields under the existing `sigilsSlotEnvDisabled`/closures feature guards and do not put a non-serializable closure environment into a cross-thread `ThreadSignal` unless the architecture explicitly supports it.
- A receiver-bound closure environment is safe for same-thread dispatch in the current design. The current cross-thread fallback should return an internal error rather than drop the environment. If a future design transports it, it must establish ownership and lifetime rules first.
- A `static consumeLast: bool` generic parameter is compile-time control over whether the final local delivery may consume the request; it is not the same thing as the runtime `SigilParamsMode`. Keep the two concepts separate: one chooses the delivery algorithm, the other records whether the packed payload is currently allowed to be destructively unpacked.
- `ref object` and reference-counted handles often copy the handle while preserving object identity. That is different from proving a value payload was moved. The tests should use a value type with observable hooks when validating ownership.
- ARC/ORC is required by Sigils. Tests and probes must use the repository's Atlas configuration and should not silently fall back to a GC build.
- The project uses Atlas, not Nimble. Dependency paths come from `deps/` and `nim.cfg`; do not create or update Nimble lock state. Format touched Nim files with `nph` and keep two-space indentation.

## Current design direction

An Astra xhigh review was completed (agent `Goodall`, now closed). It identified that a parallel `AgentMoveProc` API was too complex and had several hazards:

1. A reusable `SigilRequest` could be consumed by a second delivery.
2. A new `callMethodMove` path bypassed existing dynamic `callMethod` overrides.
3. Endpoint dispatch dropped receiver-bound closure environment metadata.
4. Typed threaded connections could lose move metadata after slot resolution.
5. `Isolated[T]` was not packable because the generic cloner requirement rejected it.
6. Move-only callback identity/`hasCallable` behavior was fragile.
7. Local behavior differed depending on packed versus direct syntax.

The current implementation is being simplified to one `AgentProc` callback path plus private delivery-mode metadata on `SigilParams`:

- `SigilParamsMode = {Copy, Consume}` is stored in `SigilParams`.
- Normal `rpcPack` creates `Copy` params.
- A final/owned delivery marks params `Consume`.
- The generated ordinary slot callback checks `params.isConsumedDelivery()` and uses `rpcUnpackMove(... ensureMove(...))` only in that mode; otherwise it uses copy unpacking.
- `callSlotsImpl` consumes only the final delivery by default; earlier fanout deliveries clone the request.
- Public `emit((Agent, SigilRequest))` uses a copy-preserving path so a retained packed request can be emitted twice.
- `callSlotsCopy` is available for explicitly copy-preserving delivery.
- The older parallel `AgentMoveProc`, `callMethodMove`, and move-slot metadata API was removed.
- Receiver-bound closure endpoint dispatch now has a separate `dispatchSubscription` callback carrying `envSlot`/`env`, while the old dispatch callback remains for compatibility.
- Cross-thread receiver-bound closure slots should return a clear internal error rather than silently dropping their environment.
- Existing dynamic `callMethod` dispatch must remain in the normal path so overrides are not bypassed.

## Important current code changes

The main touched files are in `/Volumes/projects/nims/merenda-fix-markdown-emphasis-crash/deps/sigils`:

- `sigils/protocol.nim`
  - Added `SigilParamsMode`, `isConsumedDelivery`, `markConsumedDelivery`.
  - Added a specialized `rpcPack*[T](res: sink Isolated[T]): SigilParams` using `newOwnedVariant(ensureMove(res))` and no cloner.
  - Generic `rpcPack` currently uses `clonerFor(T)`.
  - `clone(SigilParams)` returns copy-mode params.
  - `rpcUnpackMove` remains destructive and uses `takeVariant`.
- `sigils/agents.nim`
  - Removed `AgentMoveProc`, `EnvAgentMoveProc`, `AgentMoveSlotInfo`, `packedMoveSlot`, and `envMoveSlot`.
  - Added `dispatchSubscription` to `AgentDelivery` so receiver-bound closure environments survive endpoint dispatch.
  - Subscription metadata now uses the ordinary packed/direct callback plus clone metadata.
  - Compatibility support remains for the old five-argument `addSubscription` virtual hook; delivery metadata is updated afterward.
- `sigils/actors.nim`
  - Thread signal `Call` no longer carries move-slot callback fields.
  - Added `AgentActor.updateSubscriptionDelivery` under the actor lock.
- `sigils/core.nim`
  - Removed `callMethodMove`.
  - Ordinary generated `AgentProc` selects move versus copy based on `SigilParamsMode`.
  - `deliverSubscription` marks consumed params only for the owned/final path.
  - Added `callSlotsCopy` and made public packed-request `emit` copy-preserving.
- `sigils/slots.nim`
  - Generated sink slots branch on delivery mode and use `ensureMove` before `rpcUnpackMove`.
  - Grouped sink parameters are flattened consistently.
  - Direct clone wrappers clone sink fields and raise `ValueError` if cloning is unavailable.
- `sigils/closures.nim`
  - Closure callbacks branch on delivery mode and use `rpcUnpackMove` with `ensureMove` for consumed delivery.
  - Receiver-bound closure subscriptions retain environment metadata.
- `sigils/threadBase.nim` and `sigils/threadProxies.nim`
  - Thread messages no longer carry a separate move callback.
  - Endpoint dispatch has a subscription-aware path for receiver-bound environments.
  - Cross-thread receiver-bound closure delivery reports an internal error.
  - Threaded connect templates use the ordinary `addSubscription` API.
- `sigils/threadAsyncs.nim`, `threadChronos.nim`, `threadDefault.nim`, `threadPool.nim`, `threadSelectors.nim`
  - Existing changes ensure thread messages are moved with `ensureMove`.
- `sigils/registry.nim`
  - Removed old move-slot fields from proxy signal cloning.
- `tests/tvariantThreadOwnership.nim`
  - Contains custom `OwnershipProbe` hooks and tests for packed slot reuse, reusable copy-preserving requests, threaded sink payloads, managed/fanout behavior.
- `tests/tslots.nim`
  - Contains custom `MoveTrackedPayload` hooks and tests for grouped sink parameters, generic sinks, identity refs, fanout, dedup, and mixed direct delivery.
- `tests/tclosures.nim`
  - Contains sink closure coverage.
- `tests/tslotsThread.nim`
  - Threaded slots compile/runtime coverage; the target `WeakRef` issue was fixed with `.asAgent()`.

## Known test facts

The following happened before this prompt was written:

- Nim 2.2.12 local full host suite: `51/53 passed, 2 failed`.
  - Known unrelated failure: `tests/tsiwinEventLoop.nim` callback signature mismatch because Nim 2.2.12 changed `installEventLoopWakeProc` to take backend data/close proc.
  - Known unrelated failure: `tests/tselectorScopedProtocols.nim` expected a long selector compile-time error that was not observed.
- An earlier Docker Nim 2.2.10 run had `52/53 passed`; `tests/tslotsThread.nim` hit a SIGSEGV in `threadDefault.join`. This also occurred against the original image snapshot and looked flaky/unrelated. Rerun Docker tests against the final current source before claiming success.
- The fresh compile probe for `Isolated` succeeded:

  ```sh
  nim c --mm:arc --path:sigils --path:deps \
    --eval:'import std/isolation; import sigils/protocol; var x = isolate(17); discard rpcPack(move x)'
  ```

  It compiled successfully under the local Nim 2.2.12 setup.

## Immediate next steps

1. Inspect `git diff`, `git status`, and `git diff --check` in the Sigils worktree. Preserve unrelated user changes.
2. Search for stale symbols:

   ```sh
   rg -n "AgentMoveProc|EnvAgentMoveProc|AgentMoveSlotInfo|packedMoveSlot|envMoveSlot|callMethodMove|ensureMoved" sigils tests
   ```

   `ensureMoved` should not remain; the correct primitive is `ensureMove`.
3. Format touched Nim files with `nph` as required by the repository. Do not use Nimble; use Atlas and the repository `deps/`/`nim.cfg` setup.
4. Run focused local tests first, including `tslots`, `tclosures`, `tvariantThreadOwnership`, and `tslotsThread`; then run the full Sigils host suite with `atlas-run tests`.
5. Inspect and fix any remaining endpoint condition that checks only `endpoint[].dispatch` instead of both `dispatch` and `dispatchSubscription`.
6. Review `findSubscribedTo` and `moveToThread` in `sigils/threadProxies.nim`. Preserve receiver-bound closure `envSlot`, `env`, and connection state when reconstructing subscriptions if the existing architecture permits it.
7. Add or strengthen an explicit `Isolated[T]` ownership test if it can be expressed cleanly. Test a custom move-tracked type across the complete chain: signal argument -> tuple packing -> Variant -> endpoint/slot -> unpack. Avoid tests that depend on undocumented `sink` behavior alone.
8. Consider a focused test proving ordinary dynamic `callMethod` overrides are still used by delivery.
9. Recreate a fresh temporary Docker container from the local image and copy the final Sigils source into it. Direct volume mounts through the configured `docker1` context were empty, so use `docker cp`. Run Atlas tests under Docker Nim 2.2.10, including the focused suites and full suite. The old container name `sigils-ci-current` may exist and should be replaced only after checking it is the exact temporary container.
10. Run the relevant Merenda markdown/integration tests with the nested Sigils dependency if appropriate.
11. Commit only the Sigils changes on `fix/sink-payload-ownership`, push, and create a PR against `main` referencing issue #56. Do not commit the unrelated Merenda root change to `merenda.nimble`:

    ```text
    requires "gh:elcritch/sigils#main [sigNameAsString, closures, siwin, chronos]"
    ```

12. Add a detailed issue #56 comment describing the final design, tests, Astra xhigh review findings, and limitations. Mention that `Isolated[T]` is supported for single-consumer packing but fanout requires cloning and receiver-bound closure slots cannot cross a thread boundary unless their environment can be safely transported.
13. Clean up only the exact temporary Docker container(s) created for this work. Do not delete broad directories or unrelated containers.

## Design questions to keep explicit

- `sink` on a method argument is not by itself a reliable whole-chain move contract; tuple packing, Variant storage, callback generation, endpoint dispatch, and fanout each need an explicit ownership decision.
- `ensureMove` should be used at ownership-transfer boundaries.
- A wrapper such as `Isolated[ref T]` may communicate isolation but does not automatically make every generic packer, cloner, callback, or endpoint move-only. Internal metadata needs to distinguish copyable versus consumed delivery.
- A future Sigils API could model copyable, movable, and non-copyable callback/payload contracts more directly, but do not expand the public API unless the implementation and tests justify it.
- The simpler current direction is one callback type plus per-request delivery mode, preserving ordinary dynamic dispatch and making fanout/copy behavior explicit.
