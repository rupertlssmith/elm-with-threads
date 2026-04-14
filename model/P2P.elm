module Actor.P2P exposing
    ( Key
    , Subject
    , Selector
    , subject
    , send
    , sendKeyed
    , all
    , selector
    , selectMap
    , map
    , filter
    , orElse
    , withTimeout
    , select
    , subscribe
    )

import Debug
import Platform.Sub exposing (Sub)
import Task exposing (Task)
import Time exposing (Time)


-- P2P SUBJECTS AND SELECTORS (NORMAL LAYER)


type alias Key =
    String


type Subject a
    = Subject


type Selector msg result
    = Selector


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
