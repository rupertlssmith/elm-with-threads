port module Main exposing (main)

{-| Example worker demonstrating the actor system with Channel messaging,
using elm-procedure for async composition.

A supervisor actor spawns a worker actor, sends it jobs via a OneToOne channel,
and the worker reports back. A Broadcast channel broadcasts system events.

Each actor creates its own Selector on its Channel and subscribes to it.
The runtime collects actor subscriptions and routes matching messages back
to the owning actor.
-}

import Actor.Channel as Channel
import Actor.Core as Core
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext)
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


log : String -> Procedure.Procedure Never () Msg
log message =
    Procedure.do (logPort message)


createOneToOne : Procedure.Procedure Never (Channel.Channel AppMsg Channel.OneToOne AppMsg) Msg
createOneToOne =
    Channel.oneToOne ctx identity Just



-- INIT PROCEDURES


spawnSupervisor : Procedure.Procedure Never (Channel.Channel AppMsg Channel.OneToOne AppMsg) Msg
spawnSupervisor =
    createOneToOne
        |> Procedure.andThen
            (\reportInbox ->
                Core.spawn ctx (Supervisor.actor logPort) reportInbox
                    |> Procedure.andThen (\_ -> log "Supervisor spawned")
                    |> Procedure.map (\() -> reportInbox)
            )


spawnWorker : Channel.Channel AppMsg Channel.OneToOne AppMsg -> Procedure.Procedure Never ( Channel.Channel AppMsg Channel.OneToOne AppMsg, Channel.Channel AppMsg Channel.OneToOne AppMsg ) Msg
spawnWorker reportInbox =
    createOneToOne
        |> Procedure.andThen
            (\workerInbox ->
                Core.spawn ctx (Worker.actor logPort) workerInbox
                    |> Procedure.andThen (\_ -> log "Worker spawned")
                    |> Procedure.map (\() -> ( reportInbox, workerInbox ))
            )


setupBroadcast : Procedure.Procedure Never (Channel.Channel AppMsg Channel.Broadcast AppMsg) Msg
setupBroadcast =
    Channel.broadcast ctx identity Just
        |> Procedure.andThen
            (\topic ->
                log "Events broadcast channel created"
                    |> Procedure.andThen (\() -> Procedure.do (Runtime.msgToCmd (SetEventsTopic topic)))
                    |> Procedure.map (\() -> topic)
            )


publishEvents : Channel.Channel AppMsg Channel.Broadcast AppMsg -> Procedure.Procedure Never () Msg
publishEvents topic =
    Channel.publish ctx topic (TopicEvent "system-started")
        |> Procedure.andThen (\() -> Channel.publish ctx topic (TopicEvent "supervisor-ready"))
        |> Procedure.andThen (\() -> Channel.publish ctx topic (TopicEvent "worker-spawned"))
        |> Procedure.andThen (\() -> log "Published 3 events to broadcast channel")


sendJobs : Channel.Channel AppMsg Channel.OneToOne AppMsg -> Procedure.Procedure Never () Msg
sendJobs workerInbox =
    Channel.send ctx workerInbox (WorkerJob 1)
        |> Procedure.andThen (\() -> Channel.send ctx workerInbox (WorkerJob 2))
        |> Procedure.andThen (\() -> Channel.send ctx workerInbox (WorkerJob 3))
        |> Procedure.andThen (\() -> log "Sent 3 jobs to worker")


sendReport : Channel.Channel AppMsg Channel.OneToOne AppMsg -> Procedure.Procedure Never () Msg
sendReport reportInbox =
    Channel.send ctx reportInbox (WorkerReport "Jobs queued")


initProcedure : Procedure.Procedure Never () Msg
initProcedure =
    log "=== elm-actor-kafka started ==="
        |> Procedure.andThen (\() -> spawnSupervisor)
        |> Procedure.andThen spawnWorker
        |> Procedure.andThen
            (\( reportInbox, workerInbox ) ->
                setupBroadcast
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
