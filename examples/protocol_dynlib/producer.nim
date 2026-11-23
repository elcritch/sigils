import sigils/selectors
import ./counterprotocol

type Counter = ref object of DynamicAgent
  value: int

protocol Counting of CounterProtocol:
  method increment(self: Counter, amount: int): int =
    self.value += amount
    self.value

proc newCounter*(): DynamicAgent =
  Counter().withProtocol(Counting)
