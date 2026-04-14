module Actor.P2P exposing
    ( Subject
    , Selector
    , Key
    , createSubject
    , send
    , sendKeyed
    , deliverMessages
    , selector
    , selectMap
    , map
    , filter
    , orElse
    , select
    , subscribe
    )

{-| Point-to-point messaging between actors via subjects and selectors,
using elm-procedure for async composition.

@docs Subject, Selector, Key
@docs createSubject, send, sendKeyed, deliverMessages
@docs selector, selectMap, map, filter, orElse
@docs select, subscribe

-}

import Actor.Internal.Mailbox as Mailbox
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, ProcessEntry(..), SystemContext, msgToCmd)
import Actor.Internal.Selector as Sel exposing (SelectorAst(..), SelectorEntry)
import Actor.Internal.Types exposing (ProcessId, SelectorId, SubjectId)
import Procedure


{-| A subject is a named mailbox owned by a process. Other actors send messages
to a subject; the owning process receives them.
-}
type Subject appMsg
    = Subject SubjectId


{-| A selector defines how to match and transform incoming messages.
-}
type Selector appMsg
    = Selector (SelectorAst appMsg)


{-| A routing key for keyed sends.
-}
type alias Key =
    String


{-| Create a new subject owned by the given process.
-}
createSubject : SystemContext appMsg msg -> ProcessId -> Procedure.Procedure Never (Subject appMsg) msg
createSubject ctx ownerPid =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( newSystem, sid ) =
                            Runtime.createSubject ownerPid system
                    in
                    ( newSystem, msgToCmd (tagger (Subject sid)) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Send a message to a subject.
-}
send : SystemContext appMsg msg -> Subject appMsg -> appMsg -> Procedure.Procedure Never () msg
send ctx (Subject sid) appMsg =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    ( Runtime.sendToSubject sid appMsg system
                    , msgToCmd (tagger ())
                    )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Send a keyed message to a subject.
-}
sendKeyed : SystemContext appMsg msg -> Subject appMsg -> Key -> appMsg -> Procedure.Procedure Never () msg
sendKeyed ctx (Subject sid) key appMsg =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    ( Runtime.sendKeyedToSubject sid key appMsg system
                    , msgToCmd (tagger ())
                    )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Deliver all pending messages from process mailboxes.
Actor commands are forwarded via the context's mapAppCmd.
-}
deliverMessages : SystemContext appMsg msg -> Procedure.Procedure Never () msg
deliverMessages ctx =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( newSystem, actorCmds ) =
                            Runtime.deliverPendingMessages system
                    in
                    ( newSystem
                    , Cmd.batch
                        [ ctx.mapAppCmd actorCmds
                        , msgToCmd (tagger ())
                        ]
                    )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Create a base selector that matches any message.
-}
selector : Selector appMsg
selector =
    Selector SelectAny


{-| Add a subject source to a selector with a transformation function.
-}
selectMap : Subject appMsg -> (appMsg -> appMsg) -> Selector appMsg -> Selector appMsg
selectMap (Subject sid) transform (Selector ast) =
    Selector (SelectOrElse (SelectMap transform (SelectFromSubject sid Just)) ast)


{-| Transform the result of a selector.
-}
map : (appMsg -> appMsg) -> Selector appMsg -> Selector appMsg
map f (Selector ast) =
    Selector (SelectMap f ast)


{-| Filter selector results by a predicate.
-}
filter : (appMsg -> Bool) -> Selector appMsg -> Selector appMsg
filter pred (Selector ast) =
    Selector (SelectFilter pred ast)


{-| Combine two selectors — try the first, fall back to the second.
-}
orElse : Selector appMsg -> Selector appMsg -> Selector appMsg
orElse (Selector left) (Selector right) =
    Selector (SelectOrElse left right)


{-| One-shot select: try to match a message from the process's mailbox.
Returns the matched message or Nothing.
-}
select : SystemContext appMsg msg -> Selector appMsg -> ProcessId -> Procedure.Procedure Never (Maybe appMsg) msg
select ctx (Selector ast) ownerPid =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    case Runtime.getProcess ownerPid system of
                        Nothing ->
                            ( system, msgToCmd (tagger Nothing) )

                        Just (ProcessEntry r) ->
                            let
                                result =
                                    tryMatch ast (Mailbox.toList r.mailbox)
                            in
                            ( system, msgToCmd (tagger result) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Register a continuous subscription. Messages matching the selector
will be delivered to the owning process.
-}
subscribe : SystemContext appMsg msg -> Selector appMsg -> ProcessId -> Procedure.Procedure Never SelectorId msg
subscribe ctx (Selector ast) ownerPid =
    Procedure.fetch
        (\tagger ->
            let
                entry : SelectorEntry appMsg
                entry =
                    { id = 0
                    , ast = ast
                    , owner = ownerPid
                    , continuous = True
                    }

                op system =
                    let
                        ( newSystem, sid ) =
                            Runtime.registerSelector entry system
                    in
                    ( newSystem, msgToCmd (tagger sid) )
            in
            msgToCmd (ctx.runOp op)
        )



-- INTERNAL


tryMatch : SelectorAst appMsg -> List appMsg -> Maybe appMsg
tryMatch ast messages =
    case messages of
        [] ->
            Nothing

        msg :: rest ->
            case Sel.matchSelector ast msg 0 of
                Just result ->
                    Just result

                Nothing ->
                    tryMatch ast rest
