## Collection and utility examples adapted from Higher Order Messaging (2005).
## https://scg.unibe.ch/archive/papers/Weih05aHigherOrderMessagingOOPSLA2005.pdf
import std/[strutils, sugar]
import sigils/[hom, selectors]

type
  Text = ref object of DynamicAgent
    value: string

  Employee = ref object of DynamicAgent
    name: Text
    salary: int
    reports: seq[Employee]

  Window = ref object of DynamicAgent
    title: string

  Recorder = ref object of DynamicAgent
    closedWindow: string

protocol TextMessages from Text:
  method appendText(self: Text, suffix: string): string =
    self.value & suffix

  method textEquals(self: Text, expected: string): bool =
    self.value == expected

  method hasPrefix(self: Text, prefix: string): bool =
    self.value.startsWith(prefix)

  method surround(self: Text, prefix: string = "(",
      suffix: string = ")"): string =
    prefix & self.value & suffix

protocol EmployeeMessages from Employee:
  method earnsMoreThan(self: Employee, threshold: int): bool =
    self.salary > threshold

  method employeeName(self: Employee): Text =
    self.name

  method addReport(self: Employee, report: Employee) =
    self.reports.add report

protocol WindowDelegate:
  method windowDidClose(window: Window) {.optional.}

protocol RecordingDelegate of WindowDelegate:
  method windowDidClose(self: Recorder, window: Window) =
    self.closedWindow = window.title

method mayFail(): string {.selector.}

method fail(self: Text): string {.selector.} =
  raise newException(ValueError, self.value)

proc newText(value: string): Text =
  Text(value: value).withProto()

proc logAndIgnore[A, R](
    receiver: DynamicAgent, message: Selector[A, R], args: A,
    log: proc(message: string) {.closure.}
): Opt[R] =
  try:
    var value: R
    if receiver.performLocal(message, args, value):
      result = Opt.some(value)
  except CatchableError as exception:
    log(exception.msg)

when isMainModule:
  let
    john = Employee(name: newText("John"), salary: 1200).withProto()
    jane = Employee(name: newText("Jane"), salary: 1100).withProto()
    mary = Employee(name: newText("Mary"), salary: 900).withProto()
    employees = [john, jane, mary]

  # Sections 2.2 and 4.1. Keep the employees whose salary passes the test.
  doAssert employees.select(earnsMoreThan(), 1000) == @[john, jane]
  doAssert employees.selectSend(earnsMoreThan(1000)) == @[john, jane]

  # Figure 5. Vary the receiver, the argument, or both in lockstep.
  let
    names = ["John", "Mary", "Bob"]
    texts = collect(newSeq):
      for name in names:
        newText(name)
    titles = [newText("Saint "), newText("Ms "), newText("Dr. ")]
  doAssert texts.collect(appendText(), " Doe") ==
    @[Opt.some("John Doe"), Opt.some("Mary Doe"), Opt.some("Bob Doe")]
  doAssert titles[0].collectEach(appendText(), names) ==
    @[Opt.some("Saint John"), Opt.some("Saint Mary"), Opt.some("Saint Bob")]
  doAssert titles.collectEach(appendText(), names) ==
    @[Opt.some("Saint John"), Opt.some("Ms Mary"), Opt.some("Dr. Bob")]

  # Pack multiple arguments for each send into a typed tuple.
  let decorations = [(prefix: "(", suffix: ")"), (prefix: "[", suffix: "]"),
    (prefix: "<", suffix: ">")]
  doAssert texts.collectEach(surround(), decorations) ==
    @[Opt.some("(John)"), Opt.some("[Mary]"), Opt.some("<Bob>")]
  doAssert texts.collectSend(surround(suffix = "]")) ==
    @[Opt.some("(John]"), Opt.some("(Mary]"), Opt.some("(Bob]")]

  # Figure 4. Keep the receiver fixed while passing each of Sally's reports.
  let
    alice = Employee().withProto()
    sally = Employee(reports: @[john, mary]).withProto()
  discard alice.collectEach(addReport(), sally.reports)
  doAssert alice.reports == @[john, mary]

  # Section 4.1. The predicate sends a second message to the name.
  doAssert employees.selectWhere(employeeName(), textEquals("John")) == @[john]
  doAssert employees.selectWhere(employeeName(), hasPrefix(prefix = "J")) ==
    @[john, jane]

  # Section 4.4. An optional delegate send needs only one selector.
  let
    window = Window(title: "Documents")
    recorder = Recorder().withProtocol(RecordingDelegate)
  doAssert recorder.sendLocalIfHandled(windowDidClose(), window)
  doAssert recorder.closedWindow == "Documents"
  doAssert not Recorder().sendLocalIfHandled(windowDidClose(), window)

  # Keep the exception policy at the call site.
  let failing = newText("could not read text")
  discard failing.addMethod(mayFail(), fail)
  var logged: seq[string]
  let reply = failing.logAndIgnore(mayFail(), (), proc(message: string) =
    logged.add message)
  doAssert reply.isNone
  doAssert logged == @["could not read text"]
