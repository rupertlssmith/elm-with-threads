module Actor.Internal.Runtime exposing
    ( ActorSystem
    , ProcessEntry(..)
    , ProcessEntryRecord
    , SystemContext
    , initSystem
    , msgToCmd
    , spawnProcess
    , killProcess
    , createSubject
    , sendToSubject
    , sendKeyedToSubject
    , registerSelector
    , removeSelector
    , createTopic
    , publishToTopic
    , publishKeyedToTopic
    , createConsumer
    , pollConsumer
    , commitConsumer
    , seekConsumerToBeginning
    , seekConsumerToEnd
    , seekConsumerToOffset
    , deliverPendingMessages
    , updateTime
    , getProcess
    )

{-| Core actor system runtime. Manages processes, subjects, selectors, and topics.
-}

import Actor.Internal.Mailbox as Mailbox exposing (Mailbox)
import Actor.Internal.Selector as Selector exposing (SelectorAst, SelectorEntry)
import Actor.Internal.TopicStore as TopicStore exposing (TopicEntry)
import Actor.Internal.Types exposing (ConsumerId, Key, Offset, PartitionIndex, ProcessId, SelectorId, SubjectId, TopicId)
import Dict exposing (Dict)
import Task
import Time


{-| Context for running system operations as Procedures.
`runOp` wraps a system-modifying function as a message for the main update loop.
`mapAppCmd` converts actor commands (Cmd appMsg) to the main msg type.
-}
type alias SystemContext appMsg msg =
    { runOp : (ActorSystem appMsg -> ( ActorSystem appMsg, Cmd msg )) -> msg
    , mapAppCmd : Cmd appMsg -> Cmd msg
    }


{-| Convert a message value into a Cmd that dispatches it.
-}
msgToCmd : msg -> Cmd msg
msgToCmd m =
    Task.perform identity (Task.succeed m)


{-| A process entry uses a closure-based handleMessage to capture the actor's
internal model, avoiding existential type issues. Must be a `type` (not alias)
to break the recursive reference with ActorSystem.
-}
type ProcessEntry appMsg
    = ProcessEntry (ProcessEntryRecord appMsg)


type alias ProcessEntryRecord appMsg =
    { id : ProcessId
    , mailbox : Mailbox appMsg
    , handleMessage : appMsg -> ActorSystem appMsg -> ( ProcessEntry appMsg, ActorSystem appMsg, Cmd appMsg )
    }


type alias SubjectEntry =
    { id : SubjectId
    , owner : ProcessId
    }


type alias ActorSystem appMsg =
    { nextProcessId : ProcessId
    , nextSubjectId : SubjectId
    , nextSelectorId : SelectorId
    , nextTopicId : TopicId
    , processes : Dict ProcessId (ProcessEntry appMsg)
    , subjects : Dict SubjectId SubjectEntry
    , selectors : Dict SelectorId (SelectorEntry appMsg)
    , topics : Dict TopicId (TopicEntry appMsg)
    , currentTime : Time.Posix
    }


unwrap : ProcessEntry appMsg -> ProcessEntryRecord appMsg
unwrap (ProcessEntry r) =
    r


initSystem : ActorSystem appMsg
initSystem =
    { nextProcessId = 1
    , nextSubjectId = 1
    , nextSelectorId = 1
    , nextTopicId = 1
    , processes = Dict.empty
    , subjects = Dict.empty
    , selectors = Dict.empty
    , topics = Dict.empty
    , currentTime = Time.millisToPosix 0
    }


spawnProcess :
    (ProcessId -> appMsg -> ActorSystem appMsg -> ( ProcessEntry appMsg, ActorSystem appMsg, Cmd appMsg ))
    -> ActorSystem appMsg
    -> ( ActorSystem appMsg, ProcessId )
spawnProcess makeHandler system =
    let
        pid =
            system.nextProcessId

        entry =
            ProcessEntry
                { id = pid
                , mailbox = Mailbox.empty
                , handleMessage = makeHandler pid
                }
    in
    ( { system
        | nextProcessId = pid + 1
        , processes = Dict.insert pid entry system.processes
      }
    , pid
    )


