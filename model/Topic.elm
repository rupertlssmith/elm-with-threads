module Actor.Topic exposing (..)

type alias Key = String
type alias Group = String
type alias Partition = Int
type alias Offset = Int

type Topic a = Topic
type Consumer a = Consumer
type Selector msg a = Selector

type alias ConsumerRecord a =
    { value : a
    , key : Maybe Key
    , partition : Partition
    , offset : Offset
    }

createTopic : { name : String, partitions : Int } -> Task x (Topic a)
send : Topic a -> a -> Task x ()
sendKeyed : Topic a -> Key -> a -> Task x ()
consumer : Topic a -> Group -> Task x (Consumer a)
close : Consumer a -> Task x ()
poll : Consumer a -> Task x (List (ConsumerRecord a))
commit : Consumer a -> Task x ()
seekToBeginning : Consumer a -> Task x ()
seekToEnd : Consumer a -> Task x ()
seek : Consumer a -> Partition -> Offset -> Task x ()
all : Consumer a -> Selector (ConsumerRecord a) (ConsumerRecord a)
selector : Selector msg msg
selectMap : Consumer a -> (ConsumerRecord a -> msg) -> Selector msg b -> Selector msg b
map : (a -> b) -> Selector msg a -> Selector msg b
filter : (a -> Bool) -> Selector msg a -> Selector msg a
subscribe : Selector msg a -> (a -> parentMsg) -> Sub parentMsg
