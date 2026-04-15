module Actor.P2P exposing (..)

type Subject a = Subject

type Selector msg a = Selector

subject : Task x (Subject a)
send : Subject a -> a -> Task x ()
all : Subject a -> Selector a a
selector : Selector msg msg
selectMap : Subject a -> (a -> msg) -> Selector msg b -> Selector msg b
map : (a -> b) -> Selector msg a -> Selector msg b
filter : (a -> Bool) -> Selector msg a -> Selector msg a
orElse : Selector msg a -> Selector msg a -> Selector msg a
withTimeout : Time -> a -> Selector msg a -> Selector msg a
select : Selector msg a -> Task x a
subscribe : Selector msg a -> (a -> parentMsg) -> Sub parentMsg
