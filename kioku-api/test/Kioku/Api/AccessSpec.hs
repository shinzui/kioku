-- | Pure wire-format and validation tests for "Kioku.Api.Access".
--
-- Nothing here touches a database, a network, or any identity service. These tests pin two
-- things: the exact bytes the access vocabulary puts on the wire, and the boundary rules Kioku
-- enforces on identifiers it carries but does not own.
module Kioku.Api.AccessSpec (tests) where

import Data.Aeson (FromJSON, ToJSON, decode, encode)
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.Api.Access
import Kioku.Api.Access.Internal qualified as Internal
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Kioku.Api.Access"
    [ memorySpaceIdTests,
      principalRefTests,
      permissionWireTests,
      jsonRoundTripTests,
      objectRefTests,
      bindingTests,
      contextTests
    ]

-- | A memory space id is Kioku's own object identifier, so Kioku owns its rules. It has to
-- survive being an authorization object id, an indexed column, and half of a rendered object
-- reference, which is what the reserved characters are about.
memorySpaceIdTests :: TestTree
memorySpaceIdTests =
  testGroup
    "MemorySpaceId"
    [ testCase "accepts an ordinary identifier" do
        fmap memorySpaceIdText (mkMemorySpaceId "space_01h9xk3v7hf8b9c0d1e2f3g4h5")
          @?= Right "space_01h9xk3v7hf8b9c0d1e2f3g4h5",
      testCase "accepts a host-shaped label" do
        fmap memorySpaceIdText (mkMemorySpaceId "acme-tenant-3") @?= Right "acme-tenant-3",
      testCase "rejects the empty string" do
        assertLeft "empty" (mkMemorySpaceId ""),
      testGroup
        "rejects characters an encoding gives meaning to"
        [ testCase (Text.unpack ("contains " <> Text.singleton c)) do
            assertLeft ("reserved " <> show c) (mkMemorySpaceId ("space" <> Text.singleton c <> "one"))
        | c <- ":#%/"
        ],
      testCase "rejects whitespace" do
        assertLeft "space" (mkMemorySpaceId "space one"),
      testCase "rejects control characters" do
        assertLeft "control" (mkMemorySpaceId "space\ETXone"),
      testCase "rejects an over-long identifier" do
        assertLeft "too long" (mkMemorySpaceId (Text.replicate 129 "a")),
      testCase "accepts exactly the maximum length" do
        assertRight (mkMemorySpaceId (Text.replicate 128 "a")),
      testCase "the legacy space is a real, explicit id" do
        memorySpaceIdText legacyMemorySpaceId @?= "kioku_legacy",
      testCase "the legacy space is not the empty string" do
        -- The whole point of a named legacy space is that absence of a partition never means
        -- "everywhere". If this ever became empty or defaultable, that guarantee would go.
        assertBool "non-empty" (not (Text.null (memorySpaceIdText legacyMemorySpaceId)))
    ]

-- | A principal reference is somebody else's identifier. Kioku validates only what it needs to
-- store and compare the value safely, and deliberately does not know which prefixes exist.
principalRefTests :: TestTree
principalRefTests =
  testGroup
    "PrincipalRef"
    [ testGroup
        "accepts every directory-rendered principal form verbatim"
        [ testCase (Text.unpack rendered) do
            fmap principalRefText (mkPrincipalRef rendered) @?= Right rendered
        | rendered <- renderedPrincipals
        ],
      testCase "accepts a prefix Kioku has never heard of" do
        -- This is the load-bearing test for the boundary: Kioku holds no principal-kind
        -- vocabulary, so a directory that grows an eighth kind tomorrow needs no change here.
        -- A version of this constructor that validated prefixes would fail this case and would
        -- have forked the directory's own list.
        fmap principalRefText (mkPrincipalRef "workload_01h9xk3v7hf8b9c0d1e2f3g4h5")
          @?= Right "workload_01h9xk3v7hf8b9c0d1e2f3g4h5",
      testCase "rejects the empty string" do
        assertLeft "empty" (mkPrincipalRef ""),
      testCase "rejects a tuple separator" do
        assertLeft "colon" (mkPrincipalRef "person:01h9xk"),
      testCase "rejects a userset separator" do
        assertLeft "hash" (mkPrincipalRef "team_01h9xk#member"),
      testCase "rejects whitespace" do
        assertLeft "space" (mkPrincipalRef "person_01h9 xk"),
      testCase "permits characters a space id forbids" do
        -- '%' and '/' are reserved by Kioku's own scope encoding, not by anything the directory
        -- owns, so they must not be imposed on a value the directory renders.
        assertRight (mkPrincipalRef "person_01h9/xk")
    ]

