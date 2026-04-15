module Worker exposing (Model, actor)

import Actor.Channel as Channel
import Actor.Core exposing (Actor)
import Actor.Internal.Runtime exposing (ActorSystem)
import Time
import Types exposing (AppMsg(..))


type alias Model =
    { inbox : Channel.Channel AppMsg Channel.OneToOne AppMsg
    , selector : Channel.Selector AppMsg AppMsg
    , jobCount : Int
    }


actor : (String -> Cmd AppMsg) -> Actor (Channel.Channel AppMsg Channel.OneToOne AppMsg) Model AppMsg
actor log =
    { init = init
    , update = update log
    , subscriptions = subscriptions
    }


init : Channel.Channel AppMsg Channel.OneToOne AppMsg -> ( Model, Cmd AppMsg )
init inbox =
    ( { inbox = inbox
      , selector = Channel.all inbox
      , jobCount = 0
      }
    , Cmd.none
    )


update : (String -> Cmd AppMsg) -> AppMsg -> Model -> ( Model, Cmd AppMsg )
update log msg model =
    case msg of
        WorkerJob n ->
            let
                newCount =
                    model.jobCount + 1
            in
            ( { model | jobCount = newCount }
            , log ("Worker processing job #" ++ String.fromInt n ++ " (total: " ++ String.fromInt newCount ++ ")")
            )

        Heartbeat time ->
            ( model
            , log ("Worker heartbeat at " ++ String.fromInt (Time.posixToMillis time) ++ "ms (jobs done: " ++ String.fromInt model.jobCount ++ ")")
            )

        _ ->
            ( model, Cmd.none )


subscriptions : ActorSystem AppMsg -> Model -> Sub (Maybe AppMsg)
subscriptions system model =
    Sub.batch
        [ Channel.subscribe system model.selector
        , Time.every 2000 Heartbeat |> Sub.map Just
        ]
