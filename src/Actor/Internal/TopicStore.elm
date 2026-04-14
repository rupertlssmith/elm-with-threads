module Actor.Internal.TopicStore exposing
    ( TopicEntry
    , ConsumerGroupState
    , ConsumerEntry
    , initTopic
    , publish
    , publishToPartition
    , poll
    , commit
    , seekToBeginning
    , seekToEnd
    , seekToOffset
    , initConsumer
    , partitionForKey
    )

{-| In-memory partitioned log storage with consumer groups.
-}

import Actor.Internal.Types exposing (ConsumerId, Key, Offset, PartitionIndex, TopicId)
import Array exposing (Array)
import Dict exposing (Dict)


type alias TopicEntry appMsg =
    { id : TopicId
    , numPartitions : Int
    , partitions : Dict PartitionIndex (Array appMsg)
    , nextConsumerId : ConsumerId
    , consumers : Dict ConsumerId ConsumerEntry
    }


type alias ConsumerEntry =
    { id : ConsumerId
    , groupId : String
    , currentOffsets : Dict PartitionIndex Offset
    , committedOffsets : Dict PartitionIndex Offset
    }


type alias ConsumerGroupState =
    { offsets : Dict PartitionIndex Offset
    }


initTopic : TopicId -> Int -> TopicEntry appMsg
initTopic tid numPartitions =
    { id = tid
    , numPartitions = numPartitions
    , partitions =
        List.range 0 (numPartitions - 1)
            |> List.map (\i -> ( i, Array.empty ))
            |> Dict.fromList
    , nextConsumerId = 0
    , consumers = Dict.empty
    }


publish : appMsg -> TopicEntry appMsg -> TopicEntry appMsg
publish msg entry =
    let
        -- Round-robin: pick partition based on total message count
        totalMsgs =
            Dict.foldl (\_ arr acc -> acc + Array.length arr) 0 entry.partitions

        partition =
            modBy entry.numPartitions totalMsgs
    in
    publishToPartition partition msg entry


publishToPartition : PartitionIndex -> appMsg -> TopicEntry appMsg -> TopicEntry appMsg
publishToPartition partition msg entry =
    let
        updated =
            Dict.update partition
                (\maybeArr ->
                    case maybeArr of
                        Just arr ->
                            Just (Array.push msg arr)

                        Nothing ->
                            Just (Array.fromList [ msg ])
                )
                entry.partitions
    in
    { entry | partitions = updated }


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

        consumer =
            { id = cid
            , groupId = groupId
            , currentOffsets = initialOffsets
            , committedOffsets = initialOffsets
            }
    in
    ( { entry
        | nextConsumerId = cid + 1
        , consumers = Dict.insert cid consumer entry.consumers
      }
    , cid
    )


poll : ConsumerId -> TopicEntry appMsg -> ( TopicEntry appMsg, List appMsg )
poll consumerId entry =
    case Dict.get consumerId entry.consumers of
        Nothing ->
            ( entry, [] )

        Just consumer ->
            let
                ( newOffsets, messages ) =
                    Dict.foldl
                        (\partition arr ( offAcc, msgAcc ) ->
                            let
                                currentOffset =
                                    Dict.get partition consumer.currentOffsets
                                        |> Maybe.withDefault 0

                                partitionMsgs =
                                    Array.toList (Array.slice currentOffset (Array.length arr) arr)

                                newOffset =
                                    Array.length arr
                            in
                            ( Dict.insert partition newOffset offAcc
                            , msgAcc ++ partitionMsgs
                            )
                        )
                        ( consumer.currentOffsets, [] )
                        entry.partitions

                updatedConsumer =
                    { consumer | currentOffsets = newOffsets }
            in
            ( { entry | consumers = Dict.insert consumerId updatedConsumer entry.consumers }
            , messages
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
