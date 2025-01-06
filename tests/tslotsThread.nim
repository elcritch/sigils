import std/isolation
import std/unittest
import std/os
import std/sequtils
import threading/atomics

import sigils
import sigils/threads

import std/terminal
import std/strutils

type
  SomeAction* = ref object of Agent
    value: int
    obj: InnerA

  Counter* = ref object of Agent
    value: int
    obj: InnerC

  InnerA = object
    id: int
  InnerC = object
    id: int

var globalLastInnerADestroyed: Atomic[int]
globalLastInnerADestroyed.store(0)
proc `=destroy`*(obj: InnerA) = 
  if obj.id != 0:
    echo "destroyed InnerA!"
  globalLastInnerADestroyed.store obj.id

var globalLastInnerCDestroyed: Atomic[int]
globalLastInnerCDestroyed.store(0)

proc `=destroy`*(obj: InnerC) = 
  if obj.id != 0:
    echo "destroyed InnerC!"
  globalLastInnerCDestroyed.store obj.id

proc valueChanged*(tp: SomeAction, val: int) {.signal.}
proc updated*(tp: Counter, final: int) {.signal.}

proc setValue*(self: Counter, value: int) {.slot.} =
  # echo "setValue! ", value, " id: ", self.getId().int, " (th: ", getThreadId(), ")"
  # echo "setValue! self:refcount: ", self.unsafeGcCount() 
  if self.value != value:
    self.value = value
  # echo "setValue:subcriptionsTable: ", self.subcriptionsTable.pairs().toSeq.mapIt(it[1].mapIt(cast[pointer](it.tgt.getId()).repr))
  # echo "setValue:listening: ", $self.listening.toSeq.mapIt(cast[pointer](it.getId()).repr)
  if value == 756809:
    os.sleep(1)
  emit self.updated(self.value)

var globalCounter: Atomic[int]
globalCounter.store(0)

proc setValueGlobal*(self: Counter, value: int) {.slot.} =
  echo "setValueGlobal! ", value, " id: ", self.getId().int, " (th: ", getThreadId(), ")"
  if self.value != value:
    self.value = value
  globalCounter.store(value)

var globalLastTicker: Atomic[int]
proc ticker*(self: Counter) {.slot.} =
  for i in 3..3:
    echo "tick! i:", i, " ", self.unsafeWeakRef(), " (th: ", getThreadId(), ")"
    globalLastTicker.store i
    # printConnections(self)
    emit self.updated(i)

proc completed*(self: SomeAction, final: int) {.slot.} =
  echo "Action done! final: ", final, " id: ", $self.unsafeWeakRef(), " (th: ", getThreadId(), ")"
  self.value = final

proc completedSum*(self: SomeAction, final: int) {.slot.} =
  when defined(debug):
    echo "Action done! final: ", final, " id: ", $self.unsafeWeakRef(), " (th: ", getThreadId(), ")"
  self.value = self.value + final

proc value*(self: Counter): int =
  self.value

