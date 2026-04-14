port module Main exposing (main)

{-| Example worker demonstrating the actor system with P2P messaging and topics,
using elm-procedure for async composition.

A supervisor actor spawns a worker actor, sends it jobs via P2P subjects,
and the worker reports back. A topic is also created and used for event logging.

Subscribe uses real Elm Sub via port-bounce: each send fires a port notification,
JS echoes it back, and the subscribe Sub picks up matching messages.
-}

import Actor.Core as Core exposing (Actor)
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext)
import Actor.Internal.Types exposing (Process)
import Actor.P2P as P2P exposing (Subject)
import Actor.Topic as Topic exposing (Consumer, Topic)
import Platform
import Procedure
import Procedure.Program
import Time


-- PORTS


port logPort : String -> Cmd msg


port exitPort : () -> Cmd msg



-- APP MSG


type AppMsg
    = WorkerJob Int
    | WorkerReport String
    | TopicEvent String
    | Heartbeat Time.Posix



-- MODEL


type alias Route =
    { process : Process AppMsg
    , selector : P2P.Selector AppMsg AppMsg
    }


type alias Model =
    { system : ActorSystem AppMsg
    , procModel : Procedure.Program.Model Msg
    , routes : List Route
    }



-- MSG


type Msg
    = ProcMsg (Procedure.Program.Msg Msg)
    | RunSystemOp (ActorSystem AppMsg -> ( ActorSystem AppMsg, Cmd Msg ))
    | RouteToActor (Process AppMsg) AppMsg
    | RegisterRoute (Process AppMsg) (P2P.Selector AppMsg AppMsg)
    | InitDone
    | Tick Time.Posix
    | NoOp



-- SYSTEM CONTEXT


ctx : SystemContext AppMsg Msg
ctx =
    { runOp = RunSystemOp
    , mapAppCmd = Cmd.map (\_ -> NoOp)
    }



-- ACTORS


supervisorActor : Actor (Subject AppMsg) (Subject AppMsg) AppMsg
supervisorActor =
    { init = \inbox -> ( inbox, Cmd.none )
    , update =
        \msg model ->
            case msg of
                WorkerReport report ->
                    ( model, logPort ("Supervisor got report: " ++ report) )

                _ ->
                    ( model, Cmd.none )
    , subscriptions = \_ -> Sub.none
    }


type alias WorkerModel =
    { inbox : Subject AppMsg
    , jobCount : Int
    }


workerActor : Actor (Subject AppMsg) WorkerModel AppMsg
workerActor =
    { init = \inbox -> ( { inbox = inbox, jobCount = 0 }, Cmd.none )
    , update =
        \msg model ->
            case msg of
                WorkerJob n ->
                    let
                        newCount =
                            model.jobCount + 1
                    in
                    ( { model | jobCount = newCount }
                    , logPort ("Worker processing job #" ++ String.fromInt n ++ " (total: " ++ String.fromInt newCount ++ ")")
                    )

                Heartbeat time ->
                    ( model
                    , logPort ("Worker heartbeat at " ++ String.fromInt (Time.posixToMillis time) ++ "ms (jobs done: " ++ String.fromInt model.jobCount ++ ")")
                    )

                _ ->
                    ( model, Cmd.none )
    , subscriptions =
        \_ ->
            Time.every 2000 Heartbeat
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
      }
    , Procedure.run ProcMsg (\() -> InitDone) initProcedure
    )