killProcess : ProcessId -> ActorSystem appMsg -> ActorSystem appMsg
killProcess pid system =
    let
        filteredSelectors =
            Dict.filter (\_ sel -> sel.owner /= pid) system.selectors

        filteredSubjects =
            Dict.filter (\_ sub -> sub.owner /= pid) system.subjects
    in
    { system
        | processes = Dict.remove pid system.processes
        , selectors = filteredSelectors
        , subjects = filteredSubjects
    }


createSubject : ProcessId -> ActorSystem appMsg -> ( ActorSystem appMsg, SubjectId )
createSubject ownerPid system =
    let
        sid =
            system.nextSubjectId

        entry =
            { id = sid
            , owner = ownerPid
            }
    in
    ( { system
        | nextSubjectId = sid + 1
        , subjects = Dict.insert sid entry system.subjects
      }
    , sid
    )


sendToSubject : SubjectId -> appMsg -> ActorSystem appMsg -> ActorSystem appMsg
sendToSubject sid msg system =
    case Dict.get sid system.subjects of
        Nothing ->
            system

        Just subjectEntry ->
            enqueueToProcess subjectEntry.owner msg system


sendKeyedToSubject : SubjectId -> Key -> appMsg -> ActorSystem appMsg -> ActorSystem appMsg
sendKeyedToSubject sid _ msg system =
    sendToSubject sid msg system


enqueueToProcess : ProcessId -> appMsg -> ActorSystem appMsg -> ActorSystem appMsg
enqueueToProcess pid msg system =
    case Dict.get pid system.processes of
        Nothing ->
            system

        Just (ProcessEntry r) ->
            let
                updatedEntry =
                    ProcessEntry { r | mailbox = Mailbox.enqueue msg r.mailbox }
            in
            { system | processes = Dict.insert pid updatedEntry system.processes }


registerSelector : SelectorEntry appMsg -> ActorSystem appMsg -> ( ActorSystem appMsg, SelectorId )
registerSelector entry system =
    let
        sid =
            system.nextSelectorId
    in
    ( { system
        | nextSelectorId = sid + 1
        , selectors = Dict.insert sid { entry | id = sid } system.selectors
      }
    , sid
    )


removeSelector : SelectorId -> ActorSystem appMsg -> ActorSystem appMsg
removeSelector sid system =
    { system | selectors = Dict.remove sid system.selectors }


createTopic : String -> Int -> ActorSystem appMsg -> ( ActorSystem appMsg, TopicId )
createTopic _ numPartitions system =
    let
        tid =
            system.nextTopicId

        entry =
            TopicStore.initTopic tid numPartitions
    in
    ( { system
        | nextTopicId = tid + 1
        , topics = Dict.insert tid entry system.topics
      }
    , tid
    )


publishToTopic : TopicId -> appMsg -> ActorSystem appMsg -> ActorSystem appMsg
publishToTopic tid msg system =
    case Dict.get tid system.topics of
        Nothing ->
            system

        Just entry ->
            { system | topics = Dict.insert tid (TopicStore.publish msg entry) system.topics }


publishKeyedToTopic : TopicId -> Key -> appMsg -> ActorSystem appMsg -> ActorSystem appMsg
publishKeyedToTopic tid key msg system =
    case Dict.get tid system.topics of
        Nothing ->
            system

        Just entry ->
            let
                partition =
                    TopicStore.partitionForKey key entry.numPartitions
            in
            { system
                | topics =
                    Dict.insert tid
                        (TopicStore.publishToPartition partition msg entry)
                        system.topics
            }


createConsumer : TopicId -> String -> ActorSystem appMsg -> ( ActorSystem appMsg, Maybe ( TopicId, ConsumerId ) )
createConsumer tid groupId system =
    case Dict.get tid system.topics of
        Nothing ->
            ( system, Nothing )

        Just entry ->
            let
                ( updatedEntry, cid ) =
                    TopicStore.initConsumer groupId entry
            in
            ( { system | topics = Dict.insert tid updatedEntry system.topics }
            , Just ( tid, cid )
            )


pollConsumer : TopicId -> ConsumerId -> ActorSystem appMsg -> ( ActorSystem appMsg, List appMsg )
pollConsumer tid cid system =
    case Dict.get tid system.topics of
        Nothing ->
            ( system, [] )

        Just entry ->
            let
                ( updatedEntry, messages ) =
                    TopicStore.poll cid entry
            in
            ( { system | topics = Dict.insert tid updatedEntry system.topics }
            , messages
            )


