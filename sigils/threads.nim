import std/sets
import agents

proc moveToThead*(agent: typeof(Agent()[])) =
  let xid: WeakRef[Agent] = WeakRef[Agent](pt: cast[Agent](addr agent))

  # echo "\ndestroy: agent: ", xid[].debugId, " pt: ", xid.toPtr.repr, " lstCnt: ", xid[].listeners.len(), " subCnt: ", xid[].subscribed.len
  # echo "subscribed: ", xid[].subscribed.toSeq.mapIt(it[].debugId).repr

  # remove myself from agents I'm listening to
  var delSigs: seq[string]
  for obj in agent.subscribed:
    # echo "freeing subscribed: ", obj[].debugId
    delSigs.setLen(0)
    for signal, listenerPairs in obj[].listeners.mpairs():
      var toDel = initOrderedSet[AgentPairing](listenerPairs.len())
      for item in listenerPairs:
        if item.tgt == xid:
          toDel.incl(item)
          # echo "agentRemoved: ", "tgt: ", xid.toPtr.repr, " id: ", agent.debugId, " obj: ", obj[].debugId, " name: ", signal
      for item in toDel:
        listenerPairs.excl(item)
      if listenerPairs.len() == 0:
        delSigs.add(signal)
    for sig in delSigs:
      obj[].listeners.del(sig)
  
  # remove myself from agents listening to me
  for signal, listenerPairs in xid[].listeners.mpairs():
    # echo "freeing signal: ", signal, " listeners: ", listenerPairs
    for listners in listenerPairs:
      # listeners.tgt.
      # echo "\tlisterners: ", listners.tgt
      # echo "\tlisterners:subscribed ", listners.tgt[].subscribed
      listners.tgt[].subscribed.excl(xid)
      # echo "\tlisterners:subscribed ", listners.tgt[].subscribed