initProcedure : Procedure.Procedure Never () Msg
initProcedure =
    Procedure.do (logPort "=== elm-actor-kafka started ===")
        -- Create subjects first, then spawn actors with them as flags
        |> Procedure.andThen (\() -> P2P.subject ctx)
        |> Procedure.andThen
            (\reportInbox ->
                Core.spawn ctx supervisorActor reportInbox
                    |> Procedure.andThen
                        (\supProcess ->
                            Procedure.do (logPort "Supervisor spawned")
                                |> Procedure.andThen
                                    (\() ->
                                        Procedure.do (Runtime.msgToCmd (RegisterRoute supProcess (P2P.fromSubject reportInbox)))
                                    )
                                |> Procedure.map (\() -> reportInbox)
                        )
            )
        |> Procedure.andThen
            (\reportInbox ->
                P2P.subject ctx
                    |> Procedure.andThen
                        (\workerInbox ->
                            Core.spawn ctx workerActor workerInbox
                                |> Procedure.andThen
                                    (\workerProcess ->
                                        Procedure.do (logPort "Worker spawned")
                                            |> Procedure.andThen
                                                (\() ->
                                                    Procedure.do (Runtime.msgToCmd (RegisterRoute workerProcess (P2P.fromSubject workerInbox)))
                                                )
                                            |> Procedure.map (\() -> ( reportInbox, workerInbox ))
                                    )
                        )
            )
        |> Procedure.andThen
            (\( reportInbox, workerInbox ) ->
                Topic.createTopic ctx "events" 3
                    |> Procedure.andThen
                        (\eventsTopic ->
                            Procedure.do (logPort "Events topic created with 3 partitions")
                                |> Procedure.andThen (\() -> Topic.createConsumer ctx eventsTopic "logger-group")
                                |> Procedure.andThen
                                    (\maybeConsumer ->
                                        -- Publish events
                                        Topic.publish ctx eventsTopic (TopicEvent "system-started")
                                            |> Procedure.andThen (\() -> Topic.publish ctx eventsTopic (TopicEvent "supervisor-ready"))
                                            |> Procedure.andThen (\() -> Topic.publish ctx eventsTopic (TopicEvent "worker-spawned"))
                                            |> Procedure.andThen (\() -> Procedure.do (logPort "Published 3 events to topic"))
                                            -- Send jobs to worker
                                            |> Procedure.andThen (\() -> P2P.send ctx workerInbox (WorkerJob 1))
                                            |> Procedure.andThen (\() -> P2P.send ctx workerInbox (WorkerJob 2))
                                            |> Procedure.andThen (\() -> P2P.send ctx workerInbox (WorkerJob 3))
                                            |> Procedure.andThen (\() -> Procedure.do (logPort "Sent 3 jobs to worker"))
                                            -- Send report to supervisor
                                            |> Procedure.andThen (\() -> P2P.send ctx reportInbox (WorkerReport "Jobs queued"))
                                            |> Procedure.andThen (\() -> Procedure.do (logPort "--- Messages sent, delivery via port-bounce Sub ---"))
                                            -- Poll topic consumer
                                            |> Procedure.andThen (\() -> pollAndLogTopicEvents ctx maybeConsumer)
                                            |> Procedure.andThen (\() -> Procedure.do (logPort "=== Init complete ==="))
                                    )
                        )
            )


pollAndLogTopicEvents : SystemContext AppMsg Msg -> Maybe Consumer -> Procedure.Procedure Never () Msg
pollAndLogTopicEvents sysCtx maybeConsumer =
    case maybeConsumer of
        Just consumer ->
            Topic.poll sysCtx consumer
                |> Procedure.andThen
                    (\messages ->
                        let
                            topicLogCmds =
                                messages
                                    |> List.filterMap
                                        (\m ->
                                            case m of
                                                TopicEvent e ->
                                                    Just (logPort ("Topic event: " ++ e))

                                                _ ->
                                                    Nothing
                                        )
                        in
                        Procedure.do (Cmd.batch (List.reverse topicLogCmds))
                            |> Procedure.andThen
                                (\() ->
                                    Procedure.do (logPort ("--- Topic consumer polled " ++ String.fromInt (List.length messages) ++ " events ---"))
                                )
                    )
                |> Procedure.andThen (\() -> Topic.commit sysCtx consumer)

        Nothing ->
            Procedure.provide ()


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
    in
    Sub.batch
        ([ Procedure.Program.subscriptions model.procModel
         , Time.every 1000 Tick
         , Runtime.collectSubscriptions RouteToActor model.system
         ]
            ++ p2pSubs
        )
