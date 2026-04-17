module Actor.Task exposing
    ( Task
    , succeed, fail
    , map, mapError, andThen, andMap, sequence
    , fromProcedure, toProcedure, fromContext
    , attempt, run
    )

{-| Opaque task type that threads the actor runtime's `SystemContext` implicitly,
so call sites read like the model API (`Task x a`) rather than carrying a `ctx`
argument through every operation.

A `Task msg parentMsg err val` is a reader over `SystemContext msg parentMsg`
wrapping an underlying `Procedure.Procedure err val parentMsg`. The ctx is
supplied once at the top of the application via `run` / `attempt`.

@docs Task
@docs succeed, fail
@docs map, mapError, andThen, andMap, sequence
@docs fromProcedure, toProcedure, fromContext
@docs attempt, run

-}

import Actor.Internal.Runtime exposing (SystemContext)
import Procedure
import Procedure.Program


{-| An `ActorTask`. The `msg` and `parentMsg` parameters are usually fixed
per application — consumers typically alias `Task AppMsg AppMsg e a` as
`ActorTask e a`.
-}
type Task msg parentMsg err val
    = Task (SystemContext msg parentMsg -> Procedure.Procedure err val parentMsg)


{-| A task that immediately yields a value.
-}
succeed : val -> Task msg parentMsg err val
succeed v =
    Task (\_ -> Procedure.provide v)


{-| A task that immediately fails with the given error.
-}
fail : err -> Task msg parentMsg err val
fail e =
    Task (\_ -> Procedure.break e)


{-| Map the success value of a task.
-}
map : (a -> b) -> Task msg parentMsg err a -> Task msg parentMsg err b
map f (Task run_) =
    Task (\ctx -> Procedure.map f (run_ ctx))


{-| Map the error value of a task.
-}
mapError : (e -> f) -> Task msg parentMsg e val -> Task msg parentMsg f val
mapError f (Task run_) =
    Task (\ctx -> Procedure.mapError f (run_ ctx))


{-| Chain another task onto the success of this one. Shares the same ctx.
-}
andThen : (a -> Task msg parentMsg err b) -> Task msg parentMsg err a -> Task msg parentMsg err b
andThen f (Task run_) =
    Task
        (\ctx ->
            run_ ctx
                |> Procedure.andThen
                    (\a ->
                        case f a of
                            Task run2 ->
                                run2 ctx
                    )
        )


{-| Applicative application of tasks.

    f |> andMap ta |> andMap tb

runs each task and applies `f` to their results in sequence.

-}
andMap : Task msg parentMsg err a -> Task msg parentMsg err (a -> b) -> Task msg parentMsg err b
andMap ta tf =
    tf |> andThen (\f -> map f ta)


{-| Run a list of tasks in order and collect their results.
-}
sequence : List (Task msg parentMsg err a) -> Task msg parentMsg err (List a)
sequence tasks =
    case tasks of
        [] ->
            succeed []

        t :: rest ->
            t |> andThen (\x -> sequence rest |> map (\xs -> x :: xs))


{-| Lift a raw `Procedure` into a `Task` that ignores the ctx.

Useful for mixing in cmd-producing primitives like `Procedure.do port` that
have nothing to do with the actor system.

-}
fromProcedure : Procedure.Procedure err val parentMsg -> Task msg parentMsg err val
fromProcedure proc =
    Task (\_ -> proc)


{-| Build a task from a function that needs the `SystemContext` to construct
its underlying procedure. This is the primitive each API operation
(`Actor.Core.spawn`, `Actor.Channel.send`, …) uses to wrap its ctx-dependent
body.
-}
fromContext : (SystemContext msg parentMsg -> Procedure.Procedure err val parentMsg) -> Task msg parentMsg err val
fromContext =
    Task


{-| Unwrap a task back to a `Procedure`, applying the ctx.

This is what `run` / `attempt` use internally; exposed for cases where you
want to compose a task with existing `Procedure` pipelines.

-}
toProcedure : SystemContext msg parentMsg -> Task msg parentMsg err val -> Procedure.Procedure err val parentMsg
toProcedure ctx (Task f) =
    f ctx


{-| Run a task that cannot fail, firing `onDone` with the result.
-}
run :
    SystemContext msg parentMsg
    -> (Procedure.Program.Msg parentMsg -> parentMsg)
    -> (val -> parentMsg)
    -> Task msg parentMsg Never val
    -> Cmd parentMsg
run ctx procTag onDone (Task f) =
    Procedure.run procTag onDone (f ctx)


{-| Run a task that may fail, firing the tagger with `Result err val`.
-}
attempt :
    SystemContext msg parentMsg
    -> (Procedure.Program.Msg parentMsg -> parentMsg)
    -> (Result err val -> parentMsg)
    -> Task msg parentMsg err val
    -> Cmd parentMsg
attempt ctx procTag onResult (Task f) =
    Procedure.try procTag onResult (f ctx)
