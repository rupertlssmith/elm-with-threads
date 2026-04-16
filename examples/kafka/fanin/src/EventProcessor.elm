module EventProcessor exposing (Flags, Model, actor)

{-| Actor that consumes from two Kafka topics through a single Selector.

Demonstrates:

  - selector: start with an empty Selector
  - selectMap: bridge each Consumer into the Selector with type translation
      (ConsumerRecord Order -> Event, ConsumerRecord Payment -> Event)
  - filter: drop low-value orders (amount <= 50)
  - map: wrap the domain Event in AppMsg for the actor system
  - subscribe: reactive consumption through the unified Selector

The key insight: publishers to the "orders" topic only know about Order,
publishers to "payments" only know about Payment. This actor consumes both
through a single typed Selector without either publisher knowing about Event
or AppMsg. This is the same decoupling that Channel.Selector provides.

-}

import Actor.Core exposing (Actor)
import Actor.Internal.Runtime exposing (ActorSystem)
import Actor.Topic as Topic
import Types exposing (AppMsg(..), Event(..), Order, Payment)


type alias Flags =
    { orders : Topic.Consumer Order
    , payments : Topic.Consumer Payment
    }


type alias Model =
    { orders : Topic.Consumer Order
    , payments : Topic.Consumer Payment
    , selector : Topic.Selector Event AppMsg
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
                -- Bridge the orders consumer: ConsumerRecord Order -> Event
                |> Topic.selectMap flags.orders
                    (\r -> OrderPlaced r.value)
                -- Bridge the payments consumer: ConsumerRecord Payment -> Event
                |> Topic.selectMap flags.payments
                    (\r -> PaymentReceived r.value)
                -- Filter: only keep orders above $50
                |> Topic.filter
                    (\event ->
                        case event of
                            OrderPlaced order ->
                                order.amount > 50

                            _ ->
                                True
                    )
                -- Map: wrap Event in AppMsg (Selector Event Event -> Selector Event AppMsg)
                |> Topic.map EventOccurred
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
        EventOccurred event ->
            let
                description =
                    case event of
                        OrderPlaced order ->
                            "Order #"
                                ++ String.fromInt order.id
                                ++ " ["
                                ++ order.product
                                ++ "] $"
                                ++ String.fromFloat order.amount

                        PaymentReceived payment ->
                            "Payment for order #"
                                ++ String.fromInt payment.orderId
                                ++ " $"
                                ++ String.fromFloat payment.amount
                                ++ " via "
                                ++ payment.method
            in
            ( { model | eventCount = model.eventCount + 1 }
            , log ("Event " ++ String.fromInt (model.eventCount + 1) ++ ": " ++ description)
            )

        _ ->
            ( model, Cmd.none )


subscriptions : ActorSystem AppMsg -> Model -> Sub (Maybe AppMsg)
subscriptions _ model =
    Topic.subscribe model.selector Just
