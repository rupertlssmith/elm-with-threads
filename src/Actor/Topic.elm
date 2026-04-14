module Actor.Topic exposing
    ( Topic
    , Consumer
    , Key
    , Group
    , Partition
    , Offset
    , topic
    , publish
    , publishKeyed
    , publishWithPartitionKey
    , subscribeGroup
    , consumer
    , poll
    , commit
    , seekToBeginning
    , seekToEnd
    , seekToOffset
    )

{-| Kafka-style partitioned log topics with consumer groups,
using elm-procedure for async composition.

Topics and consumers carry a codec for encoding/decoding between
the payload type `a` and the system message type `msg`.

@docs Topic, Consumer, Key, Group, Partition, Offset
@docs topic, publish, publishKeyed, publishWithPartitionKey
@docs subscribeGroup, consumer, poll, commit
@docs seekToBeginning, seekToEnd, seekToOffset

-}

import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext, msgToCmd)
import Actor.Internal.Types exposing (ConsumerId, TopicId)
import Procedure


{-| An opaque handle to a topic.

`msg` is the system message type, `a` is the payload type.
-}
type Topic msg a
    = Topic TopicId (a -> msg) (msg -> Maybe a)


{-| An opaque handle to a consumer within a consumer group.

`msg` is the system message type, `a` is the payload type.
-}
type Consumer msg a
    = Consumer TopicId ConsumerId (a -> msg) (msg -> Maybe a)


type alias Key =
    String


type alias Group =
    String


type alias Partition =
    Int


type alias Offset =
    Int


{-| Create a new topic with the specified number of partitions
and an encoder/decoder codec.
-}
topic : SystemContext msg parentMsg -> (a -> msg) -> (msg -> Maybe a) -> { partitions : Int } -> Procedure.Procedure Never (Topic msg a) parentMsg
topic ctx encode decode config =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( newSystem, tid ) =
                            Runtime.createTopic "" config.partitions system
                    in
                    ( newSystem, msgToCmd (tagger (Topic tid encode decode)) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Publish a message to a topic (round-robin partition assignment).
Encodes the payload before storing.
-}
publish : SystemContext msg parentMsg -> Topic msg a -> a -> Procedure.Procedure Never () parentMsg
publish ctx (Topic tid encode _) value =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    ( Runtime.publishToTopic tid (encode value) system
                    , msgToCmd (tagger ())
                    )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Publish a keyed message to a topic (key determines partition).
Encodes the payload before storing.
-}
publishKeyed : SystemContext msg parentMsg -> Topic msg a -> Key -> a -> Procedure.Procedure Never () parentMsg
publishKeyed ctx (Topic tid encode _) key value =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    ( Runtime.publishKeyedToTopic tid key (encode value) system
                    , msgToCmd (tagger ())
                    )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Publish using a function that derives a key from the payload.
-}
publishWithPartitionKey : SystemContext msg parentMsg -> (a -> Key) -> Topic msg a -> a -> Procedure.Procedure Never () parentMsg
publishWithPartitionKey ctx toKey tp a =
    publishKeyed ctx tp (toKey a) a


{-| Subscribe a consumer group to a topic.
In this simulation, this is a no-op — use poll/commit instead.
-}
subscribeGroup : ActorSystem msg -> Topic msg a -> Group -> Sub (Maybe a)
subscribeGroup _ _ _ =
    Sub.none


{-| Create a consumer for a topic within a consumer group.
The consumer inherits the codec from the topic.
-}
consumer : SystemContext msg parentMsg -> Topic msg a -> Group -> Procedure.Procedure Never (Consumer msg a) parentMsg
consumer ctx (Topic tid encode decode) groupId =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( newSystem, ( topicId, consumerId ) ) =
                            Runtime.createConsumer tid groupId system
                    in
                    ( newSystem, msgToCmd (tagger (Consumer topicId consumerId encode decode)) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Poll for new messages from a consumer. Advances the consumer's current offset.
Decodes each message from the system message type to the payload type.
-}
poll : SystemContext msg parentMsg -> Consumer msg a -> Procedure.Procedure Never (List a) parentMsg
poll ctx (Consumer tid cid _ decode) =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( newSystem, messages ) =
                            Runtime.pollConsumer tid cid system
                    in
                    ( newSystem, msgToCmd (tagger (List.filterMap decode messages)) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Commit the consumer's current offset (marks messages as processed).
-}
commit : SystemContext msg parentMsg -> Consumer msg a -> Procedure.Procedure Never () parentMsg
commit ctx (Consumer tid cid _ _) =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    ( Runtime.commitConsumer tid cid system
                    , msgToCmd (tagger ())
                    )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Seek the consumer to the beginning of all partitions.
-}
seekToBeginning : SystemContext msg parentMsg -> Consumer msg a -> Procedure.Procedure Never () parentMsg
seekToBeginning ctx (Consumer tid cid _ _) =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    ( Runtime.seekConsumerToBeginning tid cid system
                    , msgToCmd (tagger ())
                    )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Seek the consumer to the end of all partitions.
-}
seekToEnd : SystemContext msg parentMsg -> Consumer msg a -> Procedure.Procedure Never () parentMsg
seekToEnd ctx (Consumer tid cid _ _) =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    ( Runtime.seekConsumerToEnd tid cid system
                    , msgToCmd (tagger ())
                    )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Seek the consumer to a specific offset on a specific partition.
-}
seekToOffset : SystemContext msg parentMsg -> Consumer msg a -> Partition -> Offset -> Procedure.Procedure Never () parentMsg
seekToOffset ctx (Consumer tid cid _ _) partition offset =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    ( Runtime.seekConsumerToOffset tid cid partition offset system
                    , msgToCmd (tagger ())
                    )
            in
            msgToCmd (ctx.runOp op)
        )
