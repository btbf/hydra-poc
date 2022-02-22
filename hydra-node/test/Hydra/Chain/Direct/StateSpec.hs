module Hydra.Chain.Direct.StateSpec where

import Hydra.Cardano.Api
import Hydra.Prelude
import Test.Hydra.Prelude

import qualified Cardano.Api.UTxO as UTxO
import qualified Data.Set as Set
import Hydra.Chain (HeadParameters (..))
import Hydra.Chain.Direct.State (
  HeadStateKind (..),
  OnChainHeadState,
  SomeOnChainHeadState (..),
  TokHeadState (..),
  commit,
  getKnownUTxO,
  idleOnChainHeadState,
  initialize,
  observeTx,
  reifyState,
 )
import Hydra.Ledger.Cardano (genOneUTxOFor, genTxIn, genVerificationKey)
import Hydra.Party (Party)
import Test.QuickCheck (choose, elements, forAll, property, vector)

spec :: Spec
spec =
  describe "commit" $ do
    prop "consumes all inputs that are committed." $
      forAll genHydraContext $ \ctx ->
        forAll (genStInitialized ctx) $ \stInitialized ->
          forAll genSingleUTxO $ \utxo ->
            let tx = unsafeCommit utxo stInitialized
             in case observeTx tx stInitialized of
                  Just (_, SomeOnChainHeadState st') ->
                    let knownInputs = UTxO.inputSet (getKnownUTxO st')
                     in property (knownInputs `Set.disjoint` txInputSet tx)
                  Nothing ->
                    property False

--
-- Generators
--

-- Some 'global' (to all generator) context from which generators can pick
-- values for generation. This allows to write fairly independent generators
-- which however still make sense with one another within the context of a head.
--
-- For example, one can generate a head's _party_ from that global list, whereas
-- other functions may rely on all parties and thus, we need both generation to
-- be coherent.
data HydraContext = HydraContext
  { ctxVerificationKeys :: [VerificationKey PaymentKey]
  , ctxParties :: [Party]
  , ctxNetworkId :: NetworkId
  , ctxContestationPeriod :: DiffTime
  }
  deriving (Show)

genHydraContext :: Gen HydraContext
genHydraContext = do
  n <- choose (1, 10)
  ctxVerificationKeys <- replicateM n genVerificationKey
  ctxParties <- vector n
  ctxNetworkId <- Testnet . NetworkMagic <$> arbitrary
  ctxContestationPeriod <- arbitrary
  pure $
    HydraContext
      { ctxVerificationKeys
      , ctxParties
      , ctxNetworkId
      , ctxContestationPeriod
      }

genStIdle :: HydraContext -> Gen (OnChainHeadState 'StIdle)
genStIdle HydraContext{ctxVerificationKeys, ctxNetworkId, ctxParties} = do
  ownParty <- elements ctxParties
  ownVerificationKey <- elements ctxVerificationKeys
  pure $ idleOnChainHeadState ctxNetworkId ownVerificationKey ownParty

genStInitialized :: HydraContext -> Gen (OnChainHeadState 'StInitialized)
genStInitialized ctx@HydraContext{ctxParties, ctxContestationPeriod, ctxVerificationKeys} = do
  stIdle <- genStIdle ctx
  let headParameters = HeadParameters ctxContestationPeriod ctxParties
  seedInput <- genTxIn
  case observeTx (initialize headParameters ctxVerificationKeys seedInput stIdle) stIdle of
    Nothing -> error "failed to observe arbitrarily generated init tx?"
    Just (_, SomeOnChainHeadState st) ->
      case reifyState st of
        TkInitialized ->
          pure st
        _ ->
          error "expected 'Initialized' state after observing init but got something else!"

genSingleUTxO :: Gen UTxO
genSingleUTxO =
  genVerificationKey >>= genOneUTxOFor

--
-- Helpers
--

unsafeCommit :: HasCallStack => UTxO -> OnChainHeadState 'StInitialized -> Tx
unsafeCommit u =
  either (error . show) id . commit u
