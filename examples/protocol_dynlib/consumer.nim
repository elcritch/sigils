import sigils/selectors
import ./counterprotocol
import ./build/counter_abi

let a = newCounter()
let b = newCounter()
doAssert a.hasAdopted(CounterProtocol)
doAssert a.increment(2) == 2
doAssert a.increment(3) == 5
doAssert b.increment(7) == 7
