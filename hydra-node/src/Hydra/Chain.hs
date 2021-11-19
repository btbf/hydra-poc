{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE UndecidableInstances #-}

module Hydra.Chain where

import Cardano.Prelude
import Control.Monad.Class.MonadThrow (MonadThrow)
import Data.Aeson (FromJSON, ToJSON)
import Data.Time (DiffTime, UTCTime)
import Hydra.Ledger (Tx, Utxo)
import Hydra.Party (Party)
import Hydra.Prelude (Arbitrary (arbitrary), genericArbitrary)
import Hydra.Snapshot (Snapshot, SnapshotNumber)

-- | Contains the head's parameters as established in the initial transaction.
data HeadParameters = HeadParameters
  { contestationPeriod :: DiffTime
  , parties :: [Party] -- NOTE(SN): The order of this list is important for leader selection.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Arbitrary HeadParameters where
  arbitrary = genericArbitrary

type ContestationPeriod = DiffTime

-- | Data type used to post transactions on chain. It holds everything to
-- construct corresponding Head protocol transactions.
data PostChainTx tx
  = InitTx {headParameters :: HeadParameters}
  | CommitTx {party :: Party, committed :: Utxo tx}
  | AbortTx {utxo :: Utxo tx}
  | CollectComTx {utxo :: Utxo tx}
  | CloseTx {snapshot :: Snapshot tx}
  | ContestTx {snapshot :: Snapshot tx}
  | FanoutTx {utxo :: Utxo tx}
  deriving stock (Generic)

deriving instance Tx tx => Eq (PostChainTx tx)
deriving instance Tx tx => Show (PostChainTx tx)
deriving instance Tx tx => ToJSON (PostChainTx tx)
deriving instance Tx tx => FromJSON (PostChainTx tx)

instance (Arbitrary tx, Arbitrary (Utxo tx)) => Arbitrary (PostChainTx tx) where
  arbitrary = genericArbitrary

-- REVIEW(SN): There is a similarly named type in plutus-ledger, so we might
-- want to rename this

-- | Describes transactions as seen on chain. Holds as minimal information as
-- possible to simplify observing the chain.
data OnChainTx tx
  = OnInitTx {contestationPeriod :: ContestationPeriod, parties :: [Party]}
  | OnCommitTx {party :: Party, committed :: Utxo tx}
  | OnAbortTx
  | OnCollectComTx
  | OnCloseTx {contestationDeadline :: UTCTime, snapshotNumber :: SnapshotNumber}
  | OnContestTx
  | OnFanoutTx
  | PostTxFailed
  deriving (Generic)

deriving instance Tx tx => Eq (OnChainTx tx)
deriving instance Tx tx => Show (OnChainTx tx)
deriving instance Tx tx => ToJSON (OnChainTx tx)
deriving instance Tx tx => FromJSON (OnChainTx tx)

instance (Arbitrary tx, Arbitrary (Utxo tx)) => Arbitrary (OnChainTx tx) where
  arbitrary = genericArbitrary

-- | Thrown a structurally invalid transaction is submitted through the chain
-- component. The transaction may be deemed invalid because it does not
-- satisfies pre-conditions fixed by our application (e.g. more than one UTXO is
-- committed).
data InvalidTxError
  = MoreThanOneUtxoCommitted
  deriving (Eq, Exception, Show)

-- | Handle to interface with the main chain network
newtype Chain tx m = Chain
  { -- | Construct and send a transaction to the main chain corresponding to the
    -- given 'OnChainTx' event.
    --
    -- Does at least throw 'InvalidTxError'.
    postTx :: MonadThrow m => PostChainTx tx -> m ()
  }

-- | Handle to interface observed transactions.
type ChainCallback tx m = OnChainTx tx -> m ()

-- | A type tying both posting and observing transactions into a single /Component/.
type ChainComponent tx m a = ChainCallback tx m -> (Chain tx m -> m a) -> m a
