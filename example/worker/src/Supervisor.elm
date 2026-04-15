module Supervisor exposing (actor)

import Actor.Core exposing (Actor)
import Actor.Internal.Runtime exposing (ActorSystem)
import Actor.P2P as P2P exposing (Subject)
import Types exposing (AppMsg(..))


type alias Model =
    { inbox : Subject AppMsg AppMsg
    , selector : P2P.Selector AppMsg AppMsg
    }


actor : (String -> Cmd AppMsg) -> Actor (Subject AppMsg AppMsg) Model AppMsg
actor log =
    { init = init
    , update = update log
    , subscriptions = subscriptions
    }


init : Subject AppMsg AppMsg -> ( Model, Cmd AppMsg )
init inbox =
    ( { inbox = inbox
      , selector = P2P.all inbox
      }
    , Cmd.none
    )


update : (String -> Cmd AppMsg) -> AppMsg -> Model -> ( Model, Cmd AppMsg )
update log msg model =
    case msg of
        WorkerReport report ->
            ( model, log ("Supervisor got report: " ++ report) )

        _ ->
            ( model, Cmd.none )


subscriptions : ActorSystem AppMsg -> Model -> Sub (Maybe AppMsg)
subscriptions system model =
    P2P.subscribe system model.selector
