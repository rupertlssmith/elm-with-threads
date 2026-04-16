module Actor.Internal.TopicStore exposing
    ( TopicEntry
    , ConsumerEntry
    , PollResult
    , initTopic
    , publish
    , publishToPartition
    , poll
    , commit
    , seekToBeginning
    , seekToEnd
    , seekToOffset
    , initConsumer
    , removeConsumer
    , partitionForKey
    )

{-| In-memory partitioned log storage with consumer groups.

Messages are stored with optional keys for partition routing.
Poll returns metadata (partition, offset, key) alongside each message.
-}

import Actor.Internal.Types exposing (ConsumerId, Key, Offset, PartitionIndex, SubjectId, TopicId)
import Array exposing (Array)
import Dict exposing (Dict)


type alias StoredMessage appMsg =
    { message : appMsg
    , key : Maybe Key
    }


type alias PollResult appMsg =
    { message : appMsg
    , key : Maybe Key
    , partition : PartitionIndex
    , offset : Offset
    }


type alias TopicEntry appMsg =
    { id : TopicId
    , subjectId : SubjectId
    , numPartitions : Int
    , partitions : Dict PartitionIndex (Array (StoredMessage appMsg))
    , nextConsumerId : ConsumerId
    , consumers : Dict ConsumerId ConsumerEntry
    }


type alias ConsumerEntry =
    { id : ConsumerId
    , groupId : String
    , currentOffsets : Dict PartitionIndex Offset
    , committedOffsets : Dict PartitionIndex Offset
    }


initTopic : TopicId -> SubjectId -> Int -> TopicEntry appMsg
initTopic tid sid numPartitions =
    { id = tid
    , subjectId = sid
    , numPartitions = numPartitions
    , partitions =
        List.range 0 (numPartitions - 1)
            |> List.map (\i -> ( i, Array.empty ))
            |> Dict.fromList
    , nextConsumerId = 0
    , consumers = Dict.empty
    }


publish : appMsg -> TopicEntry appMsg -> ( TopicEntry appMsg, { partition : PartitionIndex, offset : Offset } )
publish msg entry =
    let
        totalMsgs =
            Dict.foldl (\_ arr acc -> acc + Array.length arr) 0 entry.partitions

        partition =
            modBy entry.numPartitions totalMsgs
    in
    publishToPartition partition Nothing msg entry


publishToPartition : PartitionIndex -> Maybe Key -> appMsg -> TopicEntry appMsg -> ( TopicEntry appMsg, { partition : PartitionIndex, offset : Offset } )
publishToPartition partition key msg entry =
    let
        currentArr =
            Dict.get partition entry.partitions
                |> Maybe.withDefault Array.empty

        offset =
            Array.length currentArr

        stored =
            { message = msg, key = key }

        updated =
            Dict.update partition
                (\maybeArr ->
                    case maybeArr of
                        Just arr ->
                            Just (Array.push stored arr)

                        Nothing ->
                            Just (Array.fromList [ stored ])
                )
                entry.partitions
    in
    ( { entry | partitions = updated }
    , { partition = partition, offset = offset }
    )


partitionForKey : Key -> Int -> PartitionIndex
partitionForKey key numPartitions =
    let
        hash =
            String.foldl (\c acc -> acc * 31 + Char.toCode c) 0 key
    in
    modBy numPartitions (abs hash)


initConsumer : String -> TopicEntry appMsg -> ( TopicEntry appMsg, ConsumerId )
initConsumer groupId entry =
    let
        cid =
            entry.nextConsumerId

        initialOffsets =
            List.range 0 (entry.numPartitions - 1)
                |> List.map (\i -> ( i, 0 ))
                |> Dict.fromList

        consumerEntry =
            { id = cid
            , groupId = groupId
            , currentOffsets = initialOffsets
            , committedOffsets = initialOffsets
            }
    in
    ( { entry
        | nextConsumerId = cid + 1
        , consumers = Dict.insert cid consumerEntry entry.consumers
      }
    , cid
    )


removeConsumer : ConsumerId -> TopicEntry appMsg -> TopicEntry appMsg
removeConsumer consumerId entry =
    { entry | consumers = Dict.remove consumerId entry.consumers }


poll : ConsumerId -> TopicEntry appMsg -> ( TopicEntry appMsg, List (PollResult appMsg) )
poll consumerId entry =
    case Dict.get consumerId entry.consumers of
        Nothing ->
            ( entry, [] )

        Just consumer ->
            let
                ( newOffsets, results ) =
                    Dict.foldl
                        (\partition arr ( offAcc, resAcc ) ->
                            let
                                currentOffset =
                                    Dict.get partition consumer.currentOffsets
                                        |> Maybe.withDefault 0

                                partitionResults =
                                    Array.toList (Array.slice currentOffset (Array.length arr) arr)
                                        |> List.indexedMap
                                            (\i stored ->
                                                { message = stored.message
                                                , key = stored.key
                                                , partition = partition
                                                , offset = currentOffset + i
                                                }
                                            )

                                newOffset =
                                    Array.length arr
                            in
                            ( Dict.insert partition newOffset offAcc
                            , resAcc ++ partitionResults
                            )
                        )
                        ( consumer.currentOffsets, [] )
                        entry.partitions

                updatedConsumer =
                    { consumer | currentOffsets = newOffsets }
            in
            ( { entry | consumers = Dict.insert consumerId updatedConsumer entry.consumers }
            , results
            )


commit : ConsumerId -> TopicEntry appMsg -> TopicEntry appMsg
commit consumerId entry =
    case Dict.get consumerId entry.consumers of
        Nothing ->
            entry

        Just consumer ->
            let
                updatedConsumer =
                    { consumer | committedOffsets = consumer.currentOffsets }
            in
            { entry | consumers = Dict.insert consumerId updatedConsumer entry.consumers }


seekToBeginning : ConsumerId -> TopicEntry appMsg -> TopicEntry appMsg
seekToBeginning consumerId entry =
    seekAllPartitions consumerId 0 entry


seekToEnd : ConsumerId -> TopicEntry appMsg -> TopicEntry appMsg
seekToEnd consumerId entry =
    case Dict.get consumerId entry.consumers of
        Nothing ->
            entry

        Just consumer ->
            let
                endOffsets =
                    Dict.map
                        (\partition _ ->
                            Dict.get partition entry.partitions
                                |> Maybe.map Array.length
                                |> Maybe.withDefault 0
                        )
                        consumer.currentOffsets

                updatedConsumer =
                    { consumer | currentOffsets = endOffsets }
            in
            { entry | consumers = Dict.insert consumerId updatedConsumer entry.consumers }


seekToOffset : ConsumerId -> PartitionIndex -> Offset -> TopicEntry appMsg -> TopicEntry appMsg
seekToOffset consumerId partition offset entry =
    case Dict.get consumerId entry.consumers of
        Nothing ->
            entry

        Just consumer ->
            let
                updatedConsumer =
                    { consumer
                        | currentOffsets = Dict.insert partition offset consumer.currentOffsets
                    }
            in
            { entry | consumers = Dict.insert consumerId updatedConsumer entry.consumers }


seekAllPartitions : ConsumerId -> Offset -> TopicEntry appMsg -> TopicEntry appMsg
seekAllPartitions consumerId offset entry =
    case Dict.get consumerId entry.consumers of
        Nothing ->
            entry

        Just consumer ->
            let
                newOffsets =
                    Dict.map (\_ _ -> offset) consumer.currentOffsets

                updatedConsumer =
                    { consumer | currentOffsets = newOffsets }
            in
            { entry | consumers = Dict.insert consumerId updatedConsumer entry.consumers }
