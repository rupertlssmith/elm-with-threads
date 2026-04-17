port module Main exposing (main)

{-| Kafka Fan-In Example

Demonstrates multi-topic consumption with Selectors:

  - Two topics with different value types (Order, Payment)
  - selector: empty Selector as starting point
  - selectMap: bridge each Consumer into a unified AppMsg type
  - filter: drop events that don't meet criteria
  - subscribe: reactive consumption from the combined Selector

The EventProcessor actor consumes from both topics through one Selector.
Publishers to each topic are decoupled — they only know their own value
type, not the consumer's message types.

Operations are composed with `Actor.Task`, which hides the `SystemContext`
from every call site.

-}

import Actor.Core as Core
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext)
import Actor.Task as Task
import Actor.Topic as Topic
import EventProcessor
import Platform
import Procedure
import Procedure.Program
import Time
import Types exposing (AppMsg(..), Order, Payment)



-- PORTS


port logPort : String -> Cmd msg


port exitPort : () -> Cmd msg



-- APP-LEVEL TASK ALIAS


type alias Task a =
    Task.Task AppMsg Msg Never a



-- CODECS


encodeOrder : Order -> AppMsg
encodeOrder order =
    LogMsg ("O:" ++ String.fromInt order.id ++ ":" ++ order.product ++ ":" ++ String.fromFloat order.amount)


decodeOrder : AppMsg -> Maybe Order
decodeOrder msg =
    case msg of
        LogMsg s ->
            case String.split ":" s of
                "O" :: idStr :: product :: amountStr :: [] ->
                    Maybe.map2
                        (\id amount -> { id = id, product = product, amount = amount })
                        (String.toInt idStr)
                        (String.toFloat amountStr)

                _ ->
                    Nothing

        _ ->
            Nothing


encodePayment : Payment -> AppMsg
encodePayment payment =
    LogMsg ("P:" ++ String.fromInt payment.orderId ++ ":" ++ String.fromFloat payment.amount ++ ":" ++ payment.method)


decodePayment : AppMsg -> Maybe Payment
decodePayment msg =
    case msg of
        LogMsg s ->
            case String.split ":" s of
                "P" :: orderIdStr :: amountStr :: method :: [] ->
                    Maybe.map2
                        (\orderId amount -> { orderId = orderId, amount = amount, method = method })
                        (String.toInt orderIdStr)
                        (String.toFloat amountStr)

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


createTopics :
    Task { orders : Topic.Topic AppMsg Order, payments : Topic.Topic AppMsg Payment }
createTopics =
    Topic.createTopic encodeOrder decodeOrder { name = "orders", partitions = 3 }
        |> Task.andThen
            (\ordersTopic ->
                Topic.createTopic encodePayment decodePayment { name = "payments", partitions = 2 }
                    |> Task.map
                        (\paymentsTopic ->
                            { orders = ordersTopic
                            , payments = paymentsTopic
                            }
                        )
            )


spawnEventProcessor :
    { orders : Topic.Topic AppMsg Order, payments : Topic.Topic AppMsg Payment }
    -> Task EventProcessor.Flags
spawnEventProcessor topics =
    Topic.consumer topics.orders "event-processors"
        |> Task.andThen
            (\ordersConsumer ->
                Topic.consumer topics.payments "event-processors"
                    |> Task.andThen
                        (\paymentsConsumer ->
                            let
                                flags =
                                    { orders = ordersConsumer
                                    , payments = paymentsConsumer
                                    }
                            in
                            Core.spawn (EventProcessor.actor logPort) flags
                                |> Task.andThen (\_ -> log "EventProcessor spawned with orders + payments consumers")
                                |> Task.map (\() -> flags)
                        )
            )


sendMessages :
    { orders : Topic.Topic AppMsg Order, payments : Topic.Topic AppMsg Payment }
    -> Task ()
sendMessages topics =
    Topic.send topics.orders
        { id = 1, product = "Laptop", amount = 999.99 }
        |> Task.andThen
            (\() ->
                Topic.send topics.orders
                    { id = 2, product = "Sticker", amount = 2.50 }
            )
        |> Task.andThen
            (\() ->
                Topic.send topics.orders
                    { id = 3, product = "Monitor", amount = 349.00 }
            )
        |> Task.andThen
            (\() ->
                Topic.send topics.payments
                    { orderId = 1, amount = 999.99, method = "credit_card" }
            )
        |> Task.andThen
            (\() ->
                Topic.send topics.payments
                    { orderId = 3, amount = 349.00, method = "paypal" }
            )
        |> Task.andThen
            (\() ->
                log "Sent 3 orders + 2 payments (order #2 at $2.50 will be filtered out)"
            )


initTask : Task ()
initTask =
    log "=== Kafka Fan-In Example ==="
        |> Task.andThen (\() -> createTopics)
        |> Task.andThen
            (\topics ->
                spawnEventProcessor topics
                    |> Task.andThen (\_ -> sendMessages topics)
            )
        |> Task.andThen (\() -> log "--- Events arriving via unified Selector subscription ---")
        |> Task.andThen (\() -> log "=== Init complete ===")



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
