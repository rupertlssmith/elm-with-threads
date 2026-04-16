module EventProcessor exposing (Flags, Model, actor)

{-| Actor that consumes from two Kafka topics through a single Selector.

Demonstrates:

  - selector: start with an empty Selector
  - selectMap: bridge each Consumer into the Selector with type translation
      (ConsumerRecord Order -> AppMsg, ConsumerRecord Payment -> AppMsg)
  - filter: drop low-value orders (amount <= 50)
  - subscribe: reactive consumption through the unified Selector

The key insight: publishers to the "orders" topic only know about Order,
publishers to "payments" only know about Payment. This actor consumes both
through a single typed Selector without either publisher knowing about
the other's message type.

-}

import Actor.Core exposing (Actor)
import Actor.Internal.Runtime exposing (ActorSystem)
import Actor.Topic as Topic
import Types exposing (AppMsg(..), Order, Payment)


type alias Flags =
    { orders : Topic.Consumer AppMsg Order
    , payments : Topic.Consumer AppMsg Payment
    }


type alias Model =
    { orders : Topic.Consumer AppMsg Order
    , payments : Topic.Consumer AppMsg Payment
    , selector : Topic.Selector AppMsg AppMsg
    , eventCount : Int
    }


actor : (String -> Cmd AppMsg) -> Actor Flags Model AppMsg
actor log =
    { init = init
    , update = update log
    , subscriptions = subscriptions
    }


init : Flags -> ( Model, Cmd AppMsg )
init flags =
    let
        sel =
            Topic.selector
                -- Bridge the orders consumer: ConsumerRecord Order -> AppMsg
                |> Topic.selectMap flags.orders
                    (\r -> OrderPlaced r.value)
                -- Bridge the payments consumer: ConsumerRecord Payment -> AppMsg
                |> Topic.selectMap flags.payments
                    (\r -> PaymentReceived r.value)
                -- Filter: only keep orders above $50
                |> Topic.filter
                    (\appMsg ->
                        case appMsg of
                            OrderPlaced order ->
                                order.amount > 50

                            _ ->
                                True
                    )
    in
    ( { orders = flags.orders
      , payments = flags.payments
      , selector = sel
      , eventCount = 0
      }
    , Cmd.none
    )


update : (String -> Cmd AppMsg) -> AppMsg -> Model -> ( Model, Cmd AppMsg )
update log msg model =
    case msg of
        OrderPlaced order ->
            ( { model | eventCount = model.eventCount + 1 }
            , log
                ("Event "
                    ++ String.fromInt (model.eventCount + 1)
                    ++ ": Order #"
                    ++ String.fromInt order.id
                    ++ " ["
                    ++ order.product
                    ++ "] $"
                    ++ String.fromFloat order.amount
                )
            )

        PaymentReceived payment ->
            ( { model | eventCount = model.eventCount + 1 }
            , log
                ("Event "
                    ++ String.fromInt (model.eventCount + 1)
                    ++ ": Payment for order #"
                    ++ String.fromInt payment.orderId
                    ++ " $"
                    ++ String.fromFloat payment.amount
                    ++ " via "
                    ++ payment.method
                )
            )

        _ ->
            ( model, Cmd.none )


subscriptions : ActorSystem AppMsg -> Model -> Sub (Maybe AppMsg)
subscriptions system model =
    Topic.subscribe system model.selector
