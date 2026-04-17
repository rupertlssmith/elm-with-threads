port module Main exposing (main)

{-| Example worker demonstrating the actor system with Channel messaging.

A supervisor actor spawns a worker actor, sends it jobs via a OneToOne channel,
and the worker reports back. A Broadcast channel broadcasts system events.

Each actor creates its own Selector on its Channel and subscribes to it.
The runtime collects actor subscriptions and routes matching messages back
to the owning actor.

Operations are composed with `Actor.Task`, which hides the `SystemContext`
from every call site.
-}

import Actor.Channel as Channel
import Actor.Core as Core
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext)
import Actor.Task as Task
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



-- APP-LEVEL TASK ALIAS — collapses the two runtime type params


type alias Task a =
    Task.Task AppMsg Msg Never a



-- MODEL


type alias Model =
    { system : ActorSystem AppMsg
    , procModel : Procedure.Program.Model Msg
    , eventsTopic : Maybe (Channel.Channel AppMsg Channel.Broadcast AppMsg)
    }



-- MSG


type Msg
    = ProcMsg (Procedure.Program.Msg Msg)
    | RunSystemOp (ActorSystem AppMsg -> ( ActorSystem AppMsg, Cmd Msg ))
    | DeliverToActor (Core.Process AppMsg) AppMsg
    | SetEventsTopic (Channel.Channel AppMsg Channel.Broadcast AppMsg)
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


log : String -> Task ()
log message =
    Task.fromProcedure (Procedure.do (logPort message))



-- INIT TASKS


spawnSupervisor : Task (Channel.Channel AppMsg Channel.OneToOne AppMsg)
spawnSupervisor =
    Channel.oneToOne identity Just
        |> Task.andThen
            (\reportInbox ->
                Core.spawn (Supervisor.actor logPort) reportInbox
                    |> Task.andThen (\_ -> log "Supervisor spawned")
                    |> Task.map (\() -> reportInbox)
            )


spawnWorker :
    Channel.Channel AppMsg Channel.OneToOne AppMsg
    -> Task ( Channel.Channel AppMsg Channel.OneToOne AppMsg, Channel.Channel AppMsg Channel.OneToOne AppMsg )
spawnWorker reportInbox =
    Channel.oneToOne identity Just
        |> Task.andThen
            (\workerInbox ->
                Core.spawn (Worker.actor logPort) workerInbox
                    |> Task.andThen (\_ -> log "Worker spawned")
                    |> Task.map (\() -> ( reportInbox, workerInbox ))
            )


setupBroadcast : Task (Channel.Channel AppMsg Channel.Broadcast AppMsg)
setupBroadcast =
    Channel.broadcast identity Just
        |> Task.andThen
            (\topic ->
                log "Events broadcast channel created"
                    |> Task.andThen (\() -> Task.fromProcedure (Procedure.do (Runtime.msgToCmd (SetEventsTopic topic))))
                    |> Task.map (\() -> topic)
            )


publishEvents : Channel.Channel AppMsg Channel.Broadcast AppMsg -> Task ()
publishEvents topic =
    Channel.publish topic (TopicEvent "system-started")
        |> Task.andThen (\() -> Channel.publish topic (TopicEvent "supervisor-ready"))
        |> Task.andThen (\() -> Channel.publish topic (TopicEvent "worker-spawned"))
        |> Task.andThen (\() -> log "Published 3 events to broadcast channel")


sendJobs : Channel.Channel AppMsg Channel.OneToOne AppMsg -> Task ()
sendJobs workerInbox =
    Channel.send workerInbox (WorkerJob 1)
        |> Task.andThen (\() -> Channel.send workerInbox (WorkerJob 2))
        |> Task.andThen (\() -> Channel.send workerInbox (WorkerJob 3))
        |> Task.andThen (\() -> log "Sent 3 jobs to worker")


sendReport : Channel.Channel AppMsg Channel.OneToOne AppMsg -> Task ()
sendReport reportInbox =
    Channel.send reportInbox (WorkerReport "Jobs queued")


initTask : Task ()
initTask =
    log "=== elm-actor-kafka started ==="
        |> Task.andThen (\() -> spawnSupervisor)
        |> Task.andThen spawnWorker
        |> Task.andThen
            (\( reportInbox, workerInbox ) ->
                setupBroadcast
                    |> Task.andThen publishEvents
                    |> Task.andThen (\() -> sendJobs workerInbox)
                    |> Task.andThen (\() -> sendReport reportInbox)
            )
        |> Task.andThen (\() -> log "--- Messages sent, delivery via port-bounce Sub ---")
        |> Task.andThen (\() -> log "=== Init complete ===")



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
    , Task.run ctx ProcMsg (\() -> InitDone) initTask
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
        broadcastSub =
            case model.eventsTopic of
                Just topic ->
                    Channel.subscribe model.system (Channel.all topic)
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
        , broadcastSub
        ]
