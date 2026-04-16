port module Main exposing (main)

{-| Kafka Orders Example

Demonstrates the basic producer-consumer cycle:

  - createTopic with named topic and partition count
  - send (round-robin) and sendKeyed (deterministic partition routing)
  - consumer joining a consumer group
  - poll returning ConsumerRecords with metadata
  - commit to persist consumer offsets
  - seekToBeginning, seekToEnd, seek for offset management
  - close to leave the consumer group
  - subscribe via Selector for reactive delivery to an actor

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



-- CODEC


encodeOrder : Order -> AppMsg
encodeOrder order =
    LogMsg (String.fromInt order.id ++ ":" ++ order.product ++ ":" ++ order.customerId)


decodeOrder : AppMsg -> Maybe Order
decodeOrder msg =
    case msg of
        LogMsg s ->
            case String.split ":" s of
                [ idStr, product, customerId ] ->
                    String.toInt idStr
                        |> Maybe.map (\id -> { id = id, product = product, customerId = customerId })

                _ ->
                    Nothing

        _ ->
            Nothing



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
createOrdersTopic : Procedure.Procedure Never (Topic.Topic AppMsg Order) Msg
createOrdersTopic =
    Topic.createTopic ctx encodeOrder decodeOrder { name = "orders", partitions = 3 }


{-| Create a consumer in the "order-processors" group
and spawn the OrderProcessor actor with it.
-}
spawnProcessor : Topic.Topic AppMsg Order -> Procedure.Procedure Never (Topic.Consumer AppMsg Order) Msg
spawnProcessor ordersTopic =
    Topic.consumer ctx ordersTopic "order-processors"
        |> Procedure.andThen
            (\c ->
                Core.spawn ctx (OrderProcessor.actor logPort) c
                    |> Procedure.andThen (\_ -> log "OrderProcessor actor spawned")
                    |> Procedure.map (\() -> c)
            )


{-| Send orders: some unkeyed (round-robin partition assignment),
some keyed by customer ID (deterministic partition routing).
-}
sendOrders : Topic.Topic AppMsg Order -> Procedure.Procedure Never () Msg
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


{-| Poll consumer, log each record's metadata, then commit.
-}
pollAndCommit : Topic.Consumer AppMsg Order -> Procedure.Procedure Never () Msg
pollAndCommit c =
    Topic.poll ctx c
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
        |> Procedure.andThen (\() -> Topic.commit ctx c)
        |> Procedure.andThen (\() -> log "Offsets committed")


{-| Demonstrate seek operations: replay from beginning, seek to a specific
partition/offset, and seek to end.
-}
demonstrateSeek : Topic.Consumer AppMsg Order -> Procedure.Procedure Never () Msg
demonstrateSeek c =
    Topic.seekToBeginning ctx c
        |> Procedure.andThen (\() -> log "Seeked to beginning")
        |> Procedure.andThen (\() -> Topic.poll ctx c)
        |> Procedure.andThen
            (\records ->
                log ("Replayed " ++ String.fromInt (List.length records) ++ " records from beginning")
            )
        |> Procedure.andThen (\() -> Topic.seek ctx c 0 1)
        |> Procedure.andThen (\() -> log "Seeked to partition=0, offset=1")
        |> Procedure.andThen (\() -> Topic.poll ctx c)
        |> Procedure.andThen
            (\records ->
                log ("Polled " ++ String.fromInt (List.length records) ++ " records from offset 1")
            )
        |> Procedure.andThen (\() -> Topic.seekToEnd ctx c)
        |> Procedure.andThen (\() -> log "Seeked to end")


initProcedure : Procedure.Procedure Never () Msg
initProcedure =
    log "=== Kafka Orders Example ==="
        |> Procedure.andThen (\() -> createOrdersTopic)
        |> Procedure.andThen
            (\ordersTopic ->
                spawnProcessor ordersTopic
                    |> Procedure.andThen
                        (\c ->
                            sendOrders ordersTopic
                                |> Procedure.andThen (\() -> pollAndCommit c)
                                |> Procedure.andThen (\() -> demonstrateSeek c)
                                |> Procedure.andThen (\() -> Topic.close ctx c)
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
