import std/[net, unittest]
import sigils
import sigils/net/resolver

type Observer = ref object of Agent
  count: int
  answer: DnsResult

proc requested(self: Observer, id: uint64, host: string) {.signal.}
proc onResolved(self: Observer, answer: DnsResult) {.slot.} =
  self.count.inc()
  self.answer = answer

suite "DNS resolver":
  test "returns system lookup results on the originating scheduler":
    startLocalThreadDefault()
    let home = getCurrentSigilThread()
    let worker = newSigilThread()
    worker.start()
    block:
      var resolver = newDnsResolver()
      let proxy = resolver.moveToThread(worker)
      let observer = Observer()
      connectThreaded(observer, requested, proxy, resolveDns)
      connectThreaded(proxy, dnsResolved, observer, Observer.onResolved())
      emit observer.requested(42, "localhost")
      for i in 0..<500:
        if observer.count > 0: break
        discard home.poll()
      check observer.count == 1
      check observer.answer.id == 42
      check observer.answer.error == ""
      check observer.answer.addresses.len > 0
      for address in observer.answer.addresses:
        check isIpAddress(address)
      emit observer.requested(43, "")
      for i in 0..<500:
        if observer.count > 1: break
        discard home.poll()
      check observer.count == 2
      check observer.answer.id == 43
      check observer.answer.error.len > 0
    worker.setRunning(false)
    worker.join()
