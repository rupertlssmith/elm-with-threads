port module Actor.Ports exposing
    ( notifyP2PSend
    , onP2PSend
    )

{-| Port pair for P2P message notification via port-bounce.
The JS side echoes notifyP2PSend back through onP2PSend immediately.
-}


{-| Outgoing port: notify that a message was stored for a subject.
-}
port notifyP2PSend : { subjectId : Int, messageId : Int } -> Cmd msg


{-| Incoming port: echo of notifyP2PSend from JS.
-}
port onP2PSend : ({ subjectId : Int, messageId : Int } -> msg) -> Sub msg
