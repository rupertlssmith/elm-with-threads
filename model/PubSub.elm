module Actor.PubSub exposing
    ( Key
    , Topic
    , topic
    , publish
    , publishKeyed
    , subscribe
    )

import Debug
import Platform.Sub exposing (Sub)
import Task exposing (Task)


-- PUB/SUB TOPICS (NORMAL LAYER)


type alias Key =
    String


type Topic a
    = Topic


topic :
    Task x (Topic a)
topic =
    Debug.todo "topic"


publish :
    Topic a
    -> a
    -> Task x ()
publish =
    Debug.todo "publish"


publishKeyed :
    Topic a
    -> Key
    -> a
    -> Task x ()
publishKeyed =
    Debug.todo "publishKeyed"


subscribe :
    Topic a
    -> (a -> parentMsg)
    -> Sub parentMsg
subscribe =
    Debug.todo "subscribe"
