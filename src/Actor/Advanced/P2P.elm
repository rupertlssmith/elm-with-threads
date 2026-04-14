module Actor.Advanced.P2P exposing
    ( Meta
    , Envelope
    , Key
    , Subject
    , Selector
    , createSubject
    , send
    , sendKeyed
    , resendAsPossibleDuplicate
    , selector
    , selectMap
    , map
    , filter
    , orElse
    , select
    , subscribe
    )

{-| Enriched P2P messaging with metadata envelopes,
using elm-procedure for async composition.

@docs Meta, Envelope, Key
@docs Subject, Selector
@docs createSubject, send, sendKeyed, resendAsPossibleDuplicate
@docs selector, selectMap, map, filter, orElse
@docs select, subscribe

-}

import Actor.Internal.Mailbox as Mailbox
import Actor.Internal.Runtime as Runtime exposing (ActorSystem, ProcessEntry(..), SystemContext, msgToCmd)
import Actor.Internal.Selector as Sel exposing (SelectorAst(..), SelectorEntry)
import Actor.Internal.Types exposing (ProcessId, SelectorId, SubjectId)
import Procedure
import Time


{-| Metadata attached to each message.
-}
type alias Meta =
    { key : Maybe Key
    , possibleDuplicate : Bool
    , sequence : Maybe Int
    , timestamp : Time.Posix
    , sender : Maybe ProcessId
    }


{-| A message wrapped with metadata.
-}
type alias Envelope a =
    { meta : Meta
    , payload : a
    }


type alias Key =
    String


{-| An advanced subject wraps a process id and subject id.
-}
type Subject appMsg
    = Subject SubjectId ProcessId


{-| A selector for advanced P2P with metadata.
-}
type Selector appMsg
    = Selector (SelectorAst appMsg)


{-| Create a new advanced subject owned by the given process.
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
                    ( newSystem, msgToCmd (tagger (Subject sid ownerPid)) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Send a message to an advanced subject (no key, not a duplicate).
-}
send : SystemContext appMsg msg -> Subject appMsg -> appMsg -> Procedure.Procedure Never () msg
send ctx (Subject sid _) appMsg =
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


{-| Send a keyed message to an advanced subject.
-}
sendKeyed : SystemContext appMsg msg -> Subject appMsg -> Key -> appMsg -> Procedure.Procedure Never () msg
sendKeyed ctx (Subject sid _) key appMsg =
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


{-| Resend a message marked as a possible duplicate.
-}
resendAsPossibleDuplicate : SystemContext appMsg msg -> Subject appMsg -> Key -> appMsg -> Procedure.Procedure Never () msg
resendAsPossibleDuplicate ctx (Subject sid _) key appMsg =
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


{-| Create a base selector.
-}
selector : Selector appMsg
selector =
    Selector SelectAny


{-| Add a subject source to a selector with a transformation.
-}
selectMap : Subject appMsg -> (appMsg -> appMsg) -> Selector appMsg -> Selector appMsg
selectMap (Subject sid _) transform (Selector ast) =
    Selector (SelectOrElse (SelectMap transform (SelectFromSubject sid Just)) ast)


{-| Transform selector results.
-}
map : (appMsg -> appMsg) -> Selector appMsg -> Selector appMsg
map f (Selector ast) =
    Selector (SelectMap f ast)


{-| Filter selector results.
-}
filter : (appMsg -> Bool) -> Selector appMsg -> Selector appMsg
filter pred (Selector ast) =
    Selector (SelectFilter pred ast)


{-| Combine two selectors.
-}
orElse : Selector appMsg -> Selector appMsg -> Selector appMsg
orElse (Selector left) (Selector right) =
    Selector (SelectOrElse left right)


{-| One-shot select.
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


{-| Register a continuous subscription.
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
