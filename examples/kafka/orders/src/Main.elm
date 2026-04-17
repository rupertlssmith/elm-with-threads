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

Operations are composed with `Actor.Task`, which hides the `SystemContext`
from every call site.

-}

import Actor.Core as Core
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext)
import Actor.Task as Task
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



-- APP-LEVEL TASK ALIAS


type alias Task a =
    Task.Task AppMsg Msg Never a



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


log : String -> Task ()
log message =
    Task.fromProcedure (Procedure.do (logPort message))



-- INIT TASKS


createOrdersTopic : Task (Topic.Topic AppMsg Order)
createOrdersTopic =
    Topic.createTopic encodeOrder decodeOrder { name = "orders", partitions = 3 }


spawnProcessor : Topic.Topic AppMsg Order -> Task (Topic.Consumer AppMsg Order)
spawnProcessor ordersTopic =
    Topic.consumer ordersTopic "order-processors"
        |> Task.andThen
            (\c ->
                Core.spawn (OrderProcessor.actor logPort) c
                    |> Task.andThen (\_ -> log "OrderProcessor actor spawned")
                    |> Task.map (\() -> c)
            )


sendOrders : Topic.Topic AppMsg Order -> Task ()
sendOrders ordersTopic =
    Topic.send ordersTopic
        { id = 1, product = "Widget", customerId = "C100" }
        |> Task.andThen
            (\() ->
                Topic.send ordersTopic
                    { id = 2, product = "Gadget", customerId = "C200" }
            )
        |> Task.andThen
            (\() ->
                Topic.sendKeyed ordersTopic "C100"
                    { id = 3, product = "Doohickey", customerId = "C100" }
            )
        |> Task.andThen
            (\() ->
                Topic.sendKeyed ordersTopic "C200"
                    { id = 4, product = "Thingamajig", customerId = "C200" }
            )
        |> Task.andThen (\() -> log "Sent 4 orders (2 unkeyed, 2 keyed by customer)")


pollAndCommit : Topic.Consumer AppMsg Order -> Task ()
pollAndCommit c =
    Topic.poll c
        |> Task.andThen
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
        |> Task.andThen (\() -> Topic.commit c)
        |> Task.andThen (\() -> log "Offsets committed")


demonstrateSeek : Topic.Consumer AppMsg Order -> Task ()
demonstrateSeek c =
    let
        logRecords label records =
            let
                formatRecord r =
                    "  p=" ++ String.fromInt r.partition
                        ++ " o=" ++ String.fromInt r.offset
                        ++ " key=" ++ Maybe.withDefault "-" r.key
                        ++ " -> #" ++ String.fromInt r.value.id
                        ++ " " ++ r.value.product
            in
            log
                (label
                    ++ " "
                    ++ String.fromInt (List.length records)
                    ++ " records:\n"
                    ++ String.join "\n" (List.map formatRecord records)
                )
    in
    Topic.seekToBeginning c
        |> Task.andThen (\() -> log "Seeked to beginning")
        |> Task.andThen (\() -> Topic.poll c)
        |> Task.andThen (\records -> logRecords "Replayed" records)
        |> Task.andThen (\() -> Topic.seek c 0 1)
        |> Task.andThen (\() -> log "Seeked to partition=0, offset=1")
        |> Task.andThen (\() -> Topic.poll c)
        |> Task.andThen (\records -> logRecords "From offset 1:" records)
        |> Task.andThen (\() -> Topic.seekToEnd c)
        |> Task.andThen (\() -> log "Seeked to end")


initTask : Task ()
initTask =
    log "=== Kafka Orders Example ==="
        |> Task.andThen (\() -> createOrdersTopic)
        |> Task.andThen
            (\ordersTopic ->
                spawnProcessor ordersTopic
                    |> Task.andThen
                        (\c ->
                            sendOrders ordersTopic
                                |> Task.andThen (\() -> pollAndCommit c)
                                |> Task.andThen (\() -> demonstrateSeek c)
                                |> Task.andThen (\() -> Topic.close c)
                                |> Task.andThen (\() -> log "Consumer closed, left group")
                        )
            )
        |> Task.andThen (\() -> log "=== Done ===")



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
    , Task.run ctx ProcMsg (\() -> InitDone) initTask
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
