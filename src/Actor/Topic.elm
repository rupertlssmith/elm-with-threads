module Actor.Topic exposing
    ( Topic
    , Consumer
    , ConsumerRecord
    , Selector
    , Key
    , Group
    , Partition
    , Offset
    , createTopic
    , send
    , sendKeyed
    , consumer
    , close
    , poll
    , commit
    , seekToBeginning
    , seekToEnd
    , seek
    , all
    , selector
    , selectMap
    , map
    , filter
    , subscribe
    )

{-| Kafka-style partitioned log topics with consumer groups and selectors.

Each operation returns an `Actor.Task.Task` that internally threads the
`SystemContext` so call sites don't have to.

Topics and consumers carry a codec for encoding/decoding between
the payload type `a` and the system message type `msg`.

Selectors allow type-safe consumption from multiple topics with
filtering and type translation, following the same pattern as
Channel.Selector.

Publishing uses port-bounce so that subscribe-based consumers
receive messages reactively.

@docs Topic, Consumer, ConsumerRecord, Selector
@docs Key, Group, Partition, Offset
@docs createTopic, send, sendKeyed
@docs consumer, close, poll, commit
@docs seekToBeginning, seekToEnd, seek
@docs all, selector, selectMap, map, filter, subscribe

-}

import Actor.Internal.Runtime as Runtime exposing (ActorSystem, TopicMessageMeta, msgToCmd)
import Actor.Internal.Types exposing (ConsumerId, SubjectId, TopicId)
import Actor.Ports
import Actor.Task as Task exposing (Task)
import Procedure


{-| An opaque handle to a topic.

`msg` is the system message type, `a` is the payload type.
-}
type Topic msg a
    = Topic TopicId SubjectId (a -> msg) (msg -> Maybe a)


{-| An opaque handle to a consumer within a consumer group.

`msg` is the system message type, `a` is the payload type.
-}
type Consumer msg a
    = Consumer TopicId ConsumerId SubjectId (a -> msg) (msg -> Maybe a)


{-| A record returned by poll, containing the value along with
partition, offset, and key metadata.
-}
type alias ConsumerRecord a =
    { value : a
    , key : Maybe Key
    , partition : Partition
    , offset : Offset
    }


{-| A selector matches incoming topic messages and transforms them.
`msg` is the system message type, `a` is the output type after transformation.

Selectors are used with `subscribe` for reactive consumption from
one or more topics with type translation and filtering.
-}
type Selector msg a
    = Selector (msg -> SubjectId -> Maybe TopicMessageMeta -> Maybe a)


type alias Key =
    String


type alias Group =
    String


type alias Partition =
    Int


type alias Offset =
    Int



-- TOPIC MANAGEMENT


{-| Create a new topic with a name and partition count,
plus an encoder/decoder codec.
-}
createTopic : (a -> msg) -> (msg -> Maybe a) -> { name : String, partitions : Int } -> Task msg parentMsg err (Topic msg a)
createTopic encode decode config =
    Task.fromContext
        (\ctx ->
            Procedure.fetch
                (\tagger ->
                    let
                        op system =
                            let
                                ( newSystem, ( tid, sid ) ) =
                                    Runtime.createTopic config.name config.partitions system
                            in
                            ( newSystem, msgToCmd (tagger (Topic tid sid encode decode)) )
                    in
                    msgToCmd (ctx.runOp op)
                )
        )



-- PUBLISHING


{-| Send a message to a topic (round-robin partition assignment).
Encodes the payload, stores in the topic log and message store,
and fires a port notification for subscribers.
-}
send : Topic msg a -> a -> Task msg parentMsg err ()
send (Topic tid sid encode _) value =
    Task.fromContext
        (\ctx ->
            Procedure.fetch
                (\tagger ->
                    let
                        op system =
                            let
                                encoded =
                                    encode value

                                ( s1, pubMeta ) =
                                    Runtime.publishToTopic tid encoded system

                                ( s2, messageId ) =
                                    Runtime.storeMessage sid encoded s1

                                s3 =
                                    Runtime.storeTopicMeta messageId
                                        { partition = pubMeta.partition, offset = pubMeta.offset, key = Nothing }
                                        s2
                            in
                            ( s3
                            , Cmd.batch
                                [ Actor.Ports.notifyP2PSend { subjectId = sid, messageId = messageId }
                                , msgToCmd (tagger ())
                                ]
                            )
                    in
                    msgToCmd (ctx.runOp op)
                )
        )


{-| Send a keyed message to a topic (key determines partition).
Messages with the same key always land on the same partition,
preserving ordering for that key.
-}
sendKeyed : Topic msg a -> Key -> a -> Task msg parentMsg err ()
sendKeyed (Topic tid sid encode _) key value =
    Task.fromContext
        (\ctx ->
            Procedure.fetch
                (\tagger ->
                    let
                        op system =
                            let
                                encoded =
                                    encode value

                                ( s1, pubMeta ) =
                                    Runtime.publishKeyedToTopic tid key encoded system

                                ( s2, messageId ) =
                                    Runtime.storeMessage sid encoded s1

                                s3 =
                                    Runtime.storeTopicMeta messageId
                                        { partition = pubMeta.partition, offset = pubMeta.offset, key = Just key }
                                        s2
                            in
                            ( s3
                            , Cmd.batch
                                [ Actor.Ports.notifyP2PSend { subjectId = sid, messageId = messageId }
                                , msgToCmd (tagger ())
                                ]
                            )
                    in
                    msgToCmd (ctx.runOp op)
                )
        )



-- CONSUMER LIFECYCLE


