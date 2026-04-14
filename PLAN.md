# Elm-Actor-Kafka Implementation Plan

## Context

Building a greenfield Elm actor system library with Kafka-like topics on top of `brian-watkins/elm-procedure`. The project directory is empty. The design doc specifies public APIs for Actor.Core, Actor.P2P, Actor.Advanced.P2P, and Actor.Topic, plus an internal runtime, example worker, TypeScript entrypoint, and build setup.

**Key adaptation**: The design doc references `Runner.State`/`Runner.step` which don't exist in elm-procedure 1.1.1. The actual API provides `Procedure.Program.Model/update/subscriptions` and `Procedure.Channel`. Actor-to-actor messaging will be synchronous within `update`; elm-procedure is used for lifecycle management and async operations (timeouts, ports).

---

## 1. High-level Architecture

Four public module groups:

1. **Actor.Core** — lifecycle: `Process`, `Actor`, `spawn/self/kill`.
2. **Actor.P2P** — point-to-point messaging: `Subject`, `Selector`, keyed send, selectors, `subscribe`.
3. **Actor.Advanced.P2P** — same shapes but with metadata (key, possibleDuplicate, etc.).
4. **Actor.Topic** — Kafka-like durable topics with partitions, offsets, consumer groups.

The whole thing:

- Implemented on top of `brian-watkins/elm-procedure` (hereafter "elm-procedure").
- Run as a `Platform.worker` in Elm.
- Started by a Node/TypeScript `index.ts`.
- Built with elm + esbuild.

**Core idea**: The "actor system" is a *library + runtime* layered inside a single Elm worker program. Each actor process is one elm-procedure instance. The runtime:

- Registers processes in a table, with their elm-procedure runner state.
- Maintains mailboxes per process.
- Creates Subjects and Topics as entries in shared maps.
- Implements `send`, `select`, `subscribeGroup`, etc., by mutating those tables and stepping procedures.

The external APIs (Actor.*, Topic) are *facades* that call into this runtime via a central "procedure runner + actor system state" inside the worker.

---

## 2. Public APIs

### 2.1 `Actor.Core`

```elm
module Actor.Core exposing
    ( Process
    , Actor
    , spawn
    , self
    , kill
    )

type Process msg
    = Process Int
    -- Int = internal process id. Opaque to users.

type alias Actor flags model msg =
    { init : flags -> ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : model -> Sub msg
    }

spawn :
    Actor flags model msg
    -> flags
    -> Task x (Process msg)

self :
    Task x (Process msg)

kill :
    Process msg
    -> Task x ()
```

Usage: from inside your worker's `init`/`update`, you call `spawn` etc. At implementation time, these functions delegate into the "actor system" described in section 3.

### 2.2 `Actor.P2P` — normal P2P messaging

```elm
module Actor.P2P exposing
    ( Key
    , Subject
    , Selector
    , subject
    , send
    , sendKeyed
    , selector
    , selectMap
    , map
    , filter
    , orElse
    , withTimeout
    , select
    , subscribe
    )

type alias Key = String

type Subject a
    = Subject Int
    -- Int = internal subject id

type Selector msg result
    = Selector Int
    -- Int = internal selector id, or an index into a reified AST table.

subject : Task x (Subject a)

send : Subject a -> a -> Task x ()

sendKeyed : Subject a -> Key -> a -> Task x ()

selector : Selector msg msg

selectMap : Subject a -> (a -> msg) -> Selector msg result -> Selector msg result

map : (result -> result2) -> Selector msg result -> Selector msg result2

filter : (result -> Bool) -> Selector msg result -> Selector msg result

orElse : Selector msg result -> Selector msg result -> Selector msg result

withTimeout : Time -> result -> Selector msg result -> Selector msg result

select : Selector msg result -> Task x result

subscribe : Selector msg result -> (result -> parentMsg) -> Sub parentMsg
```

Implementation detail: `Selector` is not really just `Int`; internally a `SelectorAst` structure keyed by this id is maintained. See section 3.2.

### 2.3 `Actor.Advanced.P2P` — metadata (keys, duplicates, sequences)

