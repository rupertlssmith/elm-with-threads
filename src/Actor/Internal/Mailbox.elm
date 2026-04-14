module Actor.Internal.Mailbox exposing
    ( Mailbox
    , empty
    , enqueue
    , dequeue
    , fromList
    , isEmpty
    , toList
    )

{-| FIFO message queue for actor mailboxes.
-}


type Mailbox a
    = Mailbox (List a) (List a)


empty : Mailbox a
empty =
    Mailbox [] []


enqueue : a -> Mailbox a -> Mailbox a
enqueue item (Mailbox front back) =
    Mailbox front (item :: back)


dequeue : Mailbox a -> Maybe ( a, Mailbox a )
dequeue (Mailbox front back) =
    case front of
        x :: rest ->
            Just ( x, Mailbox rest back )

        [] ->
            case List.reverse back of
                [] ->
                    Nothing

                x :: rest ->
                    Just ( x, Mailbox rest [] )


isEmpty : Mailbox a -> Bool
isEmpty (Mailbox front back) =
    List.isEmpty front && List.isEmpty back


toList : Mailbox a -> List a
toList (Mailbox front back) =
    front ++ List.reverse back


fromList : List a -> Mailbox a
fromList items =
    Mailbox items []
