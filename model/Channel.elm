module Actor.Channel exposing (..)

type Channel c a = Channel
type OneToOne = OneToOne
type Broadcast = Broadcast
type Selector msg a = Selector

oneToOne : Task x (Channel OneToOne a)
broadcast : Task x (Channel Broadcast a)
send : Channel OneToOne a -> a -> Task x ()
publish : Channel Broadcast a -> a -> Task x ()
all : Channel c a -> Selector a a
selector : Selector msg msg
selectMap : Channel c a -> (a -> msg) -> Selector msg b -> Selector msg b
map : (a -> b) -> Selector msg a -> Selector msg b
filter : (a -> Bool) -> Selector msg a -> Selector msg a
orElse : Selector msg a -> Selector msg a -> Selector msg a
withTimeout : Time -> a -> Selector msg a -> Selector msg a
select : Selector msg a -> Task x a
subscribe : Selector msg a -> (a -> parentMsg) -> Sub parentMsg
