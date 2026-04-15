module Actor.PubSub exposing
    ( Topic
    , topic
    , publish
    , subscribe
    )

{-| Fire-and-forget pub/sub topics, using elm-procedure for async composition.

Unlike Kafka-style topics (Actor.Topic), pub/sub topics have no partitions,
consumer groups, or offset tracking. Every subscriber receives every message.

Subscribe returns a real Elm Sub via port-bounce.

Topics carry a codec for encoding/decoding between the payload type `a`
and the system message type `msg`.

@docs Topic
@docs topic, publish, subscribe

-}

import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext, msgToCmd)
import Actor.Internal.Types exposing (SubjectId)
import Actor.Ports
import Procedure


{-| An opaque handle to a pub/sub topic.

`msg` is the system message type, `a` is the payload type.
-}
type Topic msg a
    = Topic SubjectId (a -> msg) (msg -> Maybe a)


{-| Create a new pub/sub topic with an encoder/decoder codec.
-}
topic : SystemContext msg parentMsg -> (a -> msg) -> (msg -> Maybe a) -> Procedure.Procedure Never (Topic msg a) parentMsg
topic ctx encode decode =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( newSystem, sid ) =
                            Runtime.createSubject system
                    in
                    ( newSystem, msgToCmd (tagger (Topic sid encode decode)) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Publish a message to a pub/sub topic.
Encodes the payload before storing.
-}
publish : SystemContext msg parentMsg -> Topic msg a -> a -> Procedure.Procedure Never () parentMsg
publish ctx (Topic sid encode _) value =
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


{-| Subscribe to all messages on a pub/sub topic.
Returns a real Elm Sub via port-bounce.
Uses the topic's decoder to extract the payload.
-}
subscribe : ActorSystem msg -> Topic msg a -> Sub (Maybe a)
subscribe system (Topic sid _ decode) =
    Actor.Ports.onP2PSend
        (\{ subjectId, messageId } ->
            if subjectId == sid then
                case Runtime.lookupMessage messageId system of
                    Just entry ->
                        decode entry.message

                    Nothing ->
                        Nothing

            else
                Nothing
        )
