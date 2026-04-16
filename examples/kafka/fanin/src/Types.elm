module Types exposing (AppMsg(..), Event(..), Order, Payment)


type alias Order =
    { id : Int
    , product : String
    , amount : Float
    }


type alias Payment =
    { orderId : Int
    , amount : Float
    , method : String
    }


{-| Intermediate domain type produced by selectMap from two different topics.
The Selector unifies Order and Payment into a single Event stream.
-}
type Event
    = OrderPlaced Order
    | PaymentReceived Payment


type AppMsg
    = EventOccurred Event
    | LogMsg String
