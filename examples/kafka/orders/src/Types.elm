module Types exposing (AppMsg(..), Order)

import Actor.Topic as Topic


type alias Order =
    { id : Int
    , product : String
    , customerId : String
    }


type AppMsg
    = OrderReceived (Topic.ConsumerRecord Order)
    | LogMsg String
