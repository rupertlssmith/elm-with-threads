module Actor.Core exposing
    ( Actor
    , Process
    , spawn
    , self
    , kill
    )

{-| Actor lifecycle management. Each operation returns an `Actor.Task.Task`
that internally threads the `SystemContext` so call sites don't have to.

@docs Actor, Process
@docs spawn, self, kill

-}

import Actor.Internal.Mailbox as Mailbox
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, ProcessEntry(..), msgToCmd)
import Actor.Internal.Types as InternalTypes exposing (Process(..), ProcessId)
import Actor.Task as Task exposing (Task)
import Procedure


{-| Definition of an actor with flags, model and message type.

In the real platform, subscriptions would be `model -> Sub msg` and the
platform provides the system context implicitly. In this simulation,
the ActorSystem is passed explicitly, and Sub returns Maybe to handle
port-bounce events that don't match the actor's selector.
-}
type alias Actor flags model msg =
    { init : flags -> ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : ActorSystem msg -> model -> Sub (Maybe msg)
    }


{-| An opaque handle to a running actor process.
-}
type alias Process msg =
    InternalTypes.Process msg


{-| Spawn a new actor process with the given flags.
-}
spawn : Actor flags model msg -> flags -> Task msg parentMsg err (Process msg)
spawn actor flags =
    Task.fromContext
        (\ctx ->
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
                                        , actorSubs = \sys -> actor.subscriptions sys initialModel
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
        )


{-| Get the current process. Used by the top-level process to look itself up.
-}
self : Task msg parentMsg err (Process msg)
self =
    Task.fromContext
        (\ctx ->
            Procedure.fetch
                (\tagger ->
                    let
                        op system =
                            ( system, msgToCmd (tagger (Process 0)) )
                    in
                    msgToCmd (ctx.runOp op)
                )
        )


{-| Kill a running process and clean up its resources.
-}
kill : Process msg -> Task msg parentMsg err ()
kill (Process pid) =
    Task.fromContext
        (\ctx ->
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
                , actorSubs = \sys -> actor.subscriptions sys newModel
                }
    in
    ( newEntry, system, cmd )
