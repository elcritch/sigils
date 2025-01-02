import std/isolation
import std/unittest
import std/os
import std/sequtils

import sigils
import sigils/threads

type
  SomeAction* = ref object of Agent
    value: int
    obj: InnerA

  Counter* = ref object of Agent
    value: int
    obj: InnerC

  InnerA = object
  InnerC = object

proc `=destroy`*(obj: InnerA) = 
  # echo "destroyed InnerA!"
  discard

proc `=destroy`*(obj: InnerC) = 
  # echo "destroyed InnerC!"
  discard

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

var globalCounter = 0

proc setValueGlobal*(self: Counter, value: int) {.slot.} =
  echo "setValueGlobal! ", value, " id: ", self.getId().int, " (th: ", getThreadId(), ")"
  if self.value != value:
    self.value = value
  globalCounter = value

proc completed*(self: SomeAction, final: int) {.slot.} =
  # echo "Action done! final: ", final, " id: ", self.getId().int, " (th: ", getThreadId(), ")"
  self.value = final

proc value*(self: Counter): int =
  self.value

suite "threaded agent slots":

  when false:
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

  when false:
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
    test "agent connect single then moveToThread then destroy proxy":
      let ct = getCurrentSigilThread()
      var
        a = SomeAction(debugName: "A")
      when defined(sigilsDebug):
        a.debugName = "A"

      block:
        var
          b = Counter()
        when defined(sigilsDebug):
          b.debugName = "B"

        brightPrint "thread runner!", &" (th: {getThreadId()})"
        brightPrint "obj a: ", $a.unsafeWeakRef()
        brightPrint "obj b: ", $b.unsafeWeakRef()
        let thread = newSigilThread()
        thread.start()

        connect(a, valueChanged, b, setValueGlobal)
        printConnections(a)

        echo ""
        let bp: AgentProxy[Counter] = b.moveToThread(thread)
        brightPrint "obj bp: ", $bp.unsafeWeakRef()
        printConnections(a)
        echo ""
        printConnections(bp)

        emit a.valueChanged(568)
      echo "block done"
      os.sleep(10)
      check globalCounter == 568

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
          let bp: AgentProxy[Counter] = b.moveToThread(thread)
          echo "BP: ", bp.getId()
          # echo "obj bp: ", bp.unsafeWeakRef
          # echo "obj bp.remote: ", bp.remote[].unsafeWeakRef
          connect(a, valueChanged, bp, setValue)
          connect(bp, updated, a, SomeAction.completed())

          emit a.valueChanged(89)
          emit a.valueChanged(756809)

          ct[].poll()
          check a.value == 89
        echo "block done"

        ct[].poll()
        check a.value == 628

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
          connect(bp, updated, a, SomeAction.completed())

          emit a.valueChanged(756809)
          emit a.valueChanged(628)

          # thread.thread.joinThread(500)
          let ct = getCurrentSigilThread()
          ct[].poll()
          check a.value == 756809
          ct[].poll()
          check a.value == 628
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
          when defined(debug):
            let m = 2
            let n = 2
          else:
            let m = 10
            let n = 100

          for i in 1 .. m:
            var a = SomeAction.new()
            for j in 1 .. n:
              # if j mod n == 0:
              echo "Loop: ", i, ".", j, " (th: ", getThreadId(), ")"
              var b = Counter.new()
              echo "B: ", b.getId()

              let bp: AgentProxy[Counter] = b.moveToThread(thread)
              echo "BP: ", bp.getId()

              connect(a, valueChanged, bp, setValue)
              connect(bp, updated, a, SomeAction.completed())

              emit a.valueChanged(314)
              emit a.valueChanged(271)

              ct[].poll()
              check a.value == 314
              ct[].poll()
              check a.value == 271
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
