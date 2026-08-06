-- | Shared memory-space and principal fixtures for the test suite.
--
-- Every write in Kioku now needs a 'MemoryAccessContext', and most tests do not care which one —
-- they care about turns, watermarks, or recall. Those use 'testContext'.
--
-- It deliberately names a space that is /not/ 'Kioku.Api.Access.legacyMemorySpaceId'. If the
-- suite ran entirely in the legacy space, every test would keep passing on the day some path
-- started silently defaulting to it, which is the exact failure this work exists to prevent.
--
-- 'otherContext' is for the tests that need a second space to be refused from.
module Kioku.SpaceFixtures
  ( testSpace,
    otherSpace,
    testActor,
    otherActor,
    testContext,
    otherContext,
    testActorPrincipal,
    otherActorPrincipal,
    testContextProvider,
    contextFor,
    spaceNamed,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.Api.Access
  ( MemoryAccessContext,
    MemoryActor (..),
    MemoryContextProvider,
    MemorySpaceId,
    RecordedPrincipal,
    assumeAuthorizedContextProvider,
    assumeAuthorizedMemoryContext,
    memoryContextRecordedActor,
    mkMemorySpaceId,
    mkPrincipalRef,
  )

testSpace :: MemorySpaceId
testSpace = spaceNamed "space_test"

otherSpace :: MemorySpaceId
otherSpace = spaceNamed "space_other"

testActor :: MemoryActor
testActor = actorNamed "agent_01h9xk3v7hf8b9c0d1e2f3g4h5"

otherActor :: MemoryActor
otherActor = actorNamed "agent_01h9xk3v7hf8b9c0d1e2f3g4h6"

testContext :: MemoryAccessContext
testContext = contextFor testSpace testActor

otherContext :: MemoryAccessContext
otherContext = contextFor otherSpace otherActor

-- | The provider a background worker under test uses: authorized for whatever space the work
-- names, as 'testActor'.
testContextProvider :: (Applicative m) => MemoryContextProvider m
testContextProvider = assumeAuthorizedContextProvider testActor

-- | The actor as an event payload records it.
testActorPrincipal :: RecordedPrincipal
testActorPrincipal = memoryContextRecordedActor testContext

otherActorPrincipal :: RecordedPrincipal
otherActorPrincipal = memoryContextRecordedActor otherContext

contextFor :: MemorySpaceId -> MemoryActor -> MemoryAccessContext
contextFor = assumeAuthorizedMemoryContext

spaceNamed :: Text -> MemorySpaceId
spaceNamed = expectRight . mkMemorySpaceId

actorNamed :: Text -> MemoryActor
actorNamed = MemoryActor . expectRight . mkPrincipalRef

expectRight :: Either Text a -> a
expectRight = either (error . Text.unpack) id
