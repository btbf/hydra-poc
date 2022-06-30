module Hydra.Cardano.Api.Lovelace where

import Hydra.Cardano.Api.Prelude

import qualified Cardano.Ledger.Coin as Ledger

-- * Extras

-- | Directly retrieve the amount of 'Lovelace' stored in a 'TxOut'.
txOutLovelace :: TxOut ctx era -> Lovelace
txOutLovelace (TxOut _ v _ _) = txOutValueToLovelace v

-- * Type Conversions

-- | Convert a cardano-ledger's 'Coin' into a cardano-api 'Lovelace'.
fromLedgerCoin :: Ledger.Coin -> Lovelace
fromLedgerCoin (Ledger.Coin n) = Lovelace n

-- | Convert a cardano-api's 'Lovelace' into a cardano-ledger's 'Coin'.
toLedgerCoin :: Lovelace -> Ledger.Coin
toLedgerCoin (Lovelace n) = Ledger.Coin n
