## DNS resolution actor. Move it to a worker scheduler before requesting lookups.

import std/[net, nativesockets]
import ../[actors, agents, core]

type
  DnsResult* = object
    ## Result of one hostname lookup. Addresses are numeric IPv4 or IPv6 strings.
    id*: uint64
    host*: string
    addresses*: seq[string]
    error*: string

  DnsResolver* = ref object of AgentActor
    ## Performs blocking system resolution on its owning worker scheduler.

proc dnsResolved*(resolver: DnsResolver, answer: DnsResult) {.signal.}

proc newDnsResolver*(): DnsResolver =
  ## Create a resolver actor to move onto a worker scheduler.
  DnsResolver()

proc resolveDns*(resolver: DnsResolver, id: uint64, host: string) {.slot.} =
  ## Resolve a hostname. Each request emits one result, including failures.
  var resolved = DnsResult(id: id, host: host)
  try:
    if host.len == 0 or '\0' in host:
      raise newException(ValueError, "DNS hostname must not be empty or contain NUL")
    let addresses = getAddrInfo(host, Port(0), AF_UNSPEC, SOCK_STREAM, IPPROTO_TCP)
    try:
      var current = addresses
      while current != nil:
        let address = getAddrString(current.ai_addr)
        if isIpAddress(address) and address notin resolved.addresses:
          resolved.addresses.add(address)
        current = current.ai_next
    finally:
      freeAddrInfo(addresses)
    if resolved.addresses.len == 0:
      resolved.error = "hostname resolved to no IP addresses"
  except CatchableError as error:
    resolved.error = error.msg
  emit resolver.dnsResolved(resolved)