```elm
module Actor.Advanced.P2P exposing
    ( Key
    , Meta
    , Envelope
    , Subject
    , Selector
    , subject
    , send
    , sendKeyed
    , resendAsPossibleDuplicate
    , sendWithPartitionKey
    , selector
    , selectMap
    , map
    , filter
    , orElse
    , withTimeout
    , select
    , subscribe
    , selectWithMeta
    , subscribeWithMeta
    )

type alias Key = String

type alias Meta =
    { key : Maybe Key
    , possibleDuplicate : Bool
    , sequence : Maybe Int
    }

type alias Envelope a =
    { meta : Meta
    , payload : a
    }

type Subject a
    = Subject Int

type Selector msg result
    = Selector Int

subject : Task x (Subject a)

send : Subject a -> a -> Task x ()

sendKeyed : Subject a -> Key -> a -> Task x ()

resendAsPossibleDuplicate : Subject a -> Key -> a -> Task x ()

sendWithPartitionKey : (a -> Key) -> Subject a -> a -> Task x ()

selector : Selector msg msg

selectMap : Subject a -> (Envelope a -> msg) -> Selector msg result -> Selector msg result

map : (result -> result2) -> Selector msg result -> Selector msg result2

filter : (result -> Bool) -> Selector msg result -> Selector msg result

orElse : Selector msg result -> Selector msg result -> Selector msg result

withTimeout : Time -> result -> Selector msg result -> Selector msg result

select : Selector msg result -> Task x result

subscribe : Selector msg result -> (result -> parentMsg) -> Sub parentMsg

selectWithMeta : Selector ( Meta, msg ) result -> Task x result

subscribeWithMeta : Selector ( Meta, msg ) result -> (result -> parentMsg) -> Sub parentMsg
```

Implemented by layering metadata on top of the same underlying runtime that `Actor.P2P` uses.

### 2.4 `Actor.Topic` — Kafka-style durable topics (normal layer)

```elm
module Actor.Topic exposing
    ( Key
    , Group
    , Partition
    , Offset
    , Topic
    , Consumer
    , topic
    , publish
    , publishKeyed
    , publishWithPartitionKey
    , consumer
    , subscribeGroup
    , seekToBeginning
    , seekToEnd
    , seekToOffset
    )

type alias Key = String
type alias Group = String
type alias Partition = Int
type alias Offset = Int

type Topic a
    = Topic Int

type Consumer a
    = Consumer Int

topic : { partitions : Int } -> Task x (Topic a)

publish : Topic a -> a -> Task x ()

publishKeyed : Topic a -> Key -> a -> Task x ()

publishWithPartitionKey : (a -> Key) -> Topic a -> a -> Task x ()

consumer : Topic a -> Group -> Task x (Consumer a)

subscribeGroup : Topic a -> Group -> (a -> parentMsg) -> Sub parentMsg

seekToBeginning : Consumer a -> Task x ()

seekToEnd : Consumer a -> Task x ()

seekToOffset : Consumer a -> Partition -> Offset -> Task x ()
```

`Actor.Advanced.Topic` can be added later mirroring the Advanced.P2P envelope/meta pattern.

---

## 3. Internal Design on top of elm-procedure

### 3.1 Global `ActorSystem` model

A dedicated **internal module** (`Actor.Internal.Runtime`) owns the global state:

```elm
type alias ProcessId = Int
type alias SubjectId = Int
type alias SelectorId = Int
type alias TopicId = Int

-- How one process is represented internally
type alias ProcessEntry appMsg =
    { id : ProcessId
    , mailbox : Mailbox appMsg
    , handleMessage : appMsg -> ActorSystem appMsg -> ( ActorSystem appMsg, Cmd appMsg )
    -- closure captures actor model internally
    }

type alias SubjectEntry =
    { owner : ProcessId
    }

type alias ActorSystem appMsg =
    { nextProcessId : ProcessId
    , nextSubjectId : SubjectId
    , nextSelectorId : SelectorId
    , nextTopicId : TopicId
    , processes : Dict ProcessId (ProcessEntry appMsg)
    , subjects : Dict SubjectId SubjectEntry
    , selectors : Dict SelectorId (SelectorEntry appMsg)
    , topics : Dict TopicId (TopicEntry appMsg)
    , currentTime : Time.Posix
    }
```

**Key points**:
- `ActorSystem` lives *inside the worker's main model*.
- All public APIs (`Actor.Core.spawn`, `Actor.P2P.send`, etc.) are pure functions that operate on `ActorSystem`.
- ProcessEntry uses closure-based `handleMessage` to capture actor model internally, avoiding existential type issues.

### 3.2 SelectorAst DSL and evaluator

```elm
type SelectorAst appMsg
    = SelectFromSubject SubjectId (appMsg -> Maybe appMsg)
    | SelectMap (appMsg -> appMsg) (SelectorAst appMsg)
    | SelectFilter (appMsg -> Bool) (SelectorAst appMsg)
    | SelectOrElse (SelectorAst appMsg) (SelectorAst appMsg)
    | SelectWithTimeout Float appMsg (SelectorAst appMsg)
    | SelectEmpty

type alias SelectorEntry appMsg =
    { id : SelectorId
    , ast : SelectorAst appMsg
    , owner : ProcessId
    }

matchSelector :
    SelectorAst appMsg
    -> appMsg
    -> SubjectId
    -> Time.Posix
    -> Maybe appMsg
```

