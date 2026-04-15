port module Main exposing (main)

{-| Example worker demonstrating the actor system with P2P messaging and pub/sub,
using elm-procedure for async composition.

A supervisor actor spawns a worker actor, sends it jobs via P2P subjects,
and the worker reports back. A pub/sub topic broadcasts system events.

Each actor creates its own Selector on its Subject and subscribes to it.
The runtime collects actor subscriptions and routes matching messages back
to the owning actor.
-}

import Actor.Core as Core
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


type alias Model =
    { system : ActorSystem AppMsg
    , procModel : Procedure.Program.Model Msg
    , eventsTopic : Maybe (PubSub.Topic AppMsg AppMsg)
    }



-- MSG


type Msg
    = ProcMsg (Procedure.Program.Msg Msg)
    | RunSystemOp (ActorSystem AppMsg -> ( ActorSystem AppMsg, Cmd Msg ))
    | DeliverToActor (Core.Process AppMsg) AppMsg
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



-- HELPERS


log : String -> Procedure.Procedure Never () Msg
log message =
    Procedure.do (logPort message)


createSubject : Procedure.Procedure Never (Subject AppMsg AppMsg) Msg
createSubject =
    P2P.subject ctx identity Just



-- INIT PROCEDURES


spawnSupervisor : Procedure.Procedure Never (Subject AppMsg AppMsg) Msg
spawnSupervisor =
    createSubject
        |> Procedure.andThen
            (\reportInbox ->
                Core.spawn ctx (Supervisor.actor logPort) reportInbox
                    |> Procedure.andThen (\_ -> log "Supervisor spawned")
                    |> Procedure.map (\() -> reportInbox)
            )


spawnWorker : Subject AppMsg AppMsg -> Procedure.Procedure Never ( Subject AppMsg AppMsg, Subject AppMsg AppMsg ) Msg
spawnWorker reportInbox =
    createSubject
        |> Procedure.andThen
            (\workerInbox ->
                Core.spawn ctx (Worker.actor logPort) workerInbox
                    |> Procedure.andThen (\_ -> log "Worker spawned")
                    |> Procedure.map (\() -> ( reportInbox, workerInbox ))
            )


setupPubSub : Procedure.Procedure Never (PubSub.Topic AppMsg AppMsg) Msg
setupPubSub =
    PubSub.topic ctx identity Just
        |> Procedure.andThen
            (\topic ->
                log "Events pub/sub topic created"
                    |> Procedure.andThen (\() -> Procedure.do (Runtime.msgToCmd (SetEventsTopic topic)))
                    |> Procedure.map (\() -> topic)
            )


publishEvents : PubSub.Topic AppMsg AppMsg -> Procedure.Procedure Never () Msg
publishEvents topic =
    PubSub.publish ctx topic (TopicEvent "system-started")
        |> Procedure.andThen (\() -> PubSub.publish ctx topic (TopicEvent "supervisor-ready"))
        |> Procedure.andThen (\() -> PubSub.publish ctx topic (TopicEvent "worker-spawned"))
        |> Procedure.andThen (\() -> log "Published 3 events to pub/sub topic")


sendJobs : Subject AppMsg AppMsg -> Procedure.Procedure Never () Msg
sendJobs workerInbox =
    P2P.send ctx workerInbox (WorkerJob 1)
        |> Procedure.andThen (\() -> P2P.send ctx workerInbox (WorkerJob 2))
        |> Procedure.andThen (\() -> P2P.send ctx workerInbox (WorkerJob 3))
        |> Procedure.andThen (\() -> log "Sent 3 jobs to worker")


sendReport : Subject AppMsg AppMsg -> Procedure.Procedure Never () Msg
sendReport reportInbox =
    P2P.send ctx reportInbox (WorkerReport "Jobs queued")


initProcedure : Procedure.Procedure Never () Msg
initProcedure =
    log "=== elm-actor-kafka started ==="
        |> Procedure.andThen (\() -> spawnSupervisor)
        |> Procedure.andThen spawnWorker
        |> Procedure.andThen
            (\( reportInbox, workerInbox ) ->
                setupPubSub
                    |> Procedure.andThen publishEvents
                    |> Procedure.andThen (\() -> sendJobs workerInbox)
                    |> Procedure.andThen (\() -> sendReport reportInbox)
            )
        |> Procedure.andThen (\() -> log "--- Messages sent, delivery via port-bounce Sub ---")
        |> Procedure.andThen (\() -> log "=== Init complete ===")



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
      , eventsTopic = Nothing
      }
    , Procedure.run ProcMsg (\() -> InitDone) initProcedure
    )



-- UPDATE


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

        DeliverToActor process appMsg ->
            let
                ( newSystem, actorCmd ) =
                    Runtime.deliver process appMsg model.system
            in
            ( { model | system = newSystem }, Cmd.map (\_ -> NoOp) actorCmd )

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



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    let
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
        [ Procedure.Program.subscriptions model.procModel
        , Time.every 1000 Tick
        , Runtime.collectSubscriptions DeliverToActor NoOp model.system
        , pubsubSub
        ]
