port module Main exposing (main)

{-| Example worker demonstrating the actor system with P2P messaging and pub/sub,
using elm-procedure for async composition.

A supervisor actor spawns a worker actor, sends it jobs via P2P subjects,
and the worker reports back. A pub/sub topic broadcasts system events.

Subscribe uses real Elm Sub via port-bounce: each send fires a port notification,
JS echoes it back, and the subscribe Sub picks up matching messages.
-}

import Actor.Core as Core exposing (Process)
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext)
import Actor.P2P as P2P exposing (Subject)
import Actor.PubSub as PubSub
import Platform
import Procedure
import Procedure.Program
import Supervisor
import Time
import Types exposing (AppMsg(..))
import Worker



-- PORTS


port logPort : String -> Cmd msg


port exitPort : () -> Cmd msg



-- MODEL


type alias Route =
    { process : Process AppMsg
    , selector : P2P.Selector AppMsg AppMsg
    }


type alias Model =
    { system : ActorSystem AppMsg
    , procModel : Procedure.Program.Model Msg
    , routes : List Route
    , eventsTopic : Maybe (PubSub.Topic AppMsg AppMsg)
    }



-- MSG


type Msg
    = ProcMsg (Procedure.Program.Msg Msg)
    | RunSystemOp (ActorSystem AppMsg -> ( ActorSystem AppMsg, Cmd Msg ))
    | RouteToActor (Process AppMsg) AppMsg
    | RegisterRoute (Process AppMsg) (P2P.Selector AppMsg AppMsg)
    | SetEventsTopic (PubSub.Topic AppMsg AppMsg)
    | BroadcastEvent AppMsg
    | InitDone
    | Tick Time.Posix
    | NoOp



-- SYSTEM CONTEXT


ctx : SystemContext AppMsg Msg
ctx =
    { runOp = RunSystemOp
    , mapAppCmd = Cmd.map (\_ -> NoOp)
    }



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
      , routes = []
      , eventsTopic = Nothing
      }
    , Procedure.run ProcMsg (\() -> InitDone) initProcedure
    )


initProcedure : Procedure.Procedure Never () Msg
initProcedure =
    Procedure.do (logPort "=== elm-actor-kafka started ===")
        -- Create subjects first, then spawn actors with them as flags
        |> Procedure.andThen (\() -> P2P.subject ctx identity Just)
        |> Procedure.andThen
            (\reportInbox ->
                Core.spawn ctx (Supervisor.actor logPort) reportInbox
                    |> Procedure.andThen
                        (\supProcess ->
                            Procedure.do (logPort "Supervisor spawned")
                                |> Procedure.andThen
                                    (\() ->
                                        Procedure.do (Runtime.msgToCmd (RegisterRoute supProcess (P2P.all reportInbox)))
                                    )
                                |> Procedure.map (\() -> reportInbox)
                        )
            )
        |> Procedure.andThen
            (\reportInbox ->
                P2P.subject ctx identity Just
                    |> Procedure.andThen
                        (\workerInbox ->
                            Core.spawn ctx (Worker.actor logPort) workerInbox
                                |> Procedure.andThen
                                    (\workerProcess ->
                                        Procedure.do (logPort "Worker spawned")
                                            |> Procedure.andThen
                                                (\() ->
                                                    Procedure.do (Runtime.msgToCmd (RegisterRoute workerProcess (P2P.all workerInbox)))
                                                )
                                            |> Procedure.map (\() -> ( reportInbox, workerInbox ))
                                    )
                        )
            )
        |> Procedure.andThen
            (\( reportInbox, workerInbox ) ->
                PubSub.topic ctx identity Just
                    |> Procedure.andThen
                        (\eventsTopic ->
                            Procedure.do (logPort "Events pub/sub topic created")
                                |> Procedure.andThen (\() -> Procedure.do (Runtime.msgToCmd (SetEventsTopic eventsTopic)))
                                -- Publish events
                                |> Procedure.andThen (\() -> PubSub.publish ctx eventsTopic (TopicEvent "system-started"))
                                |> Procedure.andThen (\() -> PubSub.publish ctx eventsTopic (TopicEvent "supervisor-ready"))
                                |> Procedure.andThen (\() -> PubSub.publish ctx eventsTopic (TopicEvent "worker-spawned"))
                                |> Procedure.andThen (\() -> Procedure.do (logPort "Published 3 events to pub/sub topic"))
                                -- Send jobs to worker
                                |> Procedure.andThen (\() -> P2P.send ctx workerInbox (WorkerJob 1))
                                |> Procedure.andThen (\() -> P2P.send ctx workerInbox (WorkerJob 2))
                                |> Procedure.andThen (\() -> P2P.send ctx workerInbox (WorkerJob 3))
                                |> Procedure.andThen (\() -> Procedure.do (logPort "Sent 3 jobs to worker"))
                                -- Send report to supervisor
                                |> Procedure.andThen (\() -> P2P.send ctx reportInbox (WorkerReport "Jobs queued"))
                                |> Procedure.andThen (\() -> Procedure.do (logPort "--- Messages sent, delivery via port-bounce Sub ---"))
                                |> Procedure.andThen (\() -> Procedure.do (logPort "=== Init complete ==="))
                        )
            )


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

        RouteToActor process appMsg ->
            let
                ( newSystem, actorCmd ) =
                    Runtime.deliver process appMsg model.system
            in
            ( { model | system = newSystem }, Cmd.map (\_ -> NoOp) actorCmd )

        RegisterRoute process sel ->
            ( { model | routes = { process = process, selector = sel } :: model.routes }
            , Cmd.none
            )

        SetEventsTopic topic ->
            ( { model | eventsTopic = Just topic }
            , Cmd.none
            )

        BroadcastEvent appMsg ->
            case appMsg of
                TopicEvent e ->
                    ( model, logPort ("Broadcast event: " ++ e) )

                _ ->
                    ( model, Cmd.none )

        InitDone ->
            ( model, Cmd.none )

        Tick time ->
            ( { model | system = Runtime.updateTime time model.system }
            , Cmd.none
            )

        NoOp ->
            ( model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    let
        p2pSubs =
            model.routes
                |> List.map
                    (\route ->
                        P2P.subscribe model.system route.selector
                            |> Sub.map
                                (\maybe ->
                                    case maybe of
                                        Just appMsg ->
                                            RouteToActor route.process appMsg

                                        Nothing ->
                                            NoOp
                                )
                    )

        pubsubSub =
            case model.eventsTopic of
                Just topic ->
                    PubSub.subscribe model.system topic
                        |> Sub.map
                            (\maybe ->
                                case maybe of
                                    Just appMsg ->
                                        BroadcastEvent appMsg

                                    Nothing ->
                                        NoOp
                            )

                Nothing ->
                    Sub.none
    in
    Sub.batch
        ([ Procedure.Program.subscriptions model.procModel
         , Time.every 1000 Tick
         , Runtime.collectSubscriptions RouteToActor model.system
         , pubsubSub
         ]
            ++ p2pSubs
        )
