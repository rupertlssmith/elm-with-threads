module Actor.Channel exposing
    ( Channel
    , OneToOne
    , Broadcast
    , Selector
    , oneToOne
    , broadcast
    , send
    , publish
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

{-| Unified channel for both point-to-point and broadcast messaging.

Channels create a subject ID, store messages, and use port-bounce for delivery.
The phantom type parameter `c` distinguishes delivery semantics:

  - `OneToOne` — point-to-point messaging (one consumer)
  - `Broadcast` — pub/sub messaging (all consumers)

Send/publish operations return an `Actor.Task.Task` that internally threads
the `SystemContext` so call sites don't have to.

Subscribe returns a real Elm Sub via port-bounce: each send fires a port
notification, JS echoes it back, and the subscribe Sub picks it up.

Selectors have two type parameters: `msg` is the input message type,
`a` is the output type after transformation.

Channels carry a codec for encoding/decoding between the payload type `a`
and the system message type `msg`.

@docs Channel, OneToOne, Broadcast, Selector
@docs oneToOne, broadcast, send, publish
@docs all, selector, selectMap, map, filter, orElse, withTimeout
@docs select, subscribe

-}

import Actor.Internal.Runtime as Runtime exposing (ActorSystem, msgToCmd)
import Actor.Internal.Types exposing (SubjectId)
import Actor.Ports
import Actor.Task as Task exposing (Task)
import Procedure


{-| Phantom type for point-to-point channels.
-}
type OneToOne
    = OneToOne


{-| Phantom type for broadcast channels.
-}
type Broadcast
    = Broadcast


{-| A channel is a named mailbox. The phantom type `c` distinguishes
point-to-point (`OneToOne`) from broadcast (`Broadcast`) semantics.

`msg` is the system message type, `a` is the payload type.
The channel carries an encoder `(a -> msg)` and decoder `(msg -> Maybe a)`.
-}
type Channel msg c a
    = Channel SubjectId (a -> msg) (msg -> Maybe a)


{-| A selector matches incoming messages and transforms them.
`msg` is the message type being matched, `a` is the output type.
-}
type Selector msg a
    = Selector (msg -> SubjectId -> Maybe a)


{-| Create a new point-to-point channel with an encoder/decoder codec.
-}
oneToOne : (a -> msg) -> (msg -> Maybe a) -> Task msg parentMsg err (Channel msg OneToOne a)
oneToOne encode decode =
    Task.fromContext
        (\ctx ->
            Procedure.fetch
                (\tagger ->
                    let
                        op system =
                            let
                                ( newSystem, sid ) =
                                    Runtime.createSubject system
                            in
                            ( newSystem, msgToCmd (tagger (Channel sid encode decode)) )
                    in
                    msgToCmd (ctx.runOp op)
                )
        )


{-| Create a new broadcast channel with an encoder/decoder codec.
-}
broadcast : (a -> msg) -> (msg -> Maybe a) -> Task msg parentMsg err (Channel msg Broadcast a)
broadcast encode decode =
    Task.fromContext
        (\ctx ->
            Procedure.fetch
                (\tagger ->
                    let
                        op system =
                            let
                                ( newSystem, sid ) =
                                    Runtime.createSubject system
                            in
                            ( newSystem, msgToCmd (tagger (Channel sid encode decode)) )
                    in
                    msgToCmd (ctx.runOp op)
                )
        )


{-| Send a message to a point-to-point channel. Encodes the payload, stores it
in the message store, and fires a port notification. Subscribers are woken via
the port-bounce echo.
-}
send : Channel msg OneToOne a -> a -> Task msg parentMsg err ()
send (Channel sid encode _) value =
    Task.fromContext
        (\ctx ->
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
        )


{-| Publish a message to a broadcast channel. Encodes the payload, stores it
in the message store, and fires a port notification. All subscribers receive
the message via port-bounce.
-}
publish : Channel msg Broadcast a -> a -> Task msg parentMsg err ()
publish (Channel sid encode _) value =
    Task.fromContext
        (\ctx ->
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
        )


{-| Create a selector that accepts messages from a specific channel.
Uses the channel's decoder to extract the payload.
-}
all : Channel msg c a -> Selector msg a
all (Channel sid _ decode) =
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


{-| Add a channel source to a selector with a transformation function.
Decodes the payload from the channel, applies the transform, and feeds
the result through the inner selector.
-}
selectMap : Channel msg c a -> (a -> msg) -> Selector msg b -> Selector msg b
selectMap (Channel sid _ decode) transform (Selector sel) =
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
select : Selector msg a -> Task msg parentMsg err (Maybe a)
select (Selector sel) =
    Task.fromContext
        (\ctx ->
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
