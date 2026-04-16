module Actor.Core exposing (..)

type Actor flags model msg
    = Actor


type Process msg
    = Process


type ExitReason
    = Normal
    | Shutdown
    | Crashed


actor :
    { init : flags -> ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : model -> Sub msg
    }
    -> Actor flags model msg
spawn : Actor flags model msg -> flags -> Task x (Process msg)
self : Task x (Process msg)
exit : Process msg -> ExitReason -> Task x ()
kill : Process msg -> Task x ()