{-| Create a consumer for a topic within a consumer group.
The consumer inherits the codec from the topic.
-}
consumer : Topic msg a -> Group -> Task msg parentMsg err (Consumer msg a)
consumer (Topic tid sid encode decode) groupId =
    Task.fromContext
        (\ctx ->
            Procedure.fetch
                (\tagger ->
                    let
                        op system =
                            let
                                ( newSystem, ( topicId, consumerId ) ) =
                                    Runtime.createConsumer tid groupId system
                            in
                            ( newSystem, msgToCmd (tagger (Consumer topicId consumerId sid encode decode)) )
                    in
                    msgToCmd (ctx.runOp op)
                )
        )


{-| Close a consumer, removing it from the consumer group.
-}
close : Consumer msg a -> Task msg parentMsg err ()
close (Consumer tid cid _ _ _) =
    Task.fromContext
        (\ctx ->
            Procedure.fetch
                (\tagger ->
                    let
                        op system =
                            ( Runtime.removeConsumer tid cid system
                            , msgToCmd (tagger ())
                            )
                    in
                    msgToCmd (ctx.runOp op)
                )
        )


{-| Commit the consumer's current offset (marks messages as processed).
-}
commit : Consumer msg a -> Task msg parentMsg err ()
commit (Consumer tid cid _ _ _) =
    Task.fromContext
        (\ctx ->
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
        )


{-| Seek the consumer to the beginning of all partitions.
-}
seekToBeginning : Consumer msg a -> Task msg parentMsg err ()
seekToBeginning (Consumer tid cid _ _ _) =
    Task.fromContext
        (\ctx ->
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
        )


{-| Seek the consumer to the end of all partitions.
-}
seekToEnd : Consumer msg a -> Task msg parentMsg err ()
seekToEnd (Consumer tid cid _ _ _) =
    Task.fromContext
        (\ctx ->
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
        )


{-| Seek the consumer to a specific offset on a specific partition.
-}
seek : Consumer msg a -> Partition -> Offset -> Task msg parentMsg err ()
seek (Consumer tid cid _ _ _) partition offset =
    Task.fromContext
        (\ctx ->
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
        )



-- POLLING


{-| Poll for new messages from a consumer. Advances the consumer's current offset.
Returns ConsumerRecords with value, key, partition, and offset metadata.
-}
poll : Consumer msg a -> Task msg parentMsg err (List (ConsumerRecord a))
poll (Consumer tid cid _ _ decode) =
    Task.fromContext
        (\ctx ->
            Procedure.fetch
                (\tagger ->
                    let
                        op system =
                            let
                                ( newSystem, results ) =
                                    Runtime.pollConsumer tid cid system

                                records =
                                    List.filterMap
                                        (\r ->
                                            decode r.message
                                                |> Maybe.map
                                                    (\value ->
                                                        { value = value
                                                        , key = r.key
                                                        , partition = r.partition
                                                        , offset = r.offset
                                                        }
                                                    )
                                        )
                                        results
                            in
                            ( newSystem, msgToCmd (tagger records) )
                    in
                    msgToCmd (ctx.runOp op)
                )
        )



-- SELECTORS


{-| Create a selector that passes through all ConsumerRecords from a consumer.
Analogous to Channel.all.
-}
all : Consumer msg a -> Selector msg (ConsumerRecord a)
all (Consumer _ _ topicSid _ decode) =
    Selector
        (\rawMsg sourceSubject maybeMeta ->
            if sourceSubject == topicSid then
                case ( decode rawMsg, maybeMeta ) of
                    ( Just value, Just meta ) ->
                        Just
                            { value = value
                            , key = meta.key
                            , partition = meta.partition
                            , offset = meta.offset
                            }

                    _ ->
                        Nothing

            else
                Nothing
        )


{-| Create a base selector that matches any message.
-}
selector : Selector msg msg
selector =
    Selector (\msg _ _ -> Just msg)


{-| Add a consumer source to a selector with a transformation function.
Decodes ConsumerRecords from the consumer, applies the transform, and
feeds the result through the inner selector.

This is how multiple typed topics are unified into a single Selector
with type translation — publishers to each topic don't know about
the consumer's message type.
-}
selectMap : Consumer msg a -> (ConsumerRecord a -> msg) -> Selector msg b -> Selector msg b
selectMap (Consumer _ _ topicSid _ decode) transform (Selector sel) =
    Selector
        (\rawMsg sourceSubject maybeMeta ->
            if sourceSubject == topicSid then
                case ( decode rawMsg, maybeMeta ) of
                    ( Just value, Just meta ) ->
                        let
                            record =
                                { value = value
                                , key = meta.key
                                , partition = meta.partition
                                , offset = meta.offset
                                }
                        in
                        sel (transform record) sourceSubject maybeMeta

                    _ ->
                        sel rawMsg sourceSubject maybeMeta

            else
                sel rawMsg sourceSubject maybeMeta
        )


{-| Transform the result of a selector.
-}
map : (a -> b) -> Selector msg a -> Selector msg b
map f (Selector sel) =
    Selector (\msg sid meta -> Maybe.map f (sel msg sid meta))


{-| Filter selector results by a predicate.
-}
filter : (a -> Bool) -> Selector msg a -> Selector msg a
filter pred (Selector sel) =
    Selector
        (\msg sid meta ->
            sel msg sid meta
                |> Maybe.andThen
                    (\val ->
                        if pred val then
                            Just val

                        else
                            Nothing
                    )
        )



-- SUBSCRIBING


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
                    sel entry.message entry.subjectId (Runtime.lookupTopicMeta messageId system)

                Nothing ->
                    Nothing
        )
