import sigils/selectors

protocol CounterProtocol:
  method increment*(amount: int): int
