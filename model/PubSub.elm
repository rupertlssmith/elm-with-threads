module Actor.PubSub exposing (..)

type alias Key = String

type Topic a = Topic

topic : Task x (Topic a)
publish : Topic a -> a -> Task x ()
publishKeyed : Topic a -> Key -> a -> Task x ()
subscribe : Topic a -> (a -> parentMsg) -> Sub parentMsg
