port module Main exposing (main)

{-| Kafka Orders Example

Demonstrates the basic producer-consumer cycle:

  - createTopic with named topic and partition count
  - send (round-robin) and sendKeyed (deterministic partition routing)
  - consumer joining a consumer group
  - poll via Selector (Topic.all) returning ConsumerRecords with metadata
  - commit to persist consumer offsets
  - seekToBeginning, seekToEnd, seek for offset management
  - close to leave the consumer group

-}

import Actor.Core as Core
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext)
import Actor.Topic as Topic
import OrderProcessor
import Platform
import Procedure
import Procedure.Program
import Time
import Types exposing (AppMsg(..), Order)



-- PORTS


port logPort : String -> Cmd msg


port exitPort : () -> Cmd msg



-- MODEL


type alias Model =
    { system : ActorSystem AppMsg
    , procModel : Procedure.Program.Model Msg
    }



-- MSG


type Msg
    = ProcMsg (Procedure.Program.Msg Msg)
    | RunSystemOp (ActorSystem AppMsg -> ( ActorSystem AppMsg, Cmd Msg ))
    | DeliverToActor (Core.Process AppMsg) AppMsg
    | InitDone
    | Tick Time.Posix
    | NoOp



-- SYSTEM CONTEXT


ctx : SystemContext AppMsg Msg
ctx =
    { runOp = RunSystemOp
    , mapAppCmd = Cmd.map (\_ -> NoOp)
    }



-- HELPERS


log : String -> Procedure.Procedure Never () Msg
log message =
    Procedure.do (logPort message)



-- INIT PROCEDURES


{-| Create the orders topic with 3 partitions.
-}
createOrdersTopic : Procedure.Procedure Never (Topic.Topic Order) Msg
createOrdersTopic =
    Topic.createTopic ctx { name = "orders", partitions = 3 }


{-| Create a consumer in the "order-processors" group
and spawn the OrderProcessor actor with it.
-}
spawnProcessor : Topic.Topic Order -> Procedure.Procedure Never (Topic.Consumer Order) Msg
spawnProcessor ordersTopic =
    Topic.consumer ctx ordersTopic "order-processors"
        |> Procedure.andThen
            (\consumer ->
                Core.spawn ctx (OrderProcessor.actor logPort) consumer
                    |> Procedure.andThen (\_ -> log "OrderProcessor actor spawned")
                    |> Procedure.map (\() -> consumer)
            )


{-| Send orders: some unkeyed (round-robin partition assignment),
some keyed by customer ID (deterministic partition routing).
-}
sendOrders : Topic.Topic Order -> Procedure.Procedure Never () Msg
sendOrders ordersTopic =
    Topic.send ctx ordersTopic
        { id = 1, product = "Widget", customerId = "C100" }
        |> Procedure.andThen
            (\() ->
                Topic.send ctx ordersTopic
                    { id = 2, product = "Gadget", customerId = "C200" }
            )
        |> Procedure.andThen
            (\() ->
                Topic.sendKeyed ctx ordersTopic "C100"
                    { id = 3, product = "Doohickey", customerId = "C100" }
            )
        |> Procedure.andThen
            (\() ->
                Topic.sendKeyed ctx ordersTopic "C200"
                    { id = 4, product = "Thingamajig", customerId = "C200" }
            )
        |> Procedure.andThen (\() -> log "Sent 4 orders (2 unkeyed, 2 keyed by customer)")


{-| Poll consumer via its selector, log each record's metadata, then commit.
-}
pollAndCommit : Topic.Consumer Order -> Procedure.Procedure Never () Msg
pollAndCommit consumer =
    Topic.poll ctx (Topic.all consumer)
        |> Procedure.andThen
            (\records ->
                let
                    formatRecord r =
                        "  p=" ++ String.fromInt r.partition
                            ++ " o=" ++ String.fromInt r.offset
                            ++ " key=" ++ Maybe.withDefault "-" r.key
                            ++ " -> #" ++ String.fromInt r.value.id
                            ++ " " ++ r.value.product
                in
                log
                    ("Polled "
                        ++ String.fromInt (List.length records)
                        ++ " records:\n"
                        ++ String.join "\n" (List.map formatRecord records)
                    )
            )
        |> Procedure.andThen (\() -> Topic.commit ctx consumer)
        |> Procedure.andThen (\() -> log "Offsets committed")


{-| Demonstrate seek operations: replay from beginning, seek to a specific
partition/offset, and seek to end.
-}
demonstrateSeek : Topic.Consumer Order -> Procedure.Procedure Never () Msg
demonstrateSeek consumer =
    -- Replay everything from the start
    Topic.seekToBeginning ctx consumer
        |> Procedure.andThen (\() -> log "Seeked to beginning")
        |> Procedure.andThen (\() -> Topic.poll ctx (Topic.all consumer))
        |> Procedure.andThen
            (\records ->
                log ("Replayed " ++ String.fromInt (List.length records) ++ " records from beginning")
            )
        -- Seek to a specific offset on partition 0
        |> Procedure.andThen (\() -> Topic.seek ctx consumer 0 2)
        |> Procedure.andThen (\() -> log "Seeked to partition=0, offset=2")
        |> Procedure.andThen (\() -> Topic.poll ctx (Topic.all consumer))
        |> Procedure.andThen
            (\records ->
                log ("Polled " ++ String.fromInt (List.length records) ++ " records from offset 2")
            )
        -- Jump to the end (latest)
        |> Procedure.andThen (\() -> Topic.seekToEnd ctx consumer)
        |> Procedure.andThen (\() -> log "Seeked to end")


initProcedure : Procedure.Procedure Never () Msg
initProcedure =
    log "=== Kafka Orders Example ==="
        |> Procedure.andThen (\() -> createOrdersTopic)
        |> Procedure.andThen
            (\ordersTopic ->
                spawnProcessor ordersTopic
                    |> Procedure.andThen
                        (\consumer ->
                            sendOrders ordersTopic
                                |> Procedure.andThen (\() -> pollAndCommit consumer)
                                |> Procedure.andThen (\() -> demonstrateSeek consumer)
                                |> Procedure.andThen (\() -> Topic.close ctx consumer)
                                |> Procedure.andThen (\() -> log "Consumer closed, left group")
                        )
            )
        |> Procedure.andThen (\() -> log "=== Done ===")



-- MAIN


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { system = Runtime.initSystem
      , procModel = Procedure.Program.init
      }
    , Procedure.run ProcMsg (\() -> InitDone) initProcedure
    )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ProcMsg procMsg ->
            Procedure.Program.update procMsg model.procModel
                |> Tuple.mapFirst (\pm -> { model | procModel = pm })

        RunSystemOp op ->
            let
                ( newSystem, cmd ) =
                    op model.system
            in
            ( { model | system = newSystem }, cmd )

        DeliverToActor process appMsg ->
            let
                ( newSystem, actorCmd ) =
                    Runtime.deliver process appMsg model.system
            in
            ( { model | system = newSystem }, Cmd.map (\_ -> NoOp) actorCmd )

        InitDone ->
            ( model, Cmd.none )

        Tick time ->
            ( { model | system = Runtime.updateTime time model.system }
            , Cmd.none
            )

        NoOp ->
            ( model, Cmd.none )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Procedure.Program.subscriptions model.procModel
        , Time.every 1000 Tick
        , Runtime.collectSubscriptions DeliverToActor NoOp model.system
        ]
