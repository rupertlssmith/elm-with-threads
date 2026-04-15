module Supervisor exposing (actor)

import Actor.Channel as Channel
import Actor.Core exposing (Actor)
import Actor.Internal.Runtime exposing (ActorSystem)
import Types exposing (AppMsg(..))


type alias Model =
    { inbox : Channel.Channel AppMsg Channel.OneToOne AppMsg
    , selector : Channel.Selector AppMsg AppMsg
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
    Channel.subscribe system model.selector