-- | Rendered principal identifiers in the shape a real directory produces: a kind prefix, an
-- underscore, and a base32 UUIDv7 suffix.
renderedPrincipals :: [Text]
renderedPrincipals =
  [ "person_01h9xk3v7hf8b9c0d1e2f3g4h5",
    "agent_01h9xk3v7hf8b9c0d1e2f3g4h6",
    "team_01h9xk3v7hf8b9c0d1e2f3g4h7",
    "role_01h9xk3v7hf8b9c0d1e2f3g4h8",
    "service_01h9xk3v7hf8b9c0d1e2f3g4h9",
    "connector_01h9xk3v7hf8b9c0d1e2f3g4ha",
    "org_01h9xk3v7hf8b9c0d1e2f3g4hb"
  ]

-- | These five spellings end up inside stored events. Changing one is a breaking change, so it
-- should have to be done on purpose, with this test in the diff.
permissionWireTests :: TestTree
permissionWireTests =
  testGroup
    "MemoryPermission"
    [ testCase "has the expected stable spellings" do
        fmap memoryPermissionText allMemoryPermissions
          @?= ["read", "record", "distill", "forget", "admin"],
      testCase "encodes as a bare JSON string" do
        LBS8.unpack (encode MemoryDistill) @?= "\"distill\"",
      testCase "parses back from every spelling" do
        traverse (parseMemoryPermission . memoryPermissionText) allMemoryPermissions
          @?= Right allMemoryPermissions,
      testCase "rejects an unknown spelling" do
        assertLeft "unknown" (parseMemoryPermission "write"),
      testCase "enumerates exactly five actions" do
        length allMemoryPermissions @?= 5
    ]

jsonRoundTripTests :: TestTree
jsonRoundTripTests =
  testGroup
    "JSON round-trips"
    [ roundTrip "MemorySpaceId" (expectRight (mkMemorySpaceId "space_01h9xk")),
      roundTrip "PrincipalRef" (expectRight (mkPrincipalRef "person_01h9xk")),
      roundTrip "MemoryActor" (MemoryActor (expectRight (mkPrincipalRef "agent_01h9xk"))),
      roundTrip "MemoryOwner" (MemoryOwner (expectRight (mkPrincipalRef "person_01h9xk"))),
      testGroup
        "MemoryPermission"
        [roundTrip (show permission) permission | permission <- allMemoryPermissions],
      testCase "identifiers cross the wire as bare strings, not objects" do
        LBS8.unpack (encode (expectRight (mkMemorySpaceId "space_01h9xk"))) @?= "\"space_01h9xk\"",
      testCase "decoding enforces the same rules as constructing" do
        -- Without this, a validated newtype is only validated on the path nobody attacks.
        decode @MemorySpaceId "\"space:one\"" @?= Nothing,
      testCase "decoding rejects an empty principal reference" do
        decode @PrincipalRef "\"\"" @?= Nothing
    ]

-- | The object reference is what makes two memory spaces genuinely separate questions to ask an
-- authorization engine.
objectRefTests :: TestTree
objectRefTests =
  testGroup
    "object references"
    [ testCase "renders as type:id" do
        memoryObjectRefText (memorySpaceObjectRef testBinding spaceOne)
          @?= "memory_space:space_one",
      testCase "two spaces produce two different objects" do
        assertBool
          "distinct"
          ( memoryObjectRefText (memorySpaceObjectRef testBinding spaceOne)
              /= memoryObjectRefText (memorySpaceObjectRef testBinding spaceTwo)
          ),
      testCase "the object depends on the space and nothing else" do
        -- Namespace and scope organize memory inside a space; they are not part of its identity
        -- as an authorization object. Two hosts sharing one space share one object.
        memorySpaceObjectRef testBinding spaceOne @?= memorySpaceObjectRef testBinding spaceOne,
      testCase "the host names the object type" do
        let other = expectRight (mkMemoryAuthorizationBinding (expectRight (mkMemoryObjectType "tenant")) fullBindings)
        memoryObjectRefText (memorySpaceObjectRef other spaceOne) @?= "tenant:space_one"
    ]

