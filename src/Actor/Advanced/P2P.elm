module Actor.Advanced.P2P exposing
    ( Meta
    , Envelope
    , Key
    , Subject
    , Selector
    , subject
    , send
    , sendKeyed
    , resendAsPossibleDuplicate
    , fromSubject
    , selector
    , selectMap
    , map
    , filter
    , orElse
    , select
    , subscribe
    )

{-| Enriched P2P messaging with metadata envelopes.

Send operations use elm-procedure for async composition.
Subscribe returns a real Elm Sub via port-bounce.

Selectors have two type parameters: `msg` is the input message type,
`result` is the output type after transformation.

@docs Meta, Envelope, Key
@docs Subject, Selector
@docs subject, send, sendKeyed, resendAsPossibleDuplicate
@docs fromSubject, selector, selectMap, map, filter, orElse
@docs select, subscribe

-}

import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext, msgToCmd)
import Actor.Internal.Types exposing (SubjectId)
import Actor.Ports
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


{-| An advanced subject wraps a subject id.
-}
type Subject a
    = Subject SubjectId


{-| A selector for advanced P2P with metadata.
`msg` is the input message type, `result` is the output type.
-}
type Selector msg result
    = Selector (msg -> SubjectId -> Maybe result)


{-| Create a new advanced subject.
-}
subject : SystemContext a msg -> Procedure.Procedure Never (Subject a) msg
subject ctx =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( newSystem, sid ) =
                            Runtime.createSubject system
                    in
                    ( newSystem, msgToCmd (tagger (Subject sid)) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Send a message to an advanced subject. Stores the message and fires
a port notification for subscribers.
-}
send : SystemContext a msg -> Subject a -> a -> Procedure.Procedure Never () msg
send ctx (Subject sid) a =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( newSystem, messageId ) =
                            Runtime.storeMessage sid a system
                    in
                    ( newSystem
                    , Cmd.batch
                        [ Actor.Ports.notifyP2PSend
                            { subjectId = sid, messageId = messageId }
                        , msgToCmd (tagger ())
                        ]
                    )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Send a keyed message to an advanced subject.
-}
sendKeyed : SystemContext a msg -> Subject a -> Key -> a -> Procedure.Procedure Never () msg
sendKeyed ctx subj _ a =
    send ctx subj a


{-| Resend a message marked as a possible duplicate.
-}
resendAsPossibleDuplicate : SystemContext a msg -> Subject a -> Key -> a -> Procedure.Procedure Never () msg
resendAsPossibleDuplicate ctx subj _ a =
    send ctx subj a


{-| Create a selector that accepts messages from a specific subject.
-}
fromSubject : Subject a -> Selector a a
fromSubject (Subject sid) =
    Selector
        (\msg sourceSubject ->
            if sourceSubject == sid then
                Just msg

            else
                Nothing
        )


{-| Create a base selector.
-}
selector : Selector msg msg
selector =
    Selector (\msg _ -> Just msg)


{-| Add a subject source to a selector with a transformation.
-}
selectMap : Subject a -> (a -> result) -> Selector a result -> Selector a result
selectMap (Subject sid) transform (Selector sel) =
    Selector
        (\msg sourceSubject ->
            if sourceSubject == sid then
                Just (transform msg)

            else
                sel msg sourceSubject
        )


{-| Transform selector results.
-}
map : (result -> result2) -> Selector msg result -> Selector msg result2
map f (Selector sel) =
    Selector (\msg sid -> Maybe.map f (sel msg sid))


{-| Filter selector results.
-}
filter : (result -> Bool) -> Selector msg result -> Selector msg result
filter pred (Selector sel) =
    Selector
        (\msg sid ->
            sel msg sid
                |> Maybe.andThen
                    (\result ->
                        if pred result then
                            Just result

                        else
                            Nothing
                    )
        )


{-| Combine two selectors.
-}
orElse : Selector msg result -> Selector msg result -> Selector msg result
orElse (Selector left) (Selector right) =
    Selector
        (\msg sid ->
            case left msg sid of
                Just result ->
                    Just result

                Nothing ->
                    right msg sid
        )


{-| One-shot select from message store.
-}
select : SystemContext a msg -> Selector a result -> Procedure.Procedure Never (Maybe result) msg
select ctx (Selector sel) =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        result =
                            system
                                |> Runtime.messageStoreValues
                                |> List.filterMap
                                    (\entry -> sel entry.message entry.subjectId)
                                |> List.head
                    in
                    ( system, msgToCmd (tagger result) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Subscribe to messages matching a selector. Returns a real Elm Sub
via port-bounce.
-}
subscribe : ActorSystem a -> Selector a result -> Sub (Maybe result)
subscribe system (Selector sel) =
    Actor.Ports.onP2PSend
        (\{ messageId } ->
            case Runtime.lookupMessage messageId system of
                Just entry ->
                    sel entry.message entry.subjectId

                Nothing ->
                    Nothing
        )
