module Actor.P2P exposing
    ( Subject
    , Selector
    , Key
    , subject
    , send
    , sendKeyed
    , fromSubject
    , selector
    , selectMap
    , map
    , filter
    , orElse
    , select
    , subscribe
    )

{-| Point-to-point messaging between actors via subjects and selectors.

Send operations use elm-procedure for async composition.
Subscribe returns a real Elm Sub via port-bounce: each send fires a port
notification, JS echoes it back, and the subscribe Sub picks it up.

Selectors have two type parameters: `msg` is the input message type,
`result` is the output type after transformation.

@docs Subject, Selector, Key
@docs subject, send, sendKeyed
@docs fromSubject, selector, selectMap, map, filter, orElse
@docs select, subscribe

-}

import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext, msgToCmd)
import Actor.Internal.Types exposing (SubjectId)
import Actor.Ports
import Procedure


{-| A subject is a named mailbox owned by a process. Other actors send messages
to a subject; the owning process receives them.
-}
type Subject a
    = Subject SubjectId


{-| A selector matches incoming messages and transforms them.
`msg` is the message type being matched, `result` is the output type.
-}
type Selector msg result
    = Selector (msg -> SubjectId -> Maybe result)


{-| A routing key for keyed sends.
-}
type alias Key =
    String


{-| Create a new subject.
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


{-| Send a message to a subject. Stores the message and fires a port
notification. Subscribers are woken via the port-bounce echo.
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


{-| Send a keyed message to a subject.
-}
sendKeyed : SystemContext a msg -> Subject a -> Key -> a -> Procedure.Procedure Never () msg
sendKeyed ctx subj _ a =
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


{-| Create a base selector that matches any message.
-}
selector : Selector msg msg
selector =
    Selector (\msg _ -> Just msg)


{-| Add a subject source to a selector with a transformation function.
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


{-| Transform the result of a selector.
-}
map : (result -> result2) -> Selector msg result -> Selector msg result2
map f (Selector sel) =
    Selector (\msg sid -> Maybe.map f (sel msg sid))


{-| Filter selector results by a predicate.
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


{-| Combine two selectors — try the first, fall back to the second.
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


{-| One-shot select: scan the message store for the first matching message.
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
via port-bounce. Each send fires a port notification that bounces back
through JS; this Sub picks up matching messages from the store.
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
