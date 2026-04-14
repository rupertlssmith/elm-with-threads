port module Main exposing (main)

{-| Example worker demonstrating the actor system with P2P messaging and topics,
using elm-procedure for async composition.

A supervisor actor spawns a worker actor, sends it jobs via P2P subjects,
and the worker reports back. A topic is also created and used for event logging.
All operations are composed as Procedures and executed asynchronously.
-}

import Actor.Core as Core exposing (Actor, Process)
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext)
import Actor.Internal.Types exposing (ProcessId)
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



-- MODEL


type alias Model =
    { system : ActorSystem AppMsg
    , procModel : Procedure.Program.Model Msg
    }



-- MSG


type Msg
    = ProcMsg (Procedure.Program.Msg Msg)
    | RunSystemOp (ActorSystem AppMsg -> ( ActorSystem AppMsg, Cmd Msg ))
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


supervisorActor : Actor () AppMsg
supervisorActor =
    { init = \_ -> ()
    , update =
        \msg model ->
            case msg of
                WorkerReport report ->
                    ( model, logPort ("Supervisor got report: " ++ report) )

                _ ->
                    ( model, Cmd.none )
    }


workerActor : Actor Int AppMsg
workerActor =
    { init = \_ -> 0
    , update =
        \msg jobCount ->
            case msg of
                WorkerJob n ->
                    let
                        newCount =
                            jobCount + 1
                    in
                    ( newCount
                    , logPort ("Worker processing job #" ++ String.fromInt n ++ " (total: " ++ String.fromInt newCount ++ ")")
                    )

                _ ->
                    ( jobCount, Cmd.none )
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
      }
    , Procedure.run ProcMsg (\() -> InitDone) initProcedure
    )


initProcedure : Procedure.Procedure Never () Msg
initProcedure =
    Procedure.do (logPort "=== elm-actor-kafka started ===")
        |> Procedure.andThen
            (\() ->
                Core.spawn ctx supervisorActor
            )
        |> Procedure.andThen
            (\supProcess ->
                let
                    supPid =
                        Core.processId supProcess
                in
                Procedure.do (logPort ("Supervisor PID: " ++ String.fromInt supPid))
                    |> Procedure.andThen (\() -> P2P.createSubject ctx supPid)
            )
        |> Procedure.andThen
            (\reportInbox ->
                Core.spawn ctx workerActor
                    |> Procedure.andThen
                        (\workerProcess ->
                            let
                                workerPid =
                                    Core.processId workerProcess
                            in
                            Procedure.do (logPort ("Worker PID: " ++ String.fromInt workerPid))
                                |> Procedure.andThen (\() -> P2P.createSubject ctx workerPid)
                                |> Procedure.map (\workerInbox -> ( reportInbox, workerInbox ))
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
                                            -- Deliver messages
                                            |> Procedure.andThen (\() -> Procedure.do (logPort "--- Delivering messages ---"))
                                            |> Procedure.andThen (\() -> P2P.deliverMessages ctx)
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
    Sub.batch
        [ Procedure.Program.subscriptions model.procModel
        , Time.every 1000 Tick
        ]
