module Actor.PubSub exposing (..)

type Topic a = Topic

topic : Task x (Topic a)
publish : Topic a -> a -> Task x ()
subscribe : Topic a -> (a -> parentMsg) -> Sub parentMsg
