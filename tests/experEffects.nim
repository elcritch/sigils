type OpKinds* {.pure.} = enum
  opNull
  opNoResume #// never resumes
  opTail #// only uses `resume` in tail-call position
  opScoped #// only uses `resume` inside the handler
  opGeneral #// `resume` is a first-class value

# const char*  effect_exn[3]    = {"exn","exn_raise",NULL};
# const optag  optag_exn_raise  = { effect_exn, 1 };

type
  Resume* = object
  OpTag* = object
    name: cstring
    op: cstring

  Continuation* = proc(r: ptr Resume, local, value: pointer): pointer
  Operation* = object
    kind: OpKinds
    tag: OpTag
    fn: Continuation

  FooObj* = object
    value*: int

  Foo* = ref FooObj

  HandlerDef = object

  Handler* = object
    entry: pointer #// used to jump back to a handler
    hdef: ptr HandlerDef #// operation definitions
    arg: pointer #// the operation argument is passed here
    arg_op: ptr Operation #// the yielded operation is passed here
    arg_resume: ptr Resume #// the resumption function
    stackbase: pointer #// stack frame address of the handler function

proc opTag(name, op: static string): OpTag =
  OpTag(name: name, op: op)

proc handle_exn_raise*(r: ptr Resume, local, arg: pointer): pointer =
  echo("exception raised: ", $cast[cstring](arg))
  return nil

const exn_ops =
  [Operation(kind: opNoResume, tag: opTag("exn", "raise"), fn: handle_exn_raise)]

# const exn_def: handlerdef = { EFFECT(exn), NULL, NULL, NULL, _exn_ops };
# proc my_exn_handle(action: proc (arg: pointer): pointer, arg: pointer): pointer =
#   return handle(addr exn_def, nil, action, arg)
type
  Cont* = object
  Allocation*[T] = object

proc new*[T](obj: var T) {.tags: [Allocation[T]].} =
  discard

proc newFoo*(value: int): Foo =
  result.new()
  result.value = value

template withEffects(blk, handles: untyped) =
  block:
    blk

proc main*() =
  # normal allocation
  let f = newFoo(23)
  echo "f: ", f.value, " at 0x", cast[pointer](f).repr

  withEffects:
    let f = newFoo(23)
    echo "f: ", f.value, " at 0x", cast[pointer](f).repr
  except Allocation[T] as (r: ptr Cont, local, arg: var T):
    echo "allocation: "

main()