suite "threaded agent slots":
  setup:
    printConnectionsSlotNames = {
      remoteSlot.pointer: "remoteSlot",
      localSlot.pointer: "localSlot",
      SomeAction.completed().pointer: "completed",
      ticker.pointer: "ticker",
      Counter.setValue().pointer: "setValue",
      setValueGlobal.pointer: "setValueGlobal",
    }.toTable()

  when true:
    test "simple thread setup":

      let ct = newSigilThread()
      check not ct.isNil

      var a = SomeAction.new()
      ct[].send(ThreadSignal(kind: Move, item: move a))


  when true:
    test "simple threading test":
      var
        a = SomeAction.new()
        b = Counter.new()
        c = Counter.new()

      var agentResults = newChan[(WeakRef[Agent], SigilRequest)]()

      connect(a, valueChanged, b, setValue)
      connect(a, valueChanged, c, Counter.setValue)

      let wa: WeakRef[SomeAction] = a.unsafeWeakRef()
      emit wa.valueChanged(137)
      check typeof(wa.valueChanged(137)) is (WeakRef[Agent], SigilRequest)

      check wa[].value == 0
      check b.value == 137
      check c.value == 137

      proc threadTestProc(aref: WeakRef[SomeAction]) {.thread.} =
        var res = aref.valueChanged(1337)
        # echo "Thread aref: ", aref
        # echo "Thread sending: ", res
        agentResults.send(unsafeIsolate(ensureMove res))
        # echo "Thread Done"

      var thread: Thread[WeakRef[SomeAction]]
      createThread(thread, threadTestProc, wa)
      thread.joinThread()
      let resp = agentResults.recv()
      # echo "RESP: ", resp
      emit resp

      check b.value == 1337
      check c.value == 1337

  when true:
    test "threaded connect":
      block:
        var
          a = SomeAction.new()
          b = Counter.new()
        # echo "thread runner!"
        let thread = newSigilThread()
        let bp: AgentProxy[Counter] = b.moveToThread(thread)
        check b.isNil

        connect(a, valueChanged, bp, setValue)
        connect(a, valueChanged, bp, Counter.setValue())
        check not compiles(connect(a, valueChanged, bp, someAction))
      GC_fullCollect()

  when true:
    test "agent connect a->b then moveToThread then destroy proxy":
      # debugPrintQuiet = true
      var
        a = SomeAction(debugName: "A")
      when defined(sigilsDebug):
        a.debugName = "A"
        a.obj.id = 1010

      block:
        var
          b = Counter()
        when defined(sigilsDebug):
          b.debugName = "B"
          b.obj.id = 2020

        brightPrint "thread runner!", &" (th: {getThreadId()})"
        brightPrint "obj a: ", $a.unsafeWeakRef()
        brightPrint "obj b: ", $b.unsafeWeakRef()
        let thread = newSigilThread()
        thread.start()

        connect(a, valueChanged, b, setValueGlobal)
        printConnections(a)
        printConnections(b)

        echo "\n==== moveToThread"
        let bp: AgentProxy[Counter] = b.moveToThread(thread)
        brightPrint "obj bp: ", $bp.unsafeWeakRef()
        printConnections(a)
        printConnections(bp)
        printConnections(bp.proxyTwin[])
        printConnections(bp.remote[])
        let
          subLocalProxy = Subscription(tgt: bp.unsafeWeakRef().asAgent(), slot: setValueGlobal(Counter))
          remoteProxy = bp.proxyTwin
        check a.subcriptionsTable["valueChanged".toSigilName].contains(subLocalProxy)
        check bp.listening.contains(a.unsafeWeakRef().asAgent())
        check bp.subcriptionsTable.len() == 0

        check remoteProxy[].subcriptionsTable.len() == 1
        check remoteProxy[].listening.len() == 1
        check bp[].remote[].subcriptionsTable.len() == 1
        check bp[].remote[].listening.len() == 1

        emit a.valueChanged(568)
        os.sleep(1)
        check globalCounter.load() == 568
      echo "block done"
      # printConnections(a)

      # check a is disconnected
      check not a.hasConnections()
      emit a.valueChanged(111)
      check globalCounter.load() == 568

      for i in 1..10:
        if globalLastInnerCDestroyed.load == 2020: break
        os.sleep(1)
      check globalLastInnerCDestroyed.load == 2020

  when true:
    test "agent connect b->a then moveToThread then destroy proxy":
      debugPrintQuiet = false

      let ct = getCurrentSigilThread()
      var
        a = SomeAction(debugName: "A")
      when defined(sigilsDebug):
        a.debugName = "A"
        a.obj.id = 1010

      block:
        var
          b = Counter()
        when defined(sigilsDebug):
          b.debugName = "B"
          b.obj.id = 2020

        brightPrint "thread runner!", &" (th: {getThreadId()})"
        brightPrint "obj a: ", $a.unsafeWeakRef()
        brightPrint "obj b: ", $b.unsafeWeakRef()
        let thread = newSigilThread()
        when defined(sigilsDebug):
          thread[].debugName = "thread"

        connect(b, updated, a, SomeAction.completed())
        printConnections(a)
        printConnections(b)
        # printConnections(thread[])

        echo "\n==== moveToThread"
        let bp: AgentProxy[Counter] = b.moveToThread(thread)
        brightPrint "obj bp: ", $bp.unsafeWeakRef()
        connect(thread[].agent, started, bp.getRemote()[], ticker)

        printConnections(a)
        printConnections(bp)
        printConnections(bp.proxyTwin[])
        printConnections(bp.getRemote()[])
        # printConnections(thread[])

        let
          subLocalProxy = Subscription(tgt: bp.unsafeWeakRef().asAgent(), slot: setValueGlobal(Counter))
          remoteProxy = bp.proxyTwin
        check a.subcriptionsTable.len() == 0
        check a.listening.len() == 1
        check bp.subcriptionsTable.len() == 1
        check bp.listening.len() == 0

        check remoteProxy[].subcriptionsTable.len() == 1
        check remoteProxy[].listening.len() == 1
        check bp[].remote[].subcriptionsTable.len() == 1
        check bp[].remote[].listening.len() == 2 # listening to thread

        thread.start()

        for i in 1..3:
          if globalLastTicker.load != 3:
            os.sleep(1)
        check globalLastTicker.load == 3
        ct[].poll()
        let polled = ct[].pollAll()
        echo "polled: ", polled
        check a.value == 3
        echo "inner done"
      
      echo "outer done"

  when false:
    test "agent connect then moveToThread and run":
      var
        a = SomeAction.new()

      block:
        echo "sigil object thread connect change"
        var
          b = Counter.new()
          c = SomeAction.new()
        echo "thread runner!", " (th: ", getThreadId(), ")"
        echo "obj a: ", a.getId
        echo "obj b: ", b.getId
        echo "obj c: ", c.getId
        let thread = newSigilThread()
        thread.start()
        startLocalThread()

        connect(a, valueChanged, b, setValue)
        connect(b, updated, c, SomeAction.completed())

        let bp: AgentProxy[Counter] = b.moveToThread(thread)
        echo "obj bp: ", bp.getId()

        emit a.valueChanged(314)
        let ct = getCurrentSigilThread()
        ct[].poll()
        check c.value == 314
      GC_fullCollect()

  # when true:
  when false:
    test "agent move to thread then connect and run":

      var
        a = SomeAction.new()

      let thread = newSigilThread()
      thread.start()
      startLocalThread()

      block:
        var
          b = Counter.new()
        echo "thread runner!", " (th: ", getThreadId(), ")"
        echo "obj a: ", $a.getId()
        echo "obj b: ", $b.getId()

        let bp: AgentProxy[Counter] = b.moveToThread(thread)
        echo "obj bp: ", $bp.getId()
        # echo "obj bp.remote: ", bp.remote[].unsafeWeakRef

        connect(a, valueChanged, bp, setValue)
        connect(bp, updated, a, SomeAction.completed())

        emit a.valueChanged(314)
        # thread.thread.joinThread(500)
        # os.sleep(500)
        let ct = getCurrentSigilThread()
        ct[].poll()
        check a.value == 314
        GC_fullCollect()
      
      # check a.subcriptionsTable.len() == 0
      # check a.listening.len() == 0
      if a.subcriptionsTable.len() > 0:
        echo "a.subcriptionsTable: ", a.subcriptionsTable
      if a.listening.len() > 0:
        echo "a.listening: ", a.listening
      GC_fullCollect()

  when false:
    test "sigil object thread runner multiple emits":
      block:
        # echo "thread runner!", " (main thread:", getThreadId(), ")"
        # echo "obj a: ", a.unsafeWeakRef
        # echo "obj b: ", b.unsafeWeakRef
        let thread = newSigilThread()
        thread.start()
        startLocalThread()
        let ct = getCurrentSigilThread()

        var
          a = SomeAction.new()
        
        block:
          var
            b = Counter.new()

          echo "B: ", b.getId()
          # echo "obj bp: ", bp.unsafeWeakRef
          # echo "obj bp.remote: ", bp.remote[].unsafeWeakRef
          connect(a, valueChanged, b, setValue)
          connect(b, updated, a, SomeAction.completed())

          let bp: AgentProxy[Counter] = b.moveToThread(thread)
          echo "BP: ", bp.getId()

          emit a.valueChanged(89)
          emit a.valueChanged(756809)

          ct[].poll()
          check a.value == 89
        echo "block done"

        let cnt = ct[].pollAll()
        check cnt == 0
        check a.value == 89

        # ct[].poll()
        # check a.value == 756809

        # ct[].poll()
        # check a.value == 628
  when false:
    test "sigil object thread runner multiple emit and listens":
      block:
        var
          a = SomeAction.new()
        
        block:
          var
            b = Counter.new()

          # echo "thread runner!", " (main thread:", getThreadId(), ")"
          # echo "obj a: ", a.unsafeWeakRef
          # echo "obj b: ", b.unsafeWeakRef
          let thread = newSigilThread()
          thread.start()
          startLocalThread()

          let bp: AgentProxy[Counter] = b.moveToThread(thread)
          # echo "obj bp: ", bp.unsafeWeakRef
          # echo "obj bp.remote: ", bp.remote[].unsafeWeakRef
          connect(a, valueChanged, bp, setValue)
          connect(bp, updated, a, SomeAction.completedSum())

          emit a.valueChanged(756809)
          emit a.valueChanged(628)

          # thread.thread.joinThread(500)
          # os.sleep(10)
          let ct = getCurrentSigilThread()
          var cnt = 0
          for i in 1..20:
            cnt.inc(ct[].pollAll())
            if cnt >= 3:
              break
            os.sleep(1)
          echo "polled: ", cnt
          check a.value == 756809 + 628
        GC_fullCollect()
      GC_fullCollect()


  when false:
    test "sigil object thread runner (loop)":
      block:
        block:
          startLocalThread()
          let thread = newSigilThread()
          thread.start()
          echo "thread runner!", " (th: ", getThreadId(), ")"
          let ct = getCurrentSigilThread()
          let polled = ct[].pollAll()
          echo "polled: ", polled
          when defined(extraLoopTests):
            let m = 10
            let n = 200
          elif defined(debug):
            let m = 2
            let n = 2
          else:
            let m = 10
            let n = 10

          for i in 1 .. m:
            var a = SomeAction.new()
            for j in 1 .. n:
              when defined(debug):
                echo "Loop: ", i, ".", j, " (th: ", getThreadId(), ")"
              else:
                if j mod n == 0:
                  echo "Loop: ", i, ".", j, " (th: ", getThreadId(), ")"
              a.value = 0
              var b = Counter.new()
              # echo "B: ", b.getId()

              let bp: AgentProxy[Counter] = b.moveToThread(thread)
              # echo "BP: ", bp.getId()

              connect(a, valueChanged, bp, setValue)
              connect(bp, updated, a, SomeAction.completedSum())

              emit a.valueChanged(314)
              emit a.valueChanged(271)

              var cnt = 0
              for i in 1..20:
                cnt.inc(ct[].pollAll())
                if cnt >= 3:
                  break
                os.sleep(1)
              ct[].pollAll()
              check a.value == 314 + 271
              ct[].pollAll()
            GC_fullCollect()
        GC_fullCollect()
      GC_fullCollect()

  when false:
    test "sigil object one way runner (loop)":
      let ct = getCurrentSigilThread()
      block:
        block:
          startLocalThread()
          let thread = newSigilThread()
          thread.start()
          echo "thread runner!", " (th: ", getThreadId(), ")"
          when defined(debug):
            let m = 10
            let n = 100
          else:
            let m = 100
            let n = 1_000

          for i in 1 .. m:
            var a = SomeAction.new()

            for j in 1 .. n:
              if j mod n == 0:
                echo "Loop: ", i, ".", j, " (th: ", getThreadId(), ")"
              var b = Counter.new()

              let bp: AgentProxy[Counter] = b.moveToThread(thread)

              ct[].pollAll()

              connect(a, valueChanged, bp, setValue)

              emit a.valueChanged(314)

              # os.sleep(100)
              # let ct = getCurrentSigilThread()
              # ct[].poll()
              # check a.value == 314
              # ct[].poll()
              # check a.value == 271
              ct[].pollAll()
            GC_fullCollect()
        GC_fullCollect()
      GC_fullCollect()
