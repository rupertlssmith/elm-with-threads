module Actor.Supervisor exposing (..)

type Supervisor msg
    = Supervisor


type ManagedActor msg
    = ManagedActor


type Strategy
    = OneForOne
    | OneForAll
    | RestForOne


type Restart
    = Permanent
    | Transient
    | Temporary


type Event msg
    = ActorStarted (Process msg)
    | ActorExited (Process msg) ExitReason
    | ActorRestarted (Process msg)


managedActor : Restart -> Actor flags model msg -> flags -> ManagedActor msg
supervisor : Strategy -> List (ManagedActor msg) -> Supervisor msg
start : Supervisor msg -> Task x (Process msg)
events : Supervisor msg -> Sub (Event msg)
