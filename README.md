# elm-actor-kafka

An Elm actor system library with channel-based messaging and Kafka-style
topics, built on top of
[brian-watkins/elm-procedure](https://package.elm-lang.org/packages/brian-watkins/elm-procedure/latest/).

## Overview

The library provides an actor model for Elm applications with three
messaging patterns:

1. **Channels** — unified point-to-point and broadcast messaging with a
   typed payload codec (`Actor.Channel`).
2. **Topics** — Kafka-style partitioned logs with consumer groups, keyed
   partitioning, commit/seek semantics, and selector-based fan-in
   (`Actor.Topic`).
3. **Advanced P2P** — point-to-point messaging with metadata envelopes
   (`Actor.Advanced.P2P`).

All operations are expressed as `Actor.Task` values so the underlying
`SystemContext` is threaded implicitly rather than being passed through
every call site. Message delivery uses a JS port "port-bounce": each
`send`/`publish` fires an outgoing port which JS echoes straight back,
waking any Elm `Sub` that is watching for it.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                      Public API                      │
│  Actor.Core  Actor.Task                              │
│  Actor.Channel  Actor.Topic  Actor.Advanced.P2P      │
├──────────────────────────────────────────────────────┤
│                    Internal Runtime                  │
│  Runtime · Mailbox · Selector · TopicStore · Types   │
├──────────────────────────────────────────────────────┤
│                   Actor.Ports (JS)                   │
│           notifyP2PSend  ⇄  onP2PSend echo           │
├──────────────────────────────────────────────────────┤
│              brian-watkins/elm-procedure             │
│           (lifecycle, async, continuations)          │
└──────────────────────────────────────────────────────┘
```

## Modules

### `Actor.Core`
Lifecycle primitives for actors.

```elm
type alias Actor flags model msg =
    { init : flags -> ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : ActorSystem msg -> model -> Sub (Maybe msg)
    }

spawn : Actor flags model msg -> flags -> Task msg parentMsg err (Process msg)
self  : Task msg parentMsg err (Process msg)
kill  : Process msg -> Task msg parentMsg err ()
```

### `Actor.Task`
Opaque task monad that threads the runtime's `SystemContext` implicitly.

```elm
succeed : a -> Task msg parentMsg err a
fail    : err -> Task msg parentMsg err a
map, mapError, andThen, andMap, sequence

fromProcedure : Procedure err a parentMsg -> Task msg parentMsg err a
toProcedure   : SystemContext msg parentMsg -> Task ... -> Procedure ...

run     : SystemContext ... -> tagger -> (a -> parentMsg) -> Task ... Never a -> Cmd parentMsg
attempt : SystemContext ... -> tagger -> (Result err a -> parentMsg) -> Task ... -> Cmd parentMsg
```

Application code typically aliases the shape once:

```elm
type alias Task a = Task.Task AppMsg Msg Never a
```

### `Actor.Channel`
Unified one-to-one and broadcast channels. The phantom type
(`OneToOne` / `Broadcast`) distinguishes delivery semantics. Each channel
carries an encoder `(a -> msg)` and decoder `(msg -> Maybe a)` so
payloads are typed.

```elm
oneToOne  : (a -> msg) -> (msg -> Maybe a) -> Task ... (Channel msg OneToOne a)
broadcast : (a -> msg) -> (msg -> Maybe a) -> Task ... (Channel msg Broadcast a)

send    : Channel msg OneToOne a  -> a -> Task ... ()
publish : Channel msg Broadcast a -> a -> Task ... ()

selector    : Selector msg msg
all         : Channel msg c a -> Selector msg a
selectMap   : Channel msg c a -> (a -> msg) -> Selector msg b -> Selector msg b
map, filter, orElse, withTimeout

select    : Selector msg a -> Task ... (Maybe a)
subscribe : ActorSystem msg -> Selector msg a -> Sub (Maybe a)
```

### `Actor.Topic`
Kafka-style partitioned log topics with consumer groups.

```elm
createTopic : (a -> msg) -> (msg -> Maybe a)
           -> { name : String, partitions : Int }
           -> Task ... (Topic msg a)

send      : Topic msg a -> a -> Task ... ()
sendKeyed : Topic msg a -> Key -> a -> Task ... ()

consumer : Topic msg a -> Group -> Task ... (Consumer msg a)
close    : Consumer msg a -> Task ... ()

poll    : Consumer msg a -> Task ... (List (ConsumerRecord a))
commit  : Consumer msg a -> Task ... ()

seekToBeginning, seekToEnd : Consumer msg a -> Task ... ()
seek : Consumer msg a -> Partition -> Offset -> Task ... ()

selector, all, selectMap, map, filter
subscribe : ActorSystem msg -> Selector msg a -> Sub (Maybe a)
```

`ConsumerRecord a` carries `{ value, key, partition, offset }`.
`sendKeyed` uses the key to pin a logical stream to a single partition.

### `Actor.Advanced.P2P`
Point-to-point messaging with a metadata envelope
(`{ key, possibleDuplicate, sequence }`). Same selector/subscribe
pattern as `Actor.Channel`, with `selectWithMeta` / `subscribeWithMeta`
variants that expose `( Meta, msg )` to the selector.

### `Actor.Ports`
The JS-facing port pair used by the runtime:

```elm
port notifyP2PSend : { subjectId : Int, messageId : Int } -> Cmd msg
port onP2PSend    : ({ subjectId : Int, messageId : Int } -> msg) -> Sub msg
```

The JS host must subscribe to `notifyP2PSend` and immediately echo the
same payload back through `onP2PSend`. Each example ships a minimal
`index.ts` that does exactly this.

## Project Structure

```
elm-actor-kafka/
├── elm.json                   # library manifest (source-directories: src)
├── package.json               # root dev deps (esbuild, typescript)
├── src/Actor/
│   ├── Core.elm               # spawn / self / kill
│   ├── Task.elm               # Task monad over SystemContext
│   ├── Channel.elm            # unified OneToOne / Broadcast
│   ├── Topic.elm              # Kafka-style topics
│   ├── Advanced/P2P.elm       # enriched P2P
│   ├── Ports.elm              # notifyP2PSend / onP2PSend
│   └── Internal/              # Runtime, Mailbox, Selector, TopicStore, Types
├── model/                     # API stubs describing the target platform
└── examples/
    ├── worker/                # supervisor + worker over Channels
    └── kafka/
        ├── orders/            # producer / consumer / poll / commit / seek
        └── fanin/             # multi-topic Selector fan-in
```

## Running the Examples

### Prerequisites

- [Elm](https://elm-lang.org/) 0.19.1 on `PATH`
- [Node.js](https://nodejs.org/) >= 18
- `esbuild` (pulled in as a root dev dependency)

From the repository root, install the JS dev dependencies once — every
example resolves `esbuild` from the root `node_modules`:

```bash
npm install
```

Each example then has its own `run.sh` that compiles Elm, bundles the
TypeScript entrypoint, and runs the resulting script under Node. The
process exits after ~3 seconds — long enough to show init,
port-bounce delivery, and a few heartbeat ticks.

### Worker example

Supervisor actor spawns a Worker actor. Jobs are sent over a OneToOne
channel; the Worker reports back; system events are published on a
Broadcast channel.

```bash
cd examples/worker
bash run.sh
```

### Kafka orders example

Creates a 3-partition `orders` topic and an `OrderProcessor` consumer
in the `order-processors` group. Demonstrates round-robin `send` and
keyed `sendKeyed`, `poll`, `commit`, and the full `seek` /
`seekToBeginning` / `seekToEnd` API.

```bash
cd examples/kafka/orders
bash run.sh
```

### Kafka fan-in example

Two topics (`orders`, `payments`) with different payload types, fanned
into a single `EventProcessor` actor by building one `Selector` that
`selectMap`s both consumers into a common `AppMsg`, with a `filter` to
drop small orders.

```bash
cd examples/kafka/fanin
bash run.sh
```

## Design Notes

- **Single `appMsg` type.** All actors share one message type — standard
  Elm Architecture, no existential types. Channels and topics carry a
  codec (`a -> msg` / `msg -> Maybe a`) so producers and consumers work
  against typed payloads while the runtime stays monomorphic.
- **`Task` threads the `SystemContext` implicitly.** Call sites read as
  `Channel.send ch x |> Task.andThen ...` instead of passing an explicit
  system context into every operation. The context is supplied once at
  the top level via `Task.run` / `Task.attempt`.
- **Port-bounce delivery.** Sends store the message and fire
  `notifyP2PSend`. The JS host echoes that back through `onP2PSend`,
  which wakes the Elm `Sub` installed by `Channel.subscribe` /
  `Topic.subscribe`. Actor subscriptions are collected by the runtime
  via `Runtime.collectSubscriptions` in the top-level `subscriptions`
  function.
- **In-memory topic storage.** Partitions use `Array` for O(1) offset
  reads. Suitable for in-process use; not persistent.

## License

MIT