commitConsumer : TopicId -> ConsumerId -> ActorSystem appMsg -> ActorSystem appMsg
commitConsumer tid cid system =
    case Dict.get tid system.topics of
        Nothing ->
            system

        Just entry ->
            { system | topics = Dict.insert tid (TopicStore.commit cid entry) system.topics }


seekConsumerToBeginning : TopicId -> ConsumerId -> ActorSystem appMsg -> ActorSystem appMsg
seekConsumerToBeginning tid cid system =
    updateTopicEntry tid (TopicStore.seekToBeginning cid) system


seekConsumerToEnd : TopicId -> ConsumerId -> ActorSystem appMsg -> ActorSystem appMsg
seekConsumerToEnd tid cid system =
    updateTopicEntry tid (TopicStore.seekToEnd cid) system


seekConsumerToOffset : TopicId -> ConsumerId -> PartitionIndex -> Offset -> ActorSystem appMsg -> ActorSystem appMsg
seekConsumerToOffset tid cid partition offset system =
    updateTopicEntry tid (TopicStore.seekToOffset cid partition offset) system


updateTopicEntry : TopicId -> (TopicEntry appMsg -> TopicEntry appMsg) -> ActorSystem appMsg -> ActorSystem appMsg
updateTopicEntry tid f system =
    case Dict.get tid system.topics of
        Nothing ->
            system

        Just entry ->
            { system | topics = Dict.insert tid (f entry) system.topics }


{-| Deliver pending messages from all process mailboxes.
-}
deliverPendingMessages : ActorSystem appMsg -> ( ActorSystem appMsg, Cmd appMsg )
deliverPendingMessages system =
    let
        pids =
            Dict.keys system.processes
    in
    deliverForProcesses pids system Cmd.none


deliverForProcesses : List ProcessId -> ActorSystem appMsg -> Cmd appMsg -> ( ActorSystem appMsg, Cmd appMsg )
deliverForProcesses pids system cmds =
    case pids of
        [] ->
            ( system, cmds )

        pid :: rest ->
            let
                ( newSystem, newCmds ) =
                    drainMailbox pid system
            in
            deliverForProcesses rest newSystem (Cmd.batch [ newCmds, cmds ])


drainMailbox : ProcessId -> ActorSystem appMsg -> ( ActorSystem appMsg, Cmd appMsg )
drainMailbox pid system =
    case Dict.get pid system.processes of
        Nothing ->
            ( system, Cmd.none )

        Just (ProcessEntry r) ->
            case Mailbox.dequeue r.mailbox of
                Nothing ->
                    ( system, Cmd.none )

                Just ( msg, remainingMailbox ) ->
                    let
                        entryWithDrained =
                            ProcessEntry { r | mailbox = remainingMailbox }

                        systemWithDrained =
                            { system | processes = Dict.insert pid entryWithDrained system.processes }

                        ( ProcessEntry updatedRecord, newSystem, cmd ) =
                            r.handleMessage msg systemWithDrained

                        -- handleWith returns a new entry with Mailbox.empty, which would
                        -- wipe remaining messages. Preserve the current mailbox from the
                        -- system (which may also have new messages added during handling).
                        currentMailbox =
                            case Dict.get pid newSystem.processes of
                                Just (ProcessEntry currentR) ->
                                    currentR.mailbox

                                Nothing ->
                                    Mailbox.empty

                        preservedEntry =
                            ProcessEntry { updatedRecord | mailbox = currentMailbox }

                        systemWithUpdated =
                            { newSystem | processes = Dict.insert pid preservedEntry newSystem.processes }

                        ( finalSystem, moreCmds ) =
                            drainMailbox pid systemWithUpdated
                    in
                    ( finalSystem, Cmd.batch [ moreCmds, cmd ] )


updateTime : Time.Posix -> ActorSystem appMsg -> ActorSystem appMsg
updateTime time system =
    { system | currentTime = time }


getProcess : ProcessId -> ActorSystem appMsg -> Maybe (ProcessEntry appMsg)
getProcess pid system =
    Dict.get pid system.processes
