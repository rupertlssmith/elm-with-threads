module Actor.Core exposing (..)

type Process msg = Process

type alias Actor flags model msg =
    { init : flags -> ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : model -> Sub msg
    }

spawn : Actor flags model msg -> flags -> Task x (Process msg)
self : Task x (Process msg)
kill : Process msg -> Task x ()
