module Actor.Internal.Selector exposing
    ( SelectorAst(..)
    , SelectorEntry
    , matchSelector
    )

{-| Selector AST and evaluator used by the Runtime's mailbox-based delivery.
The public-facing function-based Selector lives in Actor.P2P.
-}

import Actor.Internal.Types exposing (ProcessId, SelectorId, SubjectId)


type SelectorAst appMsg
    = SelectFromSubject SubjectId (appMsg -> Maybe appMsg)
    | SelectMap (appMsg -> appMsg) (SelectorAst appMsg)
    | SelectFilter (appMsg -> Bool) (SelectorAst appMsg)
    | SelectOrElse (SelectorAst appMsg) (SelectorAst appMsg)
    | SelectAny


type alias SelectorEntry appMsg =
    { id : SelectorId
    , ast : SelectorAst appMsg
    , owner : ProcessId
    , continuous : Bool
    }


{-| Evaluate a selector AST against an incoming message from a given subject.
-}
matchSelector :
    SelectorAst appMsg
    -> appMsg
    -> SubjectId
    -> Maybe appMsg
matchSelector ast msg sourceSubject =
    case ast of
        SelectFromSubject sid transform ->
            if sid == sourceSubject then
                transform msg

            else
                Nothing

        SelectMap f inner ->
            matchSelector inner msg sourceSubject
                |> Maybe.map f

        SelectFilter pred inner ->
            matchSelector inner msg sourceSubject
                |> Maybe.andThen
                    (\result ->
                        if pred result then
                            Just result

                        else
                            Nothing
                    )

        SelectOrElse left right ->
            case matchSelector left msg sourceSubject of
                Just result ->
                    Just result

                Nothing ->
                    matchSelector right msg sourceSubject

        SelectAny ->
            Just msg
