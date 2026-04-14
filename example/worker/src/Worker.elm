module Worker exposing (Model, actor)

import Actor.Core exposing (Actor)
import Actor.P2P exposing (Subject)
import Time
import Types exposing (AppMsg(..))


type alias Model =
    { inbox : Subject AppMsg AppMsg
    , jobCount : Int
    }


actor : (String -> Cmd AppMsg) -> Actor (Subject AppMsg AppMsg) Model AppMsg
actor log =
    { init = init
    , update = update log
    , subscriptions = subscriptions
    }


init : Subject AppMsg AppMsg -> ( Model, Cmd AppMsg )
init inbox =
    ( { inbox = inbox, jobCount = 0 }, Cmd.none )


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


subscriptions : Model -> Sub AppMsg
subscriptions _ =
    Time.every 2000 Heartbeat
