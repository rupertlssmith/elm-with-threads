module Actor.Topic exposing (..)

type alias Key = String
type alias Group = String
type alias Partition = Int
type alias Offset = Int

type Topic a = Topic

type Consumer a = Consumer

topic : { partitions : Int } -> Task x (Topic a)
publish : Topic a -> a -> Task x ()
publishKeyed : Topic a -> Key -> a -> Task x ()
publishWithPartitionKey : (a -> Key) -> Topic a -> a -> Task x ()
subscribeGroup : Topic a -> Group -> (a -> parentMsg) -> Sub parentMsg
consumer : Topic a -> Group -> Task x (Consumer a)
poll : Consumer a -> Task x (List a)
commit : Consumer a -> Task x ()
seekToBeginning : Consumer a -> Task x ()
seekToEnd : Consumer a -> Task x ()
seekToOffset : Consumer a -> Partition -> Offset -> Task x ()
