module Actor.Core exposing
    ( Process
    , Actor
    , spawn
    , self
    , kill
    )

import Debug
import Platform.Cmd exposing (Cmd)
import Platform.Sub exposing (Sub)
import Task exposing (Task)


-- PROCESS / ACTOR LIFECYCLE


type Process msg
    = Process


type alias Actor flags model msg =
    { init : flags -> ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : model -> Sub msg
    }


spawn :
    Actor flags model msg
    -> flags
    -> Task x (Process msg)
spawn =
    Debug.todo "spawn"


self :
    Task x (Process msg)
self =
    Debug.todo "self"


kill :
    Process msg
    -> Task x ()
kill =
    Debug.todo "kill"