bindingTests :: TestTree
bindingTests =
  testGroup
    "MemoryAuthorizationBinding"
    [ testCase "rejects a binding with any action missing" do
        assertLeft
          "incomplete"
          ( mkMemoryAuthorizationBinding
              (expectRight (mkMemoryObjectType "memory_space"))
              (filter ((/= MemoryForget) . fst) fullBindings)
          ),
      testCase "names the missing actions" do
        case mkMemoryAuthorizationBinding
          (expectRight (mkMemoryObjectType "memory_space"))
          (filter ((`notElem` [MemoryForget, MemoryAdmin]) . fst) fullBindings) of
          Right _ -> fail "expected an incomplete binding to be rejected"
          Left message -> do
            assertBool "names forget" ("forget" `Text.isInfixOf` message)
            assertBool "names admin" ("admin" `Text.isInfixOf` message),
      testCase "a complete binding resolves every action" do
        fmap
          (memoryPermissionNameText . objectPermission . memoryPermissionBinding testBinding)
          allMemoryPermissions
          @?= ["can_read", "can_record", "can_distill", "can_forget", "can_administer"],
      testCase "each action carries its own coarse scope" do
        fmap
          (memoryCoarseScopeText . coarseScope . memoryPermissionBinding testBinding)
          allMemoryPermissions
          @?= ["kioku:read", "kioku:record", "kioku:distill", "kioku:forget", "kioku:admin"]
    ]

contextTests :: TestTree
contextTests =
  testGroup
    "MemoryAccessContext"
    [ testCase "an assumed context grants every action" do
        let context = assumeAuthorizedMemoryContext spaceOne testActor
        fmap (`memoryContextAllows` context) allMemoryPermissions
          @?= replicate 5 True,
      testCase "an assumed context observed nothing, so it pins nothing" do
        memoryContextFreshness (assumeAuthorizedMemoryContext spaceOne testActor)
          @?= MemoryFreshnessDefault,
      testCase "an assumed context names the space it was assumed for" do
        memoryContextSpace (assumeAuthorizedMemoryContext spaceOne testActor) @?= spaceOne,
      testCase "an assumed context names its actor" do
        memoryContextActor (assumeAuthorizedMemoryContext spaceOne testActor) @?= testActor,
      testCase "a context carrying a decision pins later reads to it" do
        let token = expectRight (mkMemoryDecisionToken "rev-42")
            context =
              Internal.MemoryAccessContext
                { Internal.memorySpaceId = spaceOne,
                  Internal.actor = testActor,
                  Internal.grantedPermissions = Set.singleton MemoryRead,
                  Internal.decisionToken = Just token
                }
        memoryContextFreshness context @?= atLeastAsFresh token
        memoryContextDecisionToken context @?= Just token,
      testCase "a read context cannot be spent on a write" do
        -- The narrow context above is the one that matters. An assumed context grants
        -- everything by construction, so only a minted one can demonstrate that the granted
        -- set is actually consulted.
        let context =
              Internal.MemoryAccessContext
                { Internal.memorySpaceId = spaceOne,
                  Internal.actor = testActor,
                  Internal.grantedPermissions = Set.singleton MemoryRead,
                  Internal.decisionToken = Nothing
                }
        memoryContextAllows MemoryRead context @?= True
        memoryContextAllows MemoryForget context @?= False
        memoryContextPermissions context @?= Set.singleton MemoryRead
    ]

testActor :: MemoryActor
testActor = MemoryActor (expectRight (mkPrincipalRef "person_01h9xk3v7hf8b9c0d1e2f3g4h5"))

spaceOne, spaceTwo :: MemorySpaceId
spaceOne = expectRight (mkMemorySpaceId "space_one")
spaceTwo = expectRight (mkMemorySpaceId "space_two")

-- | A binding a host might plausibly write. Kioku ships no default one, so a test has to supply
-- its own — which is the property being demonstrated as much as it is test scaffolding.
testBinding :: MemoryAuthorizationBinding
testBinding =
  expectRight
    ( mkMemoryAuthorizationBinding
        (expectRight (mkMemoryObjectType "memory_space"))
        fullBindings
    )

fullBindings :: [(MemoryPermission, MemoryPermissionBinding)]
fullBindings =
  [ binding MemoryRead "kioku:read" "can_read",
    binding MemoryRecord "kioku:record" "can_record",
    binding MemoryDistill "kioku:distill" "can_distill",
    binding MemoryForget "kioku:forget" "can_forget",
    binding MemoryAdmin "kioku:admin" "can_administer"
  ]
  where
    binding permission scope name =
      ( permission,
        MemoryPermissionBinding
          { coarseScope = expectRight (mkMemoryCoarseScope scope),
            objectPermission = expectRight (mkMemoryPermissionName name)
          }
      )

roundTrip :: (ToJSON a, FromJSON a, Eq a, Show a) => String -> a -> TestTree
roundTrip name value =
  testCase name (decode (encode value) @?= Just value)

assertLeft :: (Show a) => String -> Either Text a -> IO ()
assertLeft label = \case
  Left _ -> pure ()
  Right unexpected -> fail (label <> ": expected rejection, got " <> show unexpected)

assertRight :: (Show a) => Either Text a -> IO ()
assertRight = \case
  Right _ -> pure ()
  Left message -> fail ("expected acceptance, got: " <> Text.unpack message)

expectRight :: Either Text a -> a
expectRight = either (error . Text.unpack) id
