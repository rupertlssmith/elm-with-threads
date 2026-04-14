module Actor.P2P exposing
    ( Subject
    , Selector
    , Key
    , subject
    , send
    , sendKeyed
    , all
    , selector
    , selectMap
    , map
    , filter
    , orElse
    , withTimeout
    , select
    , subscribe
    )

{-| Point-to-point messaging between actors via subjects and selectors.

Send operations use elm-procedure for async composition.
Subscribe returns a real Elm Sub via port-bounce: each send fires a port
notification, JS echoes it back, and the subscribe Sub picks it up.

Selectors have two type parameters: `msg` is the input message type,
`a` is the output type after transformation.

Subjects carry a codec for encoding/decoding between the payload type `a`
and the system message type `msg`.

@docs Subject, Selector, Key
@docs subject, send, sendKeyed
@docs all, selector, selectMap, map, filter, orElse, withTimeout
@docs select, subscribe

-}

import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext, msgToCmd)
import Actor.Internal.Types exposing (SubjectId)
import Actor.Ports
import Procedure


{-| A subject is a named mailbox owned by a process. Other actors send messages
to a subject; the owning process receives them.

`msg` is the system message type, `a` is the payload type.
The subject carries an encoder `(a -> msg)` and decoder `(msg -> Maybe a)`.
-}
type Subject msg a
    = Subject SubjectId (a -> msg) (msg -> Maybe a)


{-| A selector matches incoming messages and transforms them.
`msg` is the message type being matched, `a` is the output type.
-}
type Selector msg a
    = Selector (msg -> SubjectId -> Maybe a)


{-| A routing key for keyed sends.
-}
type alias Key =
    String


{-| Create a new subject with an encoder/decoder codec.
-}
subject : SystemContext msg parentMsg -> (a -> msg) -> (msg -> Maybe a) -> Procedure.Procedure Never (Subject msg a) parentMsg
subject ctx encode decode =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( newSystem, sid ) =
                            Runtime.createSubject system
                    in
                    ( newSystem, msgToCmd (tagger (Subject sid encode decode)) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Send a message to a subject. Encodes the payload, stores it in the
message store, and fires a port notification. Subscribers are woken via
the port-bounce echo.
-}
send : SystemContext msg parentMsg -> Subject msg a -> a -> Procedure.Procedure Never () parentMsg
send ctx (Subject sid encode _) value =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( newSystem, messageId ) =
                            Runtime.storeMessage sid (encode value) system
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
sendKeyed : SystemContext msg parentMsg -> Subject msg a -> Key -> a -> Procedure.Procedure Never () parentMsg
sendKeyed ctx subj _ a =
    send ctx subj a


{-| Create a selector that accepts messages from a specific subject.
Uses the subject's decoder to extract the payload.
-}
all : Subject msg a -> Selector msg a
all (Subject sid _ decode) =
    Selector
        (\sysMsg sourceSubject ->
            if sourceSubject == sid then
                decode sysMsg

            else
                Nothing
        )


{-| Create a base selector that matches any message.
-}
selector : Selector msg msg
selector =
    Selector (\msg _ -> Just msg)


{-| Add a subject source to a selector with a transformation function.
Decodes the payload from the subject, applies the transform, and feeds
the result through the inner selector.
-}
selectMap : Subject msg a -> (a -> msg) -> Selector msg b -> Selector msg b
selectMap (Subject sid _ decode) transform (Selector sel) =
    Selector
        (\incomingMsg sourceSubject ->
            if sourceSubject == sid then
                case decode incomingMsg of
                    Just aValue ->
                        sel (transform aValue) sourceSubject

                    Nothing ->
                        sel incomingMsg sourceSubject

            else
                sel incomingMsg sourceSubject
        )


{-| Transform the result of a selector.
-}
map : (a -> b) -> Selector msg a -> Selector msg b
map f (Selector sel) =
    Selector (\msg sid -> Maybe.map f (sel msg sid))


{-| Filter selector results by a predicate.
-}
filter : (a -> Bool) -> Selector msg a -> Selector msg a
filter pred (Selector sel) =
    Selector
        (\msg sid ->
            sel msg sid
                |> Maybe.andThen
                    (\val ->
                        if pred val then
                            Just val

                        else
                            Nothing
                    )
        )


{-| Combine two selectors — try the first, fall back to the second.
-}
orElse : Selector msg a -> Selector msg a -> Selector msg a
orElse (Selector left) (Selector right) =
    Selector
        (\msg sid ->
            case left msg sid of
                Just val ->
                    Just val

                Nothing ->
                    right msg sid
        )


{-| Add a timeout with a default value to a selector.
In this simulation, timeouts are not enforced — the default is ignored.
-}
withTimeout : Float -> a -> Selector msg a -> Selector msg a
withTimeout _ _ sel =
    sel


{-| One-shot select: scan the message store for the first matching message.
-}
select : SystemContext msg parentMsg -> Selector msg a -> Procedure.Procedure Never (Maybe a) parentMsg
select ctx (Selector sel) =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        matched =
                            system
                                |> Runtime.messageStoreValues
                                |> List.filterMap
                                    (\entry -> sel entry.message entry.subjectId)
                                |> List.head
                    in
                    ( system, msgToCmd (tagger matched) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Subscribe to messages matching a selector. Returns a real Elm Sub
via port-bounce. Each send fires a port notification that bounces back
through JS; this Sub picks up matching messages from the store.
-}
subscribe : ActorSystem msg -> Selector msg a -> Sub (Maybe a)
subscribe system (Selector sel) =
    Actor.Ports.onP2PSend
        (\{ messageId } ->
            case Runtime.lookupMessage messageId system of
                Just entry ->
                    sel entry.message entry.subjectId

                Nothing ->
                    Nothing
        )
