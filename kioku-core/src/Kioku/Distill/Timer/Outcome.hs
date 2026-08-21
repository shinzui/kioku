-- | What a distillation timer fire decided.
--
-- This module sits at the bottom of the distillation graph so that
-- "Kioku.Distill.L2", "Kioku.Distill.L3", and "Kioku.Distill.Timer.Worker" can
-- all import it (the worker imports L2 and L3, so the type cannot live there).
--
-- It replaces a @Maybe EventId@ whose @Nothing@ meant three incompatible things
-- at once — a transient failure, a permanent failure, and "this timer is not
-- mine" — all of which keiro treated identically by leaving the row @firing@
-- until its 300-second stale-claim requeue. A timer whose LLM call could never
-- succeed therefore retried forever, at full LLM cost, with nothing to show for
-- it.
module Kioku.Distill.Timer.Outcome
  ( FireOutcome (..),
    parsePartitionedScopeFields,
    firePartitionedDistillTimer,
    fireRetryDelay,
    unknownTimerRetryDelay,
    timerMarkerEventId,
  )
where

import Data.Aeson.Types (Object, Parser, parseEither, withObject, (.:))
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Effectful (Eff)
import Keiro.Timer (TimerId (..), TimerRow (..))
import Kioku.Api.Access
  ( MemoryContextProvider (..),
    MemoryPermission (MemoryDistill),
    MemorySpaceId,
    memoryContextAllows,
    memoryContextSpace,
    memorySpaceIdText,
  )
import Kioku.Api.Scope (MemoryScope)
import Kioku.Partition (parsePartitionSpace)
import Kioku.Prelude
import Kiroku.Store.Types (EventId (..))

-- | Decode the partition and scope shared by L2 and L3 timer payloads.
--
-- 'parsePartitionSpace' deliberately keeps native pre-partition timers working by defaulting a
-- missing @memorySpaceId@ into the legacy space.
parsePartitionedScopeFields :: Object -> Parser (MemorySpaceId, MemoryScope)
parsePartitionedScopeFields o =
  (,) <$> parsePartitionSpace o <*> o .: "scope"

-- | Run the common authorization and outcome pipeline for one derived-artifact timer.
--
-- Provider refusal, an under-scoped context, a context for the wrong space, and malformed input
-- are configuration facts, so they dead-letter. Only a regeneration failure is retryable.
firePartitionedDistillTimer ::
  (Show err) =>
  Text ->
  String ->
  MemoryContextProvider (Eff es) ->
  TimerRow ->
  (MemorySpaceId -> MemoryScope -> Eff es (Either err result)) ->
  Eff es FireOutcome
firePartitionedDistillTimer expectedProcessName payloadLabel contextProvider row regenerate
  | row.processManagerName /= expectedProcessName =
      pure FireNotMine
  | otherwise =
      case parseEither (withObject (payloadLabel <> " payload") parsePartitionedScopeFields) row.payload of
        Left err ->
          pure (FireFailedPermanently (label <> " payload is malformed: " <> Text.pack err))
        Right (requestedSpace, scope) -> do
          decision <- contextProvider.contextForSpace requestedSpace
          case decision of
            Left denial ->
              pure
                ( FireFailedPermanently
                    (label <> " is not authorized for its memory space: " <> Text.pack (show denial))
                )
            Right context
              | memoryContextSpace context /= requestedSpace ->
                  pure
                    ( FireFailedPermanently
                        ( label
                            <> " context provider returned memory space "
                            <> memorySpaceIdText (memoryContextSpace context)
                            <> " for requested space "
                            <> memorySpaceIdText requestedSpace
                        )
                    )
              | not (memoryContextAllows MemoryDistill context) ->
                  pure
                    ( FireFailedPermanently
                        (label <> " context is missing required permission MemoryDistill")
                    )
              | otherwise -> do
                  result <- regenerate (memoryContextSpace context) scope
                  pure case result of
                    Right _ -> FireCompleted (timerMarkerEventId row.timerId)
                    Left err -> FireRetryLater (fireRetryDelay row.attempts) (Text.pack (show err))
  where
    label = Text.pack payloadLabel

-- | The verdict of one fire attempt.
data FireOutcome
  = -- | Done. Mark the timer fired with this event id.
    FireCompleted !EventId
  | -- | Transient failure: reschedule this many seconds out, logging the note.
    -- Bounded by keiro's attempt ceiling, so a persistently failing timer ends
    -- as a visible @dead@ row rather than cycling forever.
    FireRetryLater !NominalDiffTime !Text
  | -- | This can never succeed (a corrupt payload, an unparseable correlation
    -- id). Dead-letter it with this reason instead of faking success.
    FireFailedPermanently !Text
  | -- | This timer's process manager is not mine; I did not touch the row.
    FireNotMine
  deriving stock (Generic, Eq, Show)

-- | Backoff for a transient fire failure, by post-claim attempt count:
-- 30s, 60s, 120s, … doubling, capped at 900s.
--
-- keiro increments @attempts@ at claim time, so the first failure is called with
-- @1@. Eight claims under this schedule span roughly an hour — long enough to
-- ride out a provider incident, short enough to stop burning LLM tokens on work
-- that is structurally broken.
fireRetryDelay :: Int -> NominalDiffTime
fireRetryDelay attempts =
  min 900 (30 * (2 ^ max 0 (attempts - 1)))

-- | Requeue delay for a timer no handler owns.
--
-- keiro's 'Keiro.Timer.claimDueTimer' claims the earliest due timer regardless
-- of process-manager name, so an unknown-PM timer cannot be left unclaimed — it
-- must be put back. It is deliberately not dead-lettered on sight: during a
-- rolling deploy a newer kioku may have scheduled timers this binary does not
-- know about yet, and ten minutes gives the newer worker time to take them. The
-- attempt ceiling still guarantees a genuinely orphaned timer dies visibly.
unknownTimerRetryDelay :: NominalDiffTime
unknownTimerRetryDelay = 600

-- | Distillation timers append no dedicated domain event, so a fired timer is
-- marked with its own id as the event id. Keeping the convention in one place
-- means the three fire handlers cannot drift apart on it.
timerMarkerEventId :: TimerId -> EventId
timerMarkerEventId (TimerId uuid) = EventId uuid
