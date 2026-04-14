module Actor.Core exposing
    ( Process
    , Actor
    , spawn
    , kill
    , processId
    )

{-| Actor lifecycle management using elm-procedure for async composition.
-}

import Actor.Internal.Mailbox as Mailbox
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, ProcessEntry(..), SystemContext, msgToCmd)
import Actor.Internal.Types exposing (ProcessId)
import Procedure


{-| An opaque handle to a running actor process.
-}
type Process
    = Process ProcessId


{-| Definition of an actor. The init function receives the process's own ProcessId.
The update function handles a message and returns an updated model plus commands.
-}
type alias Actor model appMsg =
    { init : ProcessId -> model
    , update : appMsg -> model -> ( model, Cmd appMsg )
    }


{-| Spawn a new actor process. Returns a Procedure that yields the process handle.
-}
spawn : SystemContext appMsg msg -> Actor model appMsg -> Procedure.Procedure Never Process msg
spawn ctx actor =
    Procedure.fetch
        (\tagger ->
            let
                makeHandler processId_ =
                    let
                        initialModel =
                            actor.init processId_
                    in
                    handleWith actor initialModel processId_

                op system =
                    let
                        ( newSystem, pid ) =
                            Runtime.spawnProcess makeHandler system
                    in
                    ( newSystem, msgToCmd (tagger (Process pid)) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Extract the raw ProcessId from a Process handle.
-}
processId : Process -> ProcessId
processId (Process pid) =
    pid


{-| Kill a running process and clean up its resources.
-}
kill : SystemContext appMsg msg -> Process -> Procedure.Procedure Never () msg
kill ctx (Process pid) =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    ( Runtime.killProcess pid system
                    , msgToCmd (tagger ())
                    )
            in
            msgToCmd (ctx.runOp op)
        )



-- INTERNAL


handleWith : Actor model appMsg -> model -> ProcessId -> appMsg -> ActorSystem appMsg -> ( ProcessEntry appMsg, ActorSystem appMsg, Cmd appMsg )
handleWith actor model pid msg system =
    let
        ( newModel, cmd ) =
            actor.update msg model

        newEntry : ProcessEntry appMsg
        newEntry =
            ProcessEntry
                { id = pid
                , mailbox = Mailbox.empty
                , handleMessage = handleWith actor newModel pid
                }
    in
    ( newEntry, system, cmd )
