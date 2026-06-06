import std/[os, osproc, strutils, unittest]

import sigils/core
import sigils/selectors

type
  ListView = ref object of DynamicAgent
    xDelegate: DynamicAgent

  ListDelegateSpy = ref object of DynamicAgent
    changingCount: int
    changedCount: int
    activatedCount: int
    reloadedCount: int
    lastSender: DynamicAgent

  ReceiverBoundListDelegateSpy = ref object of DynamicAgent
    changedCount: int
    lastSender: DynamicAgent

  NamedVariantListDelegateSpy = ref object of DynamicAgent
    changedCount: int
    lastSender: DynamicAgent

  CompleteListDelegateSpy = ref object of DynamicAgent
    changingCount: int
    changedCount: int
    activatedCount: int
    ignoredCount: int
    lastSender: DynamicAgent

protocol ListViewDelegate:
  method shouldSelectRow*(listView: ListView, row: int): bool {.optional.}

protocol ListViewEvents:
  proc selectionIsChanging*(listView: ListView, sender: DynamicAgent) {.signal.}
  proc selectionDidChange*(listView: ListView, sender: DynamicAgent) {.signal.}
  proc rowWasActivated*(listView: ListView, sender: DynamicAgent) {.signal.}
  proc selectionWasIgnored*(listView: ListView, sender: DynamicAgent) {.signal.}

protocol ListViewObserverSlots:
  proc selectionIsChanging*(sender: DynamicAgent) {.slot.}
  proc selectionDidChange*(sender: DynamicAgent) {.slot.}
  proc rowWasActivated*(sender: DynamicAgent) {.slot.}
  proc selectionWasIgnored*(sender: DynamicAgent) {.slot.}

protocol ListViewReloadEvents:
  proc listWasReloaded*(listView: ListView, sender: DynamicAgent) {.signal.}

protocol StrictListViewEvents:
  includes ListViewEvents, ListViewReloadEvents

protocol ReceiverBoundListDelegateSpyEvents from ReceiverBoundListDelegateSpy:
  includes ListViewEvents

  proc selectionDidChange*(
      delegate: ReceiverBoundListDelegateSpy, sender: DynamicAgent
  ) {.slot.} =
    inc delegate.changedCount
    delegate.lastSender = sender

protocol NamedVariantListDelegateSpyEvents of ListViewEvents:
  proc selectionDidChange*(
      delegate: NamedVariantListDelegateSpy, sender: DynamicAgent
  ) {.slot.} =
    inc delegate.changedCount
    delegate.lastSender = sender

proc selectionIsChanging*(delegate: ListDelegateSpy,
    sender: DynamicAgent) {.slot.} =
  inc delegate.changingCount
  delegate.lastSender = sender

proc selectionDidChange*(delegate: ListDelegateSpy,
    sender: DynamicAgent) {.slot.} =
  inc delegate.changedCount
  delegate.lastSender = sender

proc rowWasActivated*(delegate: ListDelegateSpy,
    sender: DynamicAgent) {.slot.} =
  inc delegate.activatedCount
  delegate.lastSender = sender

proc listWasReloaded*(delegate: ListDelegateSpy,
    sender: DynamicAgent) {.slot.} =
  inc delegate.reloadedCount
  delegate.lastSender = sender

proc selectionIsChanging*(
    delegate: CompleteListDelegateSpy, sender: DynamicAgent
) {.slot.} =
  inc delegate.changingCount
  delegate.lastSender = sender

proc selectionDidChange*(
    delegate: CompleteListDelegateSpy, sender: DynamicAgent
) {.slot.} =
  inc delegate.changedCount
  delegate.lastSender = sender

proc rowWasActivated*(
    delegate: CompleteListDelegateSpy, sender: DynamicAgent
) {.slot.} =
  inc delegate.activatedCount
  delegate.lastSender = sender

proc selectionWasIgnored*(
    delegate: CompleteListDelegateSpy, sender: DynamicAgent
) {.slot.} =
  inc delegate.ignoredCount
  delegate.lastSender = sender

proc checkInvalidProtocolExample(fileName, expected: string) =
  let
    repoRoot = parentDir(parentDir(currentSourcePath()))
    sourcePath = repoRoot / "tests" / "examples" / fileName
    nimcache = repoRoot / ".nimcache" / fileName.changeFileExt("")

  let (output, exitCode) = execCmdEx(
    "nim check --hints:off --warnings:off --path:" & quoteShell(repoRoot) &
      " --nimcache:" & quoteShell(nimcache) & " " & quoteShell(sourcePath),
    options = {poStdErrToStdOut, poUsePath},
    workingDir = repoRoot,
  )

  check exitCode != 0
  check output.contains(expected)

