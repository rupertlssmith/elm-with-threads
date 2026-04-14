module Actor.Advanced.P2P exposing
    ( Subject
    , Selector
    , Key
    , Meta
    , Envelope
    , subject
    , send
    , sendKeyed
    , resendAsPossibleDuplicate
    , sendWithPartitionKey
    , all
    , selector
    , selectMap
    , map
    , filter
    , orElse
    , withTimeout
    , select
    , selectWithMeta
    , subscribe
    , subscribeWithMeta
    )

import Debug
import Platform.Sub exposing (Sub)
import Task exposing (Task)
import Time exposing (Time)


-- TYPES


type alias Key =
    String


type alias Meta =
    { key : Maybe Key
    , possibleDuplicate : Bool
    , sequence : Maybe Int
    }


type alias Envelope a =
    { meta : Meta
    , payload : a
    }


type Subject a
    = Subject


type Selector msg result
    = Selector



-- SUBJECT / SEND (ADVANCED)


subject :
    Task x (Subject a)
subject =
    Debug.todo "subject"


send :
    Subject a
    -> a
    -> Task x ()
send =
    Debug.todo "send"


sendKeyed :
    Subject a
    -> Key
    -> a
    -> Task x ()
sendKeyed =
    Debug.todo "sendKeyed"


resendAsPossibleDuplicate :
    Subject a
    -> Key
    -> a
    -> Task x ()
resendAsPossibleDuplicate =
    Debug.todo "resendAsPossibleDuplicate"


sendWithPartitionKey :
    (a -> Key)
    -> Subject a
    -> a
    -> Task x ()
sendWithPartitionKey =
    Debug.todo "sendWithPartitionKey"



-- SELECTOR COMBINATORS (ADVANCED, SAME SHAPES AS NORMAL)


{-| Create a selector that accepts all messages from a specific subject.
-}
all :
    Subject a
    -> Selector a a
all =
    Debug.todo "all"


selector :
    Selector msg msg
selector =
    Debug.todo "selector"


selectMap :
    Subject a
    -> (a -> msg)
    -> Selector msg result
    -> Selector msg result
selectMap =
    Debug.todo "selectMap"


map :
    (result -> result2)
    -> Selector msg result
    -> Selector msg result2
map =
    Debug.todo "map"


filter :
    (result -> Bool)
    -> Selector msg result
    -> Selector msg result
filter =
    Debug.todo "filter"


orElse :
    Selector msg result
    -> Selector msg result
    -> Selector msg result
orElse =
    Debug.todo "orElse"


withTimeout :
    Time
    -> result
    -> Selector msg result
    -> Selector msg result
withTimeout =
    Debug.todo "withTimeout"


select :
    Selector msg result
    -> Task x result
select =
    Debug.todo "select"


subscribe :
    Selector msg result
    -> (result -> parentMsg)
    -> Sub parentMsg
subscribe =
    Debug.todo "subscribe"



-- META-AWARE SELECTION / SUBSCRIPTION


selectWithMeta :
    Selector ( Meta, msg ) result
    -> Task x result
selectWithMeta =
    Debug.todo "selectWithMeta"


subscribeWithMeta :
    Selector ( Meta, msg ) result
    -> (result -> parentMsg)
    -> Sub parentMsg
subscribeWithMeta =
    Debug.todo "subscribeWithMeta"
