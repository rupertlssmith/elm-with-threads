module Supervisor exposing (actor)

import Actor.Core exposing (Actor)
import Actor.P2P exposing (Subject)
import Types exposing (AppMsg(..))


type alias Model =
    Subject AppMsg AppMsg


actor : (String -> Cmd AppMsg) -> Actor (Subject AppMsg AppMsg) Model AppMsg
actor log =
    { init = init
    , update = update log
    , subscriptions = subscriptions
    }


init : Subject AppMsg AppMsg -> ( Model, Cmd AppMsg )
init inbox =
    ( inbox, Cmd.none )


update : (String -> Cmd AppMsg) -> AppMsg -> Model -> ( Model, Cmd AppMsg )
update log msg model =
    case msg of
        WorkerReport report ->
            ( model, log ("Supervisor got report: " ++ report) )

        _ ->
            ( model, Cmd.none )


subscriptions : Model -> Sub AppMsg
subscriptions _ =
    Sub.none
