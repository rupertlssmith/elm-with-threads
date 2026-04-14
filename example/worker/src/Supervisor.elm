module Supervisor exposing (actor)

import Actor.Core exposing (Actor)
import Actor.P2P exposing (Subject)
import Types exposing (AppMsg(..))


actor : (String -> Cmd AppMsg) -> Actor (Subject AppMsg AppMsg) (Subject AppMsg AppMsg) AppMsg
actor log =
    { init = \inbox -> ( inbox, Cmd.none )
    , update =
        \msg model ->
            case msg of
                WorkerReport report ->
                    ( model, log ("Supervisor got report: " ++ report) )

                _ ->
                    ( model, Cmd.none )
    , subscriptions = \_ -> Sub.none
    }
