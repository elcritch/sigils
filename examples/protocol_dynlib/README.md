# A Sigils protocol implemented by a dynamic library

The host imports the shared counter protocol and asks the library for a
`DynamicAgent`. Calling `counter.increment(3)` in the host dispatches to the
method installed by the library on that instance. The concrete counter type
and its mutable state live in the producer.

[Protocol](counterprotocol.nim) · [Producer](producer.nim) · [Consumer](consumer.nim)

Binny exports the factory and imports the existing `DynamicAgent` type from
`sigils/selectors` in its generated bindings. Each additional selector can live
in the shared protocol and use ordinary Sigils dispatch through the same
factory. The two configuration entries are in [native_dynlib.json](native_dynlib.json).

## Run

Use Nim 2.4.2 with its companion `nifler` and `nifmake`, the Sigils Atlas
dependencies, and a Binny checkout containing the enum case binding fix
(commit `d3f5a0a` on `fix/native-record-selectors`). From this directory, with
`BINNY_PATH` set to the absolute path of that checkout:

```sh
eval "$(grabnim use 2.4.2)"
nim --path:"$BINNY_PATH" testDynlib
```

The task builds the library, generates bindings, then compiles and runs the
consumer as a separate executable. It checks adoption, repeated sends on one
counter, and independent state on a second counter.

Build both sides from the same Sigils and protocol sources with matching Nim
and ABI settings. The example uses ARC and `-d:useMalloc` on both sides and
keeps the library loaded for the lifetime of its agents. Selector handlers in
this example return normally. Binny's exception bridge covers its generated
factory call, while later selector sends invoke the installed Sigils callback
directly.