The `matchSelector` function evaluates the AST against an incoming message and its source subject, returning `Just result` on match or `Nothing` to skip.

### 3.3 TopicStore

```elm
type alias TopicEntry appMsg =
    { id : TopicId
    , numPartitions : Int
    , partitions : Dict Int (Array appMsg)
    , consumerGroups : Dict String (ConsumerGroupState)
    }

type alias ConsumerGroupState =
    { offsets : Dict Int Int  -- partition -> committed offset
    , currentOffsets : Dict Int Int  -- partition -> current read offset
    }
```

- Partitions use `Array` for O(1) offset reads.
- Consumer groups track committed and current offsets per partition.
- `publish` appends to a partition (round-robin or key-hashed).
- `poll` reads from current offset to end, advancing current offset.
- `commit` saves current offset as committed offset.
- `seek` resets current offset.

### 3.4 Integrating elm-procedure

elm-procedure provides:
- `Procedure.Program.Model` type for managing async operations
- `Procedure.Program.update` and `Procedure.Program.subscriptions`
- `Procedure.Channel` for async communication

The pattern:
- `Procedure.Program.Model` lives inside `ActorSystem` for managing async operations (timeouts, port responses).
- Actor-to-actor messaging is synchronous within `update` (direct function calls on `ActorSystem`).
- elm-procedure is used for lifecycle management and truly async operations.

### 3.5 Stepping the system

The worker's `Model` includes:

```elm
type alias Model =
    { actorSystem : ActorSystem AppMsg
    }
```

In the worker's `update`, after handling external events:

```elm
update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ActorMsg actorMsg ->
            let
                ( newSystem, cmd ) =
                    Runtime.deliverMessage actorMsg model.actorSystem
            in
            ( { model | actorSystem = newSystem }, cmd )

        Tick time ->
            ( { model | actorSystem = Runtime.updateTime time model.actorSystem }
            , Cmd.none
            )
```

`deliverMessage`:
- Finds the target process by looking up subject -> owner mapping.
- Calls the process's `handleMessage` closure.
- The closure updates the actor's internal model and may produce commands.
- Commands may trigger further message deliveries (synchronous within update).

---

## 4. Worked Example: Platform.worker main

### 4.1 Example architecture

- Main Worker process is the "supervisor."
- It spawns a child worker process that:
  - Listens on a `Subject Int` for jobs.
  - Reports completion via a `Subject Report` owned by the supervisor (P2P).
- Supervisor subscribes to a selector to receive `Report`s as Elm messages.
- A topic is created to demonstrate publish/consume.

### 4.2 `Main.elm` (sketch)

```elm
module Main exposing (main)

import Actor.Core as Core
import Actor.P2P as P2P
import Actor.Topic as Topic
import Actor.Internal.Runtime as Runtime

type AppMsg
    = WorkerJob Int
    | WorkerReport String
    | TopicEvent String
    | SupervisorInit
    | SupervisorTick

type alias Model =
    { system : Runtime.ActorSystem AppMsg
    , log : List String
    }

type Msg
    = Init
    | ActorMsg AppMsg
    | Tick Time.Posix
    | LogPort String

main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }

init : () -> ( Model, Cmd Msg )
init _ =
    let
        system0 = Runtime.initSystem
        -- spawn supervisor, which spawns worker
        ( system1, supervisorPid ) = Core.spawn supervisorActor () system0
        -- create a topic
        ( system2, eventTopic ) = Topic.createTopic "events" 3 system1
        -- publish to topic
        system3 = Topic.publish eventTopic (TopicEvent "hello") system2
    in
    ( { system = system3, log = [ "System initialized" ] }
    , Cmd.none
    )
```

### 4.3 TypeScript entrypoint (`ts/index.ts`)

```ts
// @ts-ignore
import { Elm } from "../build/elm.js";

function main() {
  const app = Elm.Main.init({ flags: null });

  // Wire ports if needed:
  // app.ports.logPort.subscribe((msg: string) => {
  //   console.log("[Elm]", msg);
  // });

  console.log("elm-actor-kafka started");
}

main();
```

---

## 5. Build System

### 5.1 Project structure

```
elm-actor-kafka/
├── elm.json
├── package.json
├── esbuild.config.mjs
├── src/
│   ├── Main.elm
│   └── Actor/
│       ├── Core.elm
│       ├── P2P.elm
│       ├── Topic.elm
│       ├── Advanced/
│       │   └── P2P.elm
│       └── Internal/
│           ├── Types.elm
│           ├── Mailbox.elm
│           ├── Selector.elm
│           ├── TopicStore.elm
│           └── Runtime.elm
├── ts/
│   └── index.ts
└── build/
    ├── elm.js
    └── index.js
```

