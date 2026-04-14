# elm-actor-kafka

An Elm actor system library with Kafka-like topic messaging, built on top of [brian-watkins/elm-procedure](https://package.elm-lang.org/packages/brian-watkins/elm-procedure/latest/).

## Overview

This library provides an actor model for Elm applications with two messaging patterns:

1. **Point-to-Point (P2P)** — Direct actor-to-actor messaging via subjects and selectors
2. **Topics** — Kafka-style partitioned log messaging with consumer groups, offsets, and commit semantics

## Architecture

```
┌──────────────────────────────────────────────┐
│                Public API                     │
│  Actor.Core  Actor.P2P  Actor.Topic           │
│  Actor.Advanced.P2P                           │
├──────────────────────────────────────────────┤
│              Internal Runtime                 │
│  Runtime · Mailbox · Selector · TopicStore    │
│  Types                                        │
├──────────────────────────────────────────────┤
│           brian-watkins/elm-procedure          │
│         (lifecycle, async, channels)          │
└──────────────────────────────────────────────┘
```

## Modules

### Actor.Core
Spawn and kill actors. Each actor gets a `ProcessId` (self) injected at spawn time.

```elm
spawn : Actor model appMsg -> ActorSystem appMsg -> ( ActorSystem appMsg, ProcessId )
kill : ProcessId -> ActorSystem appMsg -> ActorSystem appMsg
```

### Actor.P2P
Point-to-point messaging between actors via subjects and selectors.

```elm
subject : ProcessId -> Subject appMsg
send : Subject appMsg -> appMsg -> ActorSystem appMsg -> ActorSystem appMsg
select : Selector appMsg -> ActorSystem appMsg -> ( ActorSystem appMsg, Maybe appMsg )
subscribe : Selector appMsg -> ProcessId -> ActorSystem appMsg -> ActorSystem appMsg
```

### Actor.Topic
Kafka-style partitioned log topics with consumer groups.

```elm
topic : String -> Int -> ActorSystem appMsg -> ( ActorSystem appMsg, Topic )
publish : Topic -> appMsg -> ActorSystem appMsg -> ActorSystem appMsg
poll : Consumer -> ActorSystem appMsg -> ( ActorSystem appMsg, List appMsg )
commit : Consumer -> ActorSystem appMsg -> ActorSystem appMsg
```

### Actor.Advanced.P2P
Enriched P2P messaging with metadata envelopes (sender, timestamp, key).

## Getting Started

### Prerequisites
- [Elm](https://elm-lang.org/) 0.19.1
- [Node.js](https://nodejs.org/) >= 18
- npm

### Build & Run

```bash
npm install
npm run build
npm start
```

This compiles the Elm code, bundles the TypeScript entrypoint with esbuild, and runs the example worker.

### Example

The included `src/Main.elm` demonstrates a supervisor actor that spawns a worker, sends P2P messages, and publishes/consumes from a topic. The TypeScript entrypoint (`ts/index.ts`) initialises the Elm app and wires the ports.

## Project Structure

```
elm-actor-kafka/
├── elm.json
├── package.json
├── esbuild.config.mjs
├── src/
│   ├── Main.elm                 # Example worker
│   └── Actor/
│       ├── Core.elm             # Spawn/kill actors
│       ├── P2P.elm              # Point-to-point messaging
│       ├── Topic.elm            # Kafka-style topics
│       ├── Advanced/
│       │   └── P2P.elm          # Enriched P2P with metadata
│       └── Internal/
│           ├── Types.elm        # Core type aliases
│           ├── Mailbox.elm      # FIFO message queue
│           ├── Selector.elm     # Selector DSL & matching
│           ├── TopicStore.elm   # Partitioned log storage
│           └── Runtime.elm      # Actor system runtime
├── ts/
│   └── index.ts                 # Node.js entrypoint
└── build/                       # Output directory
```

## Design Decisions

- **Single `appMsg` type**: All actors share one message type — standard Elm Architecture, no existential types needed.
- **Closure-based process entries**: Each process captures its actor model internally, enabling heterogeneous actor storage.
- **Synchronous in-update delivery**: Actor-to-actor messages are delivered synchronously within `update`; elm-procedure handles async operations.
- **In-memory topic storage**: Partitions use `Array` for O(1) offset reads. Suitable for in-process use; not persistent.

## License

MIT
