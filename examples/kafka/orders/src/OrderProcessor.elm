module OrderProcessor exposing (Model, actor)

{-| Actor that consumes orders from a Kafka topic.

Receives a Consumer as its init flags, builds a Selector with `Topic.all`,
and subscribes to it. Each incoming ConsumerRecord carries the order value
along with partition, offset, and key metadata.
-}

import Actor.Core exposing (Actor)
import Actor.Internal.Runtime exposing (ActorSystem)
import Actor.Topic as Topic
import Types exposing (AppMsg(..), Order)


type alias Model =
    { consumer : Topic.Consumer AppMsg Order
    , selector : Topic.Selector AppMsg (Topic.ConsumerRecord Order)
    , processed : Int
    }


actor : (String -> Cmd AppMsg) -> Actor (Topic.Consumer AppMsg Order) Model AppMsg
actor log =
    { init = init
    , update = update log
    , subscriptions = subscriptions
    }


init : Topic.Consumer AppMsg Order -> ( Model, Cmd AppMsg )
init consumer =
    ( { consumer = consumer
      , selector = Topic.all consumer
      , processed = 0
      }
    , Cmd.none
    )


update : (String -> Cmd AppMsg) -> AppMsg -> Model -> ( Model, Cmd AppMsg )
update log msg model =
    case msg of
        OrderReceived record ->
            ( { model | processed = model.processed + 1 }
            , log
                ("Order #"
                    ++ String.fromInt record.value.id
                    ++ " ["
                    ++ record.value.product
                    ++ "] partition="
                    ++ String.fromInt record.partition
                    ++ " offset="
                    ++ String.fromInt record.offset
                    ++ " key="
                    ++ Maybe.withDefault "none" record.key
                )
            )

        _ ->
            ( model, Cmd.none )


subscriptions : ActorSystem AppMsg -> Model -> Sub (Maybe AppMsg)
subscriptions system model =
    Topic.subscribe system model.selector
        |> Sub.map (Maybe.map OrderReceived)
