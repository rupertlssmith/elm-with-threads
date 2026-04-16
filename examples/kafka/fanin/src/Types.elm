module Types exposing (AppMsg(..), Order, Payment)


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


type AppMsg
    = OrderPlaced Order
    | PaymentReceived Payment
    | LogMsg String
