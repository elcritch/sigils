import std/unittest
import sigils/collections

type Task = object
  id: int
  title: string

proc taskId(task: Task): int = task.id

suite "standalone collections import":
  test "construct, observe, and publish using the documented imports":
    let tasks = newCollectionSigil(@[Task(id: 1, title: "Draft")], taskId)
    let order = tasks.order
    let first: CollectionValue[Opt[Task]] = tasks.item(1)
    tasks[1] = Task(id: 1, title: "Ready")
    check tasks.get(1).title == "Ready"
    check first{}.get.title == "Ready"
    check first{} == Opt.some(tasks.get(1))
    check order{} == @[1]

  test "get and indexed lookup raise KeyError for a missing key":
    let tasks = newCollectionSigil(@[Task(id: 1, title: "Draft")], taskId)
    expect KeyError:
      discard tasks.get(2)
    expect KeyError:
      discard tasks[2]
    check tasks.item(2){}.isNone
    check tasks.item(2){} == Opt.none(Task)
