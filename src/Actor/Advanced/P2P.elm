module Actor.Advanced.P2P exposing
    ( Subject
    , Selector
    , Key
    , Meta
    , Envelope
    , subject
    , send
    , resendAsPossibleDuplicate
    , all
    , selector
    , selectMap
    , map
    , filter
    , orElse
    , withTimeout
    , select
    , selectWithMeta
    , subscribe
    , subscribeWithMeta
    )

{-| Enriched P2P messaging with metadata envelopes.

Send operations use elm-procedure for async composition.
Subscribe returns a real Elm Sub via port-bounce.

Selectors have two type parameters: `msg` is the input message type,
`a` is the output type after transformation.

Subjects carry a codec for encoding/decoding between the payload type `a`
and the system message type `msg`.

@docs Subject, Selector, Key, Meta, Envelope
@docs subject, send, resendAsPossibleDuplicate
@docs all, selector, selectMap, map, filter, orElse, withTimeout
@docs select, selectWithMeta, subscribe, subscribeWithMeta

-}

import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext, msgToCmd)
import Actor.Internal.Types exposing (SubjectId)
import Actor.Ports
import Procedure


{-| An advanced subject wraps a subject id with an encoder/decoder codec.

`msg` is the system message type, `a` is the payload type.
-}
type Subject msg a
    = Subject SubjectId (a -> msg) (msg -> Maybe a)


{-| A selector for advanced P2P with metadata.
`msg` is the input message type, `a` is the output type.
-}
type Selector msg a
    = Selector (msg -> SubjectId -> Maybe a)


type alias Key =
    String


{-| Metadata attached to each message.
-}
type alias Meta =
    { key : Maybe Key
    , possibleDuplicate : Bool
    , sequence : Maybe Int
    }


{-| A message wrapped with metadata.
-}
type alias Envelope a =
    { meta : Meta
    , payload : a
    }


{-| Create a new advanced subject with an encoder/decoder codec.
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


{-| Send a message to an advanced subject. Encodes the payload, stores it,
and fires a port notification for subscribers.
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


{-| Resend a message marked as a possible duplicate.
-}
resendAsPossibleDuplicate : SystemContext msg parentMsg -> Subject msg a -> Key -> a -> Procedure.Procedure Never () parentMsg
resendAsPossibleDuplicate ctx subj _ a =
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


{-| Create a base selector.
-}
selector : Selector msg msg
selector =
    Selector (\msg _ -> Just msg)


{-| Add a subject source to a selector with a transformation.
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


{-| Transform selector results.
-}
map : (a -> b) -> Selector msg a -> Selector msg b
map f (Selector sel) =
    Selector (\msg sid -> Maybe.map f (sel msg sid))


{-| Filter selector results.
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


{-| Combine two selectors.
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


{-| One-shot select from message store.
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


{-| One-shot select using a meta-aware selector.
The selector operates on `( Meta, msg )` tuples.
In this simulation, default metadata is provided.
-}
selectWithMeta : SystemContext msg parentMsg -> Selector ( Meta, msg ) a -> Procedure.Procedure Never (Maybe a) parentMsg
selectWithMeta ctx (Selector sel) =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        defaultMeta =
                            { key = Nothing
                            , possibleDuplicate = False
                            , sequence = Nothing
                            }

                        matched =
                            system
                                |> Runtime.messageStoreValues
                                |> List.filterMap
                                    (\entry -> sel ( defaultMeta, entry.message ) entry.subjectId)
                                |> List.head
                    in
                    ( system, msgToCmd (tagger matched) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Subscribe to messages matching a selector. Returns a real Elm Sub
via port-bounce.
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


{-| Subscribe using a meta-aware selector. Returns a real Elm Sub via port-bounce.
In this simulation, default metadata is provided.
-}
subscribeWithMeta : ActorSystem msg -> Selector ( Meta, msg ) a -> Sub (Maybe a)
subscribeWithMeta system (Selector sel) =
    let
        defaultMeta =
            { key = Nothing
            , possibleDuplicate = False
            , sequence = Nothing
            }
    in
    Actor.Ports.onP2PSend
        (\{ messageId } ->
            case Runtime.lookupMessage messageId system of
                Just entry ->
                    sel ( defaultMeta, entry.message ) entry.subjectId

                Nothing ->
                    Nothing
        )
