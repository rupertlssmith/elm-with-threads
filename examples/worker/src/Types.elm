module Types exposing (AppMsg(..))

import Time


type AppMsg
    = WorkerJob Int
    | WorkerReport String
    | TopicEvent String
    | Heartbeat Time.Posix
