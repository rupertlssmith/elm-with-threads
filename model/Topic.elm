module Actor.Topic exposing
    ( Key
    , Group
    , Partition
    , Offset
    , Topic
    , Consumer
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

import Debug
import Platform.Sub exposing (Sub)
import Task exposing (Task)


-- DURABLE, PARTITIONED TOPICS (KAFKA-LIKE, NORMAL LAYER)


type alias Key =
    String


type alias Group =
    String


type alias Partition =
    Int


type alias Offset =
    Int


-- A durable, partitioned log of messages of type `a`.
type Topic a
    = Topic


-- A consumer handle representing membership in a consumer group for a topic.
type Consumer a
    = Consumer



-- TOPIC CREATION & PUBLISHING


{-| Create a new durable topic with the specified number of partitions.

The implementation decides where and how the log is stored (in-memory,
on disk, etc.). The important contracts are:

  * Messages are appended to a partition's log.
  * Offsets are monotonic per partition.
-}
topic :
    { partitions : Int }
    -> Task x (Topic a)
topic =
    Debug.todo "topic"


{-| Publish a message to the topic.

Partition selection is implementation-defined (e.g. round-robin) if
no key is provided. Returns when the message has been appended.
-}
publish :
    Topic a
    -> a
    -> Task x ()
publish =
    Debug.todo "publish"


{-| Publish a keyed message to the topic.

Partition is chosen as `hash(key) mod numPartitions`, and ordering
is guaranteed per key within a given partition.
-}
publishKeyed :
    Topic a
    -> Key
    -> a
    -> Task x ()
publishKeyed =
    Debug.todo "publishKeyed"


{-| Publish using a function that derives a key from the payload.

Convenience wrapper for `publishKeyed`:

    publishWithPartitionKey f topic payload
    == publishKeyed topic (f payload) payload
-}
publishWithPartitionKey :
    (a -> Key)
    -> Topic a
    -> a
    -> Task x ()
publishWithPartitionKey =
    Debug.todo "publishWithPartitionKey"



-- CONSUMPTION (CONSUMER GROUPS)


{-| Subscribe a consumer group to a topic.

All consumers with the same `Group` name form a group. Partitions
are distributed across group members; each partition is consumed by
exactly one group member at a time.

For each message consumed by this group member, `toMsg` is called to
produce the program's `parentMsg`.
-}
subscribeGroup :
    Topic a
    -> Group
    -> (a -> parentMsg)
    -> Sub parentMsg
subscribeGroup =
    Debug.todo "subscribeGroup"


{-| Create a handle for a consumer in a group.

This can be used to control offsets (seek/replay). The returned
Consumer is tied to a specific topic and group.
-}
consumer :
    Topic a
    -> Group
    -> Task x (Consumer a)
consumer =
    Debug.todo "consumer"



-- PULL-BASED CONSUMPTION (POLL / COMMIT)


{-| Poll for new messages from a consumer.

Returns a batch of messages starting from the consumer's current offset.
Advances the consumer's position past the returned messages.
-}
poll :
    Consumer a
    -> Task x (List a)
poll =
    Debug.todo "poll"


{-| Commit the consumer's current offset.

Marks all messages up to the current position as processed. On restart,
consumption resumes from the committed offset.
-}
commit :
    Consumer a
    -> Task x ()
commit =
    Debug.todo "commit"



-- OFFSET CONTROL (REPLAY / SEEK)


{-| Seek this consumer's position to the beginning of all assigned partitions.

Subsequent messages delivered via `subscribeGroup` for this consumer
group member will start from the earliest available offsets.
-}
seekToBeginning :
    Consumer a
    -> Task x ()
seekToBeginning =
    Debug.todo "seekToBeginning"


{-| Seek this consumer's position to the end of all assigned partitions.

Subsequent messages delivered via `subscribeGroup` for this consumer
group member will only include new messages published after the seek.
-}
seekToEnd :
    Consumer a
    -> Task x ()
seekToEnd =
    Debug.todo "seekToEnd"


{-| Seek this consumer's position to a specific offset in a specific partition.

Semantics:

  * If the consumer does not own the partition (in the current rebalance),
    the implementation may fail or defer the seek until it owns it.
  * Offsets are topic/partition-specific; the implementation enforces that.
-}
seekToOffset :
    Consumer a
    -> Partition
    -> Offset
    -> Task x ()
seekToOffset =
    Debug.todo "seekToOffset"
