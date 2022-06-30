{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}

-- | A helper module mostly wrapping the Alonzo.Tools'
-- 'evaluateTransactionExecutionUnits' with a much simpler API (just a plutus
-- script).
--
-- This is generally handy to measure the execution of Plutus code outside of any
-- context (e.g. an implementation of a data-structure on-chain or, as here,
-- data encoders).
module Test.Plutus.Validator (
  module Test.Plutus.Validator,
  ExUnits (..),
) where

import Hydra.Prelude hiding (label)

import Cardano.Binary (unsafeDeserialize')
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Data (Data (..), hashData)
import Cardano.Ledger.Alonzo.Language (Language (PlutusV1))
import Cardano.Ledger.Alonzo.Scripts (
  ExUnits (..),
  Script (..),
  Tag (..),
 )
import Cardano.Ledger.Alonzo.Tools (evaluateTransactionExecutionUnits)
import Cardano.Ledger.Alonzo.TxWitness (
  RdmrPtr (..),
  Redeemers (..),
  TxDats (..),
  TxWitness (..),
 )
import Cardano.Ledger.Babbage (BabbageEra)
import Cardano.Ledger.Babbage.PParams (PParams' (..))
import Cardano.Ledger.Babbage.Tx (
  IsValid (..),
  ValidatedTx (..),
 )
import Cardano.Ledger.Babbage.TxBody (
  TxBody (..),
  TxOut (..),
 )
import qualified Cardano.Ledger.Babbage.TxBody as Babbage
import Cardano.Ledger.BaseTypes (Network (..), TxIx (TxIx))
import Cardano.Ledger.Credential (
  Credential (..),
  StakeReference (..),
 )
import Cardano.Ledger.Crypto (StandardCrypto)
import Cardano.Ledger.Era (ValidateScript (hashScript))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Shelley.TxBody (Wdrl (..))
import qualified Cardano.Ledger.Shelley.UTxO as Ledger
import Cardano.Ledger.ShelleyMA.Timelocks (ValidityInterval (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Slotting.EpochInfo (fixedEpochInfo)
import Cardano.Slotting.Slot (EpochSize (EpochSize))
import Cardano.Slotting.Time (
  SystemStart (SystemStart),
  mkSlotLength,
 )
import Data.Array (array)
import qualified Data.ByteString as BS
import Data.Default (def)
import qualified Data.Map as Map
import Data.Maybe.Strict (StrictMaybe (..))
import qualified Data.Set as Set
import Hydra.Cardano.Api (PlutusScriptV2, fromPlutusScript)
import Hydra.Cardano.Api.PlutusScript (toLedgerScript)
import Plutus.V1.Ledger.Api (ScriptContext, Validator, getValidator)
import PlutusTx (BuiltinData, UnsafeFromData (..))
import qualified PlutusTx as Plutus
import PlutusTx.Prelude (check)
import Test.Cardano.Ledger.Alonzo.PlutusScripts (testingCostModelV1)
import qualified Prelude

-- TODO: DRY with hydra-plutus

-- | Wrap a typed validator to get the basic `Validator` signature which can be passed to
-- `Plutus.compile`. Vendored from `plutus-ledger`.
-- REVIEW: There might be better ways to name this than "wrap"
wrapValidator ::
  (UnsafeFromData datum, UnsafeFromData redeemer) =>
  (datum -> redeemer -> ScriptContext -> Bool) ->
  (BuiltinData -> BuiltinData -> BuiltinData -> ())
-- We can use unsafeFromBuiltinData here as we would fail immediately anyway if parsing failed
wrapValidator f d r p = check $ f (unsafeFromBuiltinData d) (unsafeFromBuiltinData r) (unsafeFromBuiltinData p)
{-# INLINEABLE wrapValidator #-}

--
-- Compare scripts to baselines
--

-- | Current (2022-04-01) mainchain parameters.
defaultMaxExecutionUnits :: ExUnits
defaultMaxExecutionUnits =
  ExUnits
    { exUnitsMem = 10_000_000
    , exUnitsSteps = 10_000_000_000
    }

distanceExUnits :: ExUnits -> ExUnits -> ExUnits
distanceExUnits (ExUnits m0 s0) (ExUnits m1 s1) =
  ExUnits
    (if m0 > m1 then m0 - m1 else m1 - m0)
    (if s0 > s1 then s0 - s1 else s1 - s0)

-- TODO: DRY with Hydra.Ledger.Cardano.Evaluate
evaluateScriptExecutionUnits ::
  Plutus.ToData a =>
  Validator ->
  a ->
  Either Text ExUnits
evaluateScriptExecutionUnits validator redeemer =
  case runIdentity (evaluateTransactionExecutionUnits pparams tx utxo epoch start costModels) of
    Right (toList -> [units]) ->
      first (("unexpected script failure: " <>) . show) units
    Right{} ->
      Left "executed more than one script?!"
    Left e ->
      Left ("unexpected failure: " <> show e)
 where
  (tx, utxo) = transactionFromScript validator redeemer
  costModels = array (PlutusV1, PlutusV1) [(PlutusV1, testingCostModelV1)]
  epoch = fixedEpochInfo (EpochSize 432000) (mkSlotLength 1)
  start = SystemStart $ Prelude.read "2017-09-23 21:44:51 UTC"
  pparams = def{_maxTxExUnits = ExUnits 9999999999 9999999999}

transactionFromScript ::
  Plutus.ToData a =>
  Validator ->
  a ->
  (ValidatedTx (BabbageEra StandardCrypto), Ledger.UTxO (BabbageEra StandardCrypto))
transactionFromScript validator redeemer =
  ( ValidatedTx
      { body = defaultTxBody
      , wits = defaultTxWits
      , isValid = IsValid True
      , auxiliaryData = SNothing
      }
  , Ledger.UTxO (fromList [(defaultTxIn, txOutFromScript)])
  )
 where
  script :: Script (BabbageEra StandardCrypto)
  script =
    toLedgerScript $ fromPlutusScript @PlutusScriptV2 $ getValidator validator

  scriptHash :: ScriptHash StandardCrypto
  scriptHash =
    hashScript @(BabbageEra StandardCrypto) script

  txOutFromScript :: TxOut (BabbageEra StandardCrypto)
  txOutFromScript =
    TxOut
      (Addr Testnet (ScriptHashObj scriptHash) StakeRefNull)
      mempty
      (Babbage.DatumHash $ hashData defaultDatum)
      SNothing

  defaultTxWits :: TxWitness (BabbageEra StandardCrypto)
  defaultTxWits =
    TxWitness
      mempty
      mempty
      (Map.fromList [(scriptHash, script)])
      ( TxDats $
          Map.fromList
            [
              ( hashData defaultDatum
              , defaultDatum
              )
            ]
      )
      ( Redeemers $
          Map.fromList
            [
              ( RdmrPtr Spend 0
              , (Data $ Plutus.toData redeemer, defaultExUnits)
              )
            ]
      )

  defaultDatum :: Data (BabbageEra StandardCrypto)
  defaultDatum = Data (Plutus.toData ())

  defaultExUnits :: ExUnits
  defaultExUnits = ExUnits 0 0

  defaultTxBody :: TxBody (BabbageEra StandardCrypto)
  defaultTxBody =
    TxBody
      { inputs = Set.singleton defaultTxIn
      , collateral = mempty
      , referenceInputs = mempty
      , outputs = mempty
      , collateralReturn = SNothing
      , totalCollateral = SNothing
      , txcerts = mempty
      , txwdrls = Wdrl mempty
      , txfee = mempty
      , txvldt = ValidityInterval SNothing SNothing
      , txUpdates = SNothing
      , reqSignerHashes = mempty
      , mint = mempty
      , scriptIntegrityHash = SNothing
      , adHash = SNothing
      , txnetworkid = SNothing
      }

  defaultTxIn :: TxIn StandardCrypto
  defaultTxIn = TxIn (unsafeDeserialize' $ BS.pack [88, 32] <> BS.replicate 32 0) (TxIx 0)