### 5.2 `package.json`

```json
{
  "name": "elm-actor-kafka",
  "scripts": {
    "build:elm": "elm make src/Main.elm --output=build/elm.js",
    "build:ts": "node esbuild.config.mjs",
    "build": "npm run build:elm && npm run build:ts",
    "start": "node build/index.js"
  },
  "devDependencies": {
    "esbuild": "^0.20.0",
    "typescript": "^5.4.0"
  }
}
```

### 5.3 `esbuild.config.mjs`

```js
import esbuild from "esbuild";

await esbuild.build({
  entryPoints: ["ts/index.ts"],
  outfile: "build/index.js",
  bundle: true,
  platform: "node",
  target: ["node18"],
  sourcemap: true,
});
```

### 5.4 Build & Run

```bash
npm install
npm run build
npm start
```

1. Compiles Elm to `build/elm.js`.
2. Bundles `ts/index.ts` into `build/index.js`.
3. Runs `node build/index.js`, which starts `Elm.Main` as a worker.

---

## 6. Implementation Phases

### Phase 1: Project Scaffolding
- `elm.json` — application type, depends on `brian-watkins/elm-procedure` 1.1.1, `elm/core`, `elm/json`, `elm/time`
- `package.json` — scripts for elm make + esbuild build pipeline
- `esbuild.config.mjs` — bundle ts/index.ts for Node
- Directory structure: `src/Actor/Internal/`, `src/Actor/Advanced/`, `ts/`

### Phase 2: Internal Runtime Core
- **`src/Actor/Internal/Types.elm`** — ProcessId, SubjectId, SelectorId, TopicId, Key, Offset, PartitionIndex
- **`src/Actor/Internal/Mailbox.elm`** — FIFO queue (enqueue, dequeue, isEmpty)
- **`src/Actor/Internal/Selector.elm`** — SelectorAst DSL + matchSelector evaluator
- **`src/Actor/Internal/TopicStore.elm`** — Partition logs, consumer groups, publish/poll/seek/commit
- **`src/Actor/Internal/Runtime.elm`** — ActorSystem type, ProcessEntry (closure-based), initSystem, spawnProcess, killProcess, sendToSubject, registerSelector, stepSystem, createTopic, publishToTopic, consumer operations

### Phase 3: Actor.Core Facade
- **`src/Actor/Core.elm`** — Process, Actor types; spawn, kill as pure functions on ActorSystem; self injected at spawn time

### Phase 4: Actor.P2P Facade
- **`src/Actor/P2P.elm`** — Subject, Selector, Key; subject/send/sendKeyed; selector combinators (selectMap/map/filter/orElse/withTimeout); select (one-shot) and subscribe (continuous)

### Phase 5: Actor.Advanced.P2P Facade
- **`src/Actor/Advanced/P2P.elm`** — Meta, Envelope types; mirrors P2P API with metadata enrichment

### Phase 6: Actor.Topic Facade
- **`src/Actor/Topic.elm`** — Topic, Consumer, Partition, Offset; topic/publish/publishKeyed; consumer/subscribeGroup/poll/commit/seek

### Phase 7: Example Worker + TypeScript
- **`src/Main.elm`** — Platform.worker with supervisor spawning a worker actor, P2P subjects, topic usage, port wiring
- **`ts/index.ts`** — Node entrypoint calling Elm.Main.init, wiring ports

### Phase 8: Build & Run
- `npm install && npm run build && npm start`

---

## 7. Key Design Decisions

- **Single `appMsg` type**: All actors share one message type — standard Elm Architecture pattern, no existential types needed.
- **Closure-based process entries**: Each process captures its actor model internally via a `handleMessage` closure, enabling heterogeneous actor storage in a homogeneous `Dict`.
- **Synchronous in-update delivery**: Actor-to-actor messages are delivered synchronously within `update`; elm-procedure handles async operations (timeouts, ports).
- **`ActorSystem` stores `currentTime : Time.Posix`**: Updated by a time subscription for timestamps in selectors and metadata.
- **`Procedure.Program.Model` lives inside ActorSystem**: For async operations managed by elm-procedure.
- **In-memory topic storage**: Partitions use `Array` for O(1) offset reads. Suitable for in-process use; not persistent.

---

## 8. Verification

1. `elm make src/Main.elm --output=build/elm.js` compiles without errors
2. `npm run build` succeeds (elm + esbuild)
3. `node build/index.js` starts the worker and logs supervisor/worker activity
