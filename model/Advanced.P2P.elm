module Actor.Advanced.P2P exposing (..)

type Subject a = Subject

type Selector msg a = Selector

type alias Key = String

type alias Meta =
    { key : Maybe Key
    , possibleDuplicate : Bool
    , sequence : Maybe Int
    }

type alias Envelope a =
    { meta : Meta
    , payload : a
    }

subject : Task x (Subject a)
send : Subject a -> a -> Task x ()
sendKeyed : Subject a -> Key -> a -> Task x ()
resendAsPossibleDuplicate : Subject a -> Key -> a -> Task x ()
sendWithPartitionKey : (a -> Key) -> Subject a -> a -> Task x ()
all : Subject a -> Selector a a
selector : Selector msg msg
selectMap : Subject a -> (a -> msg) -> Selector msg b -> Selector msg b
map : (a -> b) -> Selector msg a -> Selector msg b
filter : (a -> Bool) -> Selector msg a -> Selector msg a
orElse : Selector msg a -> Selector msg a -> Selector msg a
withTimeout : Time -> a -> Selector msg a -> Selector msg a
select : Selector msg a -> Task x a
selectWithMeta : Selector ( Meta, msg ) a -> Task x a
subscribe : Selector msg a -> (a -> parentMsg) -> Sub parentMsg
subscribeWithMeta : Selector ( Meta, msg ) a -> (a -> parentMsg) -> Sub parentMsg
