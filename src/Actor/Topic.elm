module Actor.Topic exposing
    ( Topic
    , Consumer
    , Key
    , Group
    , Partition
    , Offset
    , createTopic
    , publish
    , publishKeyed
    , createConsumer
    , poll
    , commit
    , seekToBeginning
    , seekToEnd
    , seekToOffset
    )

{-| Kafka-style partitioned log topics with consumer groups,
using elm-procedure for async composition.

@docs Topic, Consumer, Key, Group, Partition, Offset
@docs createTopic, publish, publishKeyed
@docs createConsumer, poll, commit
@docs seekToBeginning, seekToEnd, seekToOffset

-}

import Actor.Internal.Runtime as Runtime exposing (ActorSystem, SystemContext, msgToCmd)
import Actor.Internal.Types exposing (ConsumerId, TopicId)
import Procedure


{-| An opaque handle to a topic.
-}
type Topic
    = Topic TopicId


{-| An opaque handle to a consumer within a consumer group.
-}
type Consumer
    = Consumer TopicId ConsumerId


type alias Key =
    String


type alias Group =
    String


type alias Partition =
    Int


type alias Offset =
    Int


{-| Create a new topic with the given name and number of partitions.
-}
createTopic : SystemContext appMsg msg -> String -> Int -> Procedure.Procedure Never Topic msg
createTopic ctx name numPartitions =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( newSystem, tid ) =
                            Runtime.createTopic name numPartitions system
                    in
                    ( newSystem, msgToCmd (tagger (Topic tid)) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Publish a message to a topic (round-robin partition assignment).
-}
publish : SystemContext appMsg msg -> Topic -> appMsg -> Procedure.Procedure Never () msg
publish ctx (Topic tid) appMsg =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    ( Runtime.publishToTopic tid appMsg system
                    , msgToCmd (tagger ())
                    )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Publish a keyed message to a topic (key determines partition).
-}
publishKeyed : SystemContext appMsg msg -> Topic -> Key -> appMsg -> Procedure.Procedure Never () msg
publishKeyed ctx (Topic tid) key appMsg =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    ( Runtime.publishKeyedToTopic tid key appMsg system
                    , msgToCmd (tagger ())
                    )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Create a consumer for a topic within a consumer group.
-}
createConsumer : SystemContext appMsg msg -> Topic -> Group -> Procedure.Procedure Never (Maybe Consumer) msg
createConsumer ctx (Topic tid) groupId =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( newSystem, maybeIds ) =
                            Runtime.createConsumer tid groupId system
                    in
                    case maybeIds of
                        Nothing ->
                            ( newSystem, msgToCmd (tagger Nothing) )

                        Just ( topicId, consumerId ) ->
                            ( newSystem, msgToCmd (tagger (Just (Consumer topicId consumerId))) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Poll for new messages from a consumer. Advances the consumer's current offset.
-}
poll : SystemContext appMsg msg -> Consumer -> Procedure.Procedure Never (List appMsg) msg
poll ctx (Consumer tid cid) =
    Procedure.fetch
        (\tagger ->
            let
                op system =
                    let
                        ( newSystem, messages ) =
                            Runtime.pollConsumer tid cid system
                    in
                    ( newSystem, msgToCmd (tagger messages) )
            in
            msgToCmd (ctx.runOp op)
        )


{-| Commit the consumer's current offset (marks messages as processed).
-}
commit : SystemContext appMsg msg -> Consumer -> Procedure.Procedure Never () msg
commit ctx (Consumer tid cid) =
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
seekToBeginning : SystemContext appMsg msg -> Consumer -> Procedure.Procedure Never () msg
seekToBeginning ctx (Consumer tid cid) =
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
seekToEnd : SystemContext appMsg msg -> Consumer -> Procedure.Procedure Never () msg
seekToEnd ctx (Consumer tid cid) =
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
seekToOffset : SystemContext appMsg msg -> Consumer -> Partition -> Offset -> Procedure.Procedure Never () msg
seekToOffset ctx (Consumer tid cid) partition offset =
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
