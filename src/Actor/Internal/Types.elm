module Actor.Internal.Types exposing
    ( Process(..)
    , ProcessId
    , SubjectId
    , SelectorId
    , TopicId
    , ConsumerId
    , Key
    , Offset
    , PartitionIndex
    )


{-| An opaque handle to a running actor process.
-}
type Process msg
    = Process ProcessId


type alias ProcessId =
    Int


type alias SubjectId =
    Int


type alias SelectorId =
    Int


type alias TopicId =
    Int


type alias ConsumerId =
    Int


type alias Key =
    String


type alias Offset =
    Int


type alias PartitionIndex =
    Int
