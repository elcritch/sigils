import std/[times, unittest]

import sigils

type
  Callback = proc(value: int): int {.closure.}

  CallbackPayload = object
    callback: Callback

  TimezonePayload = object
    timezone: Timezone

  DateTimePayload = object
    dateTime: DateTime

  NestedDateTimePayload = object
    payload: DateTimePayload

  TemporalKind = enum
    date
    timestamp

  TemporalPayload = object
    case kind: TemporalKind
    of date:
      dateTime: DateTime
    of timestamp:
      time: Time

  ObjectValueKind = enum
    empty
    text
    temporal
    callback

  ObjectValuePayload = object
    case kind: ObjectValueKind
    of empty:
      discard
    of text:
      textValue: string
    of temporal:
      temporalValue: TemporalPayload
    of callback:
      callbackValue: CallbackPayload

  ModelPayload = object
    value: ObjectValuePayload
    children: seq[ModelPayload]

protocol PayloadProvider:
  method modelAtIndex(index: int): ModelPayload {.optional.}

protocol PayloadProviderImplementation of PayloadProvider:
  method modelAtIndex(self: DynamicAgent, index: int): ModelPayload =
    ModelPayload(
      value: ObjectValuePayload(kind: text, textValue: $index),
    )

suite "protocol payloads":
  test "local payloads do not require JSON serialization":
    let callback: Callback = proc(value: int): int =
      value + 1
    let params = rpcPack(CallbackPayload(callback: callback))
    var payload: CallbackPayload

    rpcUnpack(payload, params)

    check payload.callback(41) == 42

  test "local payloads accept standard-library types with proc fields":
    let
      dateTime = now()
      timezoneParams = rpcPack(TimezonePayload(timezone: utc()))
      dateTimeParams = rpcPack(DateTimePayload(dateTime: dateTime))
      nestedParams = rpcPack(
        NestedDateTimePayload(payload: DateTimePayload(dateTime: dateTime))
      )
      modelParams = rpcPack(ModelPayload(
        value: ObjectValuePayload(
          kind: temporal,
          temporalValue: TemporalPayload(kind: date, dateTime: dateTime)
        )
      ))
    var
      timezonePayload: TimezonePayload
      dateTimePayload: DateTimePayload
      nestedPayload: NestedDateTimePayload
      modelPayload: ModelPayload

    rpcUnpack(timezonePayload, timezoneParams)
    rpcUnpack(dateTimePayload, dateTimeParams)
    rpcUnpack(nestedPayload, nestedParams)
    rpcUnpack(modelPayload, modelParams)

    check timezonePayload.timezone.name == "Etc/UTC"
    check dateTimePayload.dateTime == dateTime
    check nestedPayload.payload.dateTime == dateTime
    check modelPayload.value.temporalValue.dateTime == dateTime

  test "local selectors do not instantiate remote codecs":
    let provider = DynamicAgent().withProtocol(PayloadProviderImplementation)

    let model = provider.modelAtIndex(42)

    check model.value.textValue == "42"
