module Actor.Internal.Runtime exposing
    ( ActorSystem
    , MailboxEntry
    , MessageStoreEntry
    , ProcessEntry(..)
    , ProcessEntryRecord
    , SystemContext
    , collectActorSubs
    , collectSubscriptions
    , commitConsumer
    , createConsumer
    , createSubject
    , createTopic
    , deliverPendingMessages
    , deliver
    , deliverToActor
    , getProcess
    , initSystem
    , killProcess
    , lookupMessage
    , msgToCmd
    , pollConsumer
    , publishKeyedToTopic
    , publishToTopic
    , registerSelector
    , removeSelector
    , seekConsumerToBeginning
    , seekConsumerToEnd
    , seekConsumerToOffset
    , sendKeyedToSubject
    , sendToSubject
    , spawnProcess
    , storeMessage
    , messageStoreValues
    , updateTime
    )

{-| Core actor system runtime. Manages processes, subjects, selectors, and topics.
-}

import Actor.Internal.Mailbox as Mailbox exposing (Mailbox)
import Actor.Internal.Selector as Selector exposing (SelectorAst, SelectorEntry)
import Actor.Internal.TopicStore as TopicStore exposing (TopicEntry)
import Actor.Internal.Types exposing (ConsumerId, Key, Offset, PartitionIndex, Process(..), ProcessId, SelectorId, SubjectId, TopicId)
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


{-| A mailbox entry tracks which Subject a message arrived through.
-}
type alias MailboxEntry appMsg =
    { sourceSubject : SubjectId
    , message : appMsg
    }


{-| A stored message awaiting consumption via port-bounce.
-}
type alias MessageStoreEntry appMsg =
    { subjectId : SubjectId
    , message : appMsg
    }


{-| A process entry uses a closure-based handleMessage to capture the actor's
internal model, avoiding existential type issues. Must be a `type` (not alias)
to break the recursive reference with ActorSystem.
-}
type ProcessEntry appMsg
    = ProcessEntry (ProcessEntryRecord appMsg)


type alias ProcessEntryRecord appMsg =
    { id : ProcessId
    , mailbox : Mailbox (MailboxEntry appMsg)
    , handleMessage : appMsg -> ActorSystem appMsg -> ( ProcessEntry appMsg, ActorSystem appMsg, Cmd appMsg )
    , actorSubs : Sub appMsg
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
    , nextMessageId : Int
    , processes : Dict ProcessId (ProcessEntry appMsg)
    , subjects : Dict SubjectId SubjectEntry
    , selectors : Dict SelectorId (SelectorEntry appMsg)
    , topics : Dict TopicId (TopicEntry appMsg)
    , messageStore : Dict Int (MessageStoreEntry appMsg)
    , currentTime : Time.Posix
    }


initSystem : ActorSystem appMsg
initSystem =
    { nextProcessId = 1
    , nextSubjectId = 1
    , nextSelectorId = 1
    , nextTopicId = 1
    , nextMessageId = 1
    , processes = Dict.empty
    , subjects = Dict.empty
    , selectors = Dict.empty
    , topics = Dict.empty
    , messageStore = Dict.empty
    , currentTime = Time.millisToPosix 0
    }


{-| Spawn a process. The factory receives the assigned PID and returns
the full ProcessEntry (including actorSubs).
-}
spawnProcess :
    (ProcessId -> ProcessEntry appMsg)
    -> ActorSystem appMsg
    -> ( ActorSystem appMsg, ProcessId )
spawnProcess makeEntry system =
    let
        pid =
            system.nextProcessId

        entry =
            makeEntry pid
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


createSubject : ActorSystem appMsg -> ( ActorSystem appMsg, SubjectId )
createSubject system =
    let
        sid =
            system.nextSubjectId
    in
    ( { system
        | nextSubjectId = sid + 1
      }
    , sid
    )


sendToSubject : SubjectId -> appMsg -> ActorSystem appMsg -> ActorSystem appMsg
sendToSubject sid msg system =
    case Dict.get sid system.subjects of
        Nothing ->
            system

        Just subjectEntry ->
            enqueueToProcess subjectEntry.owner sid msg system


sendKeyedToSubject : SubjectId -> Key -> appMsg -> ActorSystem appMsg -> ActorSystem appMsg
sendKeyedToSubject sid _ msg system =
    sendToSubject sid msg system


enqueueToProcess : ProcessId -> SubjectId -> appMsg -> ActorSystem appMsg -> ActorSystem appMsg
enqueueToProcess pid sourceSubject msg system =
    case Dict.get pid system.processes of
        Nothing ->
            system

        Just (ProcessEntry r) ->
            let
                entry =
                    { sourceSubject = sourceSubject, message = msg }

                updatedEntry =
                    ProcessEntry { r | mailbox = Mailbox.enqueue entry r.mailbox }
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
For processes with registered selectors, only messages matching a selector are
delivered. Non-matching messages remain in the mailbox.
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
            let
                selectors =
                    getSelectorsForProcess pid system
            in
            if List.isEmpty selectors then
                drainAllMessages pid r system

            else
                drainWithSelectors pid r selectors system


drainAllMessages : ProcessId -> ProcessEntryRecord appMsg -> ActorSystem appMsg -> ( ActorSystem appMsg, Cmd appMsg )
drainAllMessages pid r system =
    case Mailbox.dequeue r.mailbox of
        Nothing ->
            ( system, Cmd.none )

        Just ( entry, remainingMailbox ) ->
            deliverOneMessage pid r entry.message remainingMailbox system