suite "protocol signal-slot connection":
  test "connectProtocol connects matching slots and ignores missing slots":
    let
      listView = ListView()
      delegate = ListDelegateSpy()
      sender = DynamicAgent()

    connectProtocol(listView, delegate, ListViewEvents)

    check listView.hasSubscription(toSigilName("selectionIsChanging"), delegate)
    check listView.hasSubscription(toSigilName("selectionDidChange"), delegate)
    check listView.hasSubscription(toSigilName("rowWasActivated"), delegate)
    check not listView.hasSubscription(toSigilName("selectionWasIgnored"), delegate)

    emit listView.selectionIsChanging(sender)
    emit listView.selectionDidChange(sender)
    emit listView.rowWasActivated(sender)
    emit listView.selectionWasIgnored(sender)

    check delegate.changingCount == 1
    check delegate.changedCount == 1
    check delegate.activatedCount == 1
    check delegate.lastSender == sender

  test "disconnectProtocol removes matching protocol subscriptions":
    let
      listView = ListView()
      delegate = ListDelegateSpy()
      sender = DynamicAgent()

    connectProtocol(listView, delegate, ListViewEvents)
    disconnectProtocol(listView, delegate, ListViewEvents)

    check not listView.hasSubscription(toSigilName("selectionIsChanging"), delegate)
    check not listView.hasSubscription(toSigilName("selectionDidChange"), delegate)
    check not listView.hasSubscription(toSigilName("rowWasActivated"), delegate)

    emit listView.selectionIsChanging(sender)
    emit listView.selectionDidChange(sender)
    emit listView.rowWasActivated(sender)

    check delegate.changingCount == 0
    check delegate.changedCount == 0
    check delegate.activatedCount == 0

  test "observeProtocol supports observer-first workflow":
    let
      listView = ListView()
      delegate = ListDelegateSpy()
      sender = DynamicAgent()

    delegate.observeProtocol(listView, ListViewEvents)
    emit listView.selectionDidChange(sender)

    check delegate.changedCount == 1
    check delegate.lastSender == sender

    delegate.unobserveProtocol(listView, ListViewEvents)
    emit listView.selectionDidChange(sender)

    check delegate.changedCount == 1

  test "connectProtocol includes inherited protocol connections":
    let
      listView = ListView()
      delegate = ListDelegateSpy()
      sender = DynamicAgent()

    connectProtocol(listView, delegate, StrictListViewEvents)

    check listView.hasSubscription(toSigilName("selectionIsChanging"), delegate)
    check listView.hasSubscription(toSigilName("listWasReloaded"), delegate)

    emit listView.selectionIsChanging(sender)
    emit listView.listWasReloaded(sender)

    check delegate.changingCount == 1
    check delegate.reloadedCount == 1
    check delegate.lastSender == sender

  test "connectProtocol supports receiver-bound protocols that include events":
    let
      listView = ListView()
      delegate = ReceiverBoundListDelegateSpy().withProto()
      sender = DynamicAgent()

    connectProtocol(listView, delegate, ReceiverBoundListDelegateSpyEvents)

    check listView.hasSubscription(toSigilName("selectionDidChange"), delegate)

    emit listView.selectionIsChanging(sender)
    emit listView.selectionDidChange(sender)

    check delegate.changedCount == 1
    check delegate.lastSender == sender

  test "named protocol variants can provide matching event slots":
    let
      listView = ListView()
      delegate =
        NamedVariantListDelegateSpy().withProtocol(NamedVariantListDelegateSpyEvents)
      sender = DynamicAgent()

    check delegate.hasAdopted(ListViewEvents)

    connectProtocol(listView, delegate, NamedVariantListDelegateSpyEvents)

    check listView.hasSubscription(toSigilName("selectionDidChange"), delegate)

    emit listView.selectionDidChange(sender)

    check delegate.changedCount == 1
    check delegate.lastSender == sender

  test "named protocol variant event slots are available through observer bindings":
    let
      listView = ListView()
      delegate =
        NamedVariantListDelegateSpy().withProtocol(NamedVariantListDelegateSpyEvents)
      sender = DynamicAgent()

    check listView.setProtocolDelegate(
      listView.xDelegate, DynamicAgent(delegate), ListViewDelegate, ListViewEvents
    )
    check listView.hasSubscription(toSigilName("selectionDidChange"), delegate)

    emit listView.selectionDidChange(sender)

    check delegate.changedCount == 1
    check delegate.lastSender == sender

  test "setProtocolDelegate reconnects registered protocol event observers":
    let
      listView = ListView()
      first = ReceiverBoundListDelegateSpy().withProto()
      second = ReceiverBoundListDelegateSpy().withProto()
      sender = DynamicAgent()

    check listView.setProtocolDelegate(
      listView.xDelegate, DynamicAgent(first), ListViewDelegate, ListViewEvents
    )
    check listView.xDelegate == first
    check first.hasAdopted(ListViewDelegate)
    check listView.hasSubscription(toSigilName("selectionDidChange"), first)

    emit listView.selectionDidChange(sender)

    check first.changedCount == 1
    check first.lastSender == sender

    check listView.setProtocolDelegate(
      listView.xDelegate, DynamicAgent(second), ListViewDelegate, ListViewEvents
    )
    check listView.xDelegate == second
    check not listView.hasSubscription(toSigilName("selectionDidChange"), first)
    check listView.hasSubscription(toSigilName("selectionDidChange"), second)

    emit listView.selectionDidChange(sender)

    check first.changedCount == 1
    check second.changedCount == 1
    check second.lastSender == sender

    check not listView.setProtocolDelegate(
      listView.xDelegate, DynamicAgent(second), ListViewDelegate, ListViewEvents
    )

    check listView.setProtocolDelegate(
      listView.xDelegate, DynamicAgent(nil), ListViewDelegate, ListViewEvents
    )
    check listView.xDelegate.isNil
    check not listView.hasSubscription(toSigilName("selectionDidChange"), second)

  test "requireProtocolSlots checks explicitly declared protocol slots":
    requireProtocolSlots(CompleteListDelegateSpy, ListViewObserverSlots)

    static:
      doAssert not compiles(
        requireProtocolSlots(ListDelegateSpy, ListViewObserverSlots)
      )

  test "named protocol variants reject unmatched event slots":
    checkInvalidProtocolExample(
      "unmatchedProtocolEventSlot.nim",
      "protocol slot does not match any signal in protocol PublicWindowEvents",
    )
    checkInvalidProtocolExample(
      "mismatchedProtocolEventSlot.nim",
      "protocol signal slot windowDidClose has the wrong signature",
    )
