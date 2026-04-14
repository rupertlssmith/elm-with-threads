module Actor.Core exposing
    ( Actor
    , spawn
    , self
    , kill
    )

{-| Actor lifecycle management using elm-procedure for async composition.
-}

import Actor.Internal.Mailbox as Mailbox
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, ProcessEntry(..), SystemContext, msgToCmd)
import Actor.Internal.Types exposing (Process(..), ProcessId)
import Procedure


{-| Definition of an actor with flags, model and message type.
-}
type alias Actor flags model msg =
    { init : flags -> ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : model -> Sub msg
    }


{-| Spawn a new actor process with the given flags.
Returns a Procedure that yields the process handle.
-}
spawn : SystemContext msg parentMsg -> Actor flags model msg -> flags -> Procedure.Procedure Never (Process msg) parentMsg
spawn ctx actor flags =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( initialModel, initCmd ) =
                            actor.init flags

                        makeEntry pid =
                            ProcessEntry
                                { id = pid
                                , mailbox = Mailbox.empty
                                , handleMessage = handleWith actor initialModel pid
                                , actorSubs = actor.subscriptions initialModel
                                }

                        ( newSystem, spawnedPid ) =
                            Runtime.spawnProcess makeEntry system
                    in
                    ( newSystem
                    , Cmd.batch
                        [ msgToCmd (tagger (Process spawnedPid))
                        , ctx.mapAppCmd initCmd
                        ]
                    )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Get the current process. Used by the top-level process to look itself up.
-}
self : SystemContext msg parentMsg -> Procedure.Procedure Never (Process msg) parentMsg
self ctx =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    ( system, msgToCmd (tagger (Process 0)) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Kill a running process and clean up its resources.
-}
kill : SystemContext msg parentMsg -> Process msg -> Procedure.Procedure Never () parentMsg
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


handleWith : Actor flags model msg -> model -> ProcessId -> msg -> ActorSystem msg -> ( ProcessEntry msg, ActorSystem msg, Cmd msg )
handleWith actor model pid msg system =
    let
        ( newModel, cmd ) =
            actor.update msg model

        newEntry : ProcessEntry msg
        newEntry =
            ProcessEntry
                { id = pid
                , mailbox = Mailbox.empty
                , handleMessage = handleWith actor newModel pid
                , actorSubs = actor.subscriptions newModel
                }
    in
    ( newEntry, system, cmd )
