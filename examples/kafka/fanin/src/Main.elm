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

-}

import Actor.Core as Core
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext)
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


log : String -> Procedure.Procedure Never () Msg
log message =
    Procedure.do (logPort message)



-- INIT PROCEDURES


{-| Create both topics.
-}
createTopics :
    Procedure.Procedure
        Never
        { orders : Topic.Topic AppMsg Order
        , payments : Topic.Topic AppMsg Payment
        }
        Msg
createTopics =
    Topic.createTopic ctx encodeOrder decodeOrder { name = "orders", partitions = 3 }
        |> Procedure.andThen
            (\ordersTopic ->
                Topic.createTopic ctx encodePayment decodePayment { name = "payments", partitions = 2 }
                    |> Procedure.map
                        (\paymentsTopic ->
                            { orders = ordersTopic
                            , payments = paymentsTopic
                            }
                        )
            )


{-| Create consumers for both topics and spawn the EventProcessor with them.
-}
spawnEventProcessor :
    { orders : Topic.Topic AppMsg Order, payments : Topic.Topic AppMsg Payment }
    -> Procedure.Procedure Never EventProcessor.Flags Msg
spawnEventProcessor topics =
    Topic.consumer ctx topics.orders "event-processors"
        |> Procedure.andThen
            (\ordersConsumer ->
                Topic.consumer ctx topics.payments "event-processors"
                    |> Procedure.andThen
                        (\paymentsConsumer ->
                            let
                                flags =
                                    { orders = ordersConsumer
                                    , payments = paymentsConsumer
                                    }
                            in
                            Core.spawn ctx (EventProcessor.actor logPort) flags
                                |> Procedure.andThen (\_ -> log "EventProcessor spawned with orders + payments consumers")
                                |> Procedure.map (\() -> flags)
                        )
            )


{-| Send a mix of orders and payments.

Note: Order #2 ($2.50) is below the $50 filter threshold in the
EventProcessor's Selector, so it will be silently dropped.
-}
sendMessages :
    { orders : Topic.Topic AppMsg Order, payments : Topic.Topic AppMsg Payment }
    -> Procedure.Procedure Never () Msg
sendMessages topics =
    Topic.send ctx topics.orders
        { id = 1, product = "Laptop", amount = 999.99 }
        |> Procedure.andThen
            (\() ->
                Topic.send ctx topics.orders
                    { id = 2, product = "Sticker", amount = 2.50 }
            )
        |> Procedure.andThen
            (\() ->
                Topic.send ctx topics.orders
                    { id = 3, product = "Monitor", amount = 349.00 }
            )
        |> Procedure.andThen
            (\() ->
                Topic.send ctx topics.payments
                    { orderId = 1, amount = 999.99, method = "credit_card" }
            )
        |> Procedure.andThen
            (\() ->
                Topic.send ctx topics.payments
                    { orderId = 3, amount = 349.00, method = "paypal" }
            )
        |> Procedure.andThen
            (\() ->
                log "Sent 3 orders + 2 payments (order #2 at $2.50 will be filtered out)"
            )


initProcedure : Procedure.Procedure Never () Msg
initProcedure =
    log "=== Kafka Fan-In Example ==="
        |> Procedure.andThen (\() -> createTopics)
        |> Procedure.andThen
            (\topics ->
                spawnEventProcessor topics
                    |> Procedure.andThen (\_ -> sendMessages topics)
            )
        |> Procedure.andThen (\() -> log "--- Events arriving via unified Selector subscription ---")
        |> Procedure.andThen (\() -> log "=== Init complete ===")



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