drainWithSelectors : ProcessId -> ProcessEntryRecord appMsg -> List (SelectorEntry appMsg) -> ActorSystem appMsg -> ( ActorSystem appMsg, Cmd appMsg )
drainWithSelectors pid r selectors system =
    case findFirstMatch selectors (Mailbox.toList r.mailbox) [] of
        Nothing ->
            ( system, Cmd.none )

        Just ( transformedMsg, remainingEntries ) ->
            deliverOneMessage pid r transformedMsg (Mailbox.fromList remainingEntries) system


deliverOneMessage : ProcessId -> ProcessEntryRecord appMsg -> appMsg -> Mailbox (MailboxEntry appMsg) -> ActorSystem appMsg -> ( ActorSystem appMsg, Cmd appMsg )
deliverOneMessage pid r msg remainingMailbox system =
    let
        entryWithDrained =
            ProcessEntry { r | mailbox = remainingMailbox }

        systemWithDrained =
            { system | processes = Dict.insert pid entryWithDrained system.processes }

        ( ProcessEntry updatedRecord, newSystem, cmd ) =
            r.handleMessage msg systemWithDrained

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


findFirstMatch : List (SelectorEntry appMsg) -> List (MailboxEntry appMsg) -> List (MailboxEntry appMsg) -> Maybe ( appMsg, List (MailboxEntry appMsg) )
findFirstMatch selectors remaining skipped =
    case remaining of
        [] ->
            Nothing

        entry :: rest ->
            case tryMatchSelectors selectors entry of
                Just transformedMsg ->
                    Just ( transformedMsg, List.reverse skipped ++ rest )

                Nothing ->
                    findFirstMatch selectors rest (entry :: skipped)


tryMatchSelectors : List (SelectorEntry appMsg) -> MailboxEntry appMsg -> Maybe appMsg
tryMatchSelectors selectors entry =
    case selectors of
        [] ->
            Nothing

        sel :: rest ->
            case Selector.matchSelector sel.ast entry.message entry.sourceSubject of
                Just result ->
                    Just result

                Nothing ->
                    tryMatchSelectors rest entry


getSelectorsForProcess : ProcessId -> ActorSystem appMsg -> List (SelectorEntry appMsg)
getSelectorsForProcess pid system =
    system.selectors
        |> Dict.values
        |> List.filter (\sel -> sel.owner == pid)


{-| Deliver a single message directly to an actor's handleMessage.
Used for routing actor subscription events back to the owning process.
-}
deliverToActor : ProcessId -> appMsg -> ActorSystem appMsg -> ( ActorSystem appMsg, Cmd appMsg )
deliverToActor pid appMsg system =
    case Dict.get pid system.processes of
        Nothing ->
            ( system, Cmd.none )

        Just (ProcessEntry r) ->
            let
                ( ProcessEntry updatedRecord, newSystem, cmd ) =
                    r.handleMessage appMsg system

                currentMailbox =
                    case Dict.get pid newSystem.processes of
                        Just (ProcessEntry currentR) ->
                            currentR.mailbox

                        Nothing ->
                            Mailbox.empty

                preservedEntry =
                    ProcessEntry { updatedRecord | mailbox = currentMailbox }
            in
            ( { newSystem | processes = Dict.insert pid preservedEntry newSystem.processes }
            , cmd
            )


{-| Collect all actor subscriptions and map them to the main msg type.
The routeMsg function receives the process ID and appMsg, and should
produce a msg that delivers the appMsg to that process (e.g. via RunSystemOp).
-}
collectActorSubs : (ProcessId -> appMsg -> msg) -> ActorSystem appMsg -> Sub msg
collectActorSubs routeMsg system =
    system.processes
        |> Dict.toList
        |> List.map (\( pid, ProcessEntry r ) -> Sub.map (routeMsg pid) r.actorSubs)
        |> Sub.batch


{-| Deliver a message directly to a process via its opaque handle.
-}
deliver : Process appMsg -> appMsg -> ActorSystem appMsg -> ( ActorSystem appMsg, Cmd appMsg )
deliver (Process pid) appMsg system =
    deliverToActor pid appMsg system


{-| Collect all actor subscriptions, using opaque Process handles in the callback.
-}
collectSubscriptions : (Process appMsg -> appMsg -> msg) -> ActorSystem appMsg -> Sub msg
collectSubscriptions routeMsg system =
    collectActorSubs (\pid -> routeMsg (Process pid)) system


updateTime : Time.Posix -> ActorSystem appMsg -> ActorSystem appMsg
updateTime time system =
    { system | currentTime = time }


{-| Store a message for port-bounce delivery and return its ID.
-}
storeMessage : SubjectId -> appMsg -> ActorSystem appMsg -> ( ActorSystem appMsg, Int )
storeMessage sid msg system =
    let
        mid =
            system.nextMessageId

        entry =
            { subjectId = sid, message = msg }
    in
    ( { system
        | nextMessageId = mid + 1
        , messageStore = Dict.insert mid entry system.messageStore
      }
    , mid
    )


{-| Look up a stored message by ID.
-}
lookupMessage : Int -> ActorSystem appMsg -> Maybe (MessageStoreEntry appMsg)
lookupMessage mid system =
    Dict.get mid system.messageStore


{-| Get all message store entries as a list.
-}
messageStoreValues : ActorSystem appMsg -> List (MessageStoreEntry appMsg)
messageStoreValues system =
    Dict.values system.messageStore


getProcess : ProcessId -> ActorSystem appMsg -> Maybe (ProcessEntry appMsg)
getProcess pid system =
    Dict.get pid system.processes
