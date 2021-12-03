{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-deprecations #-}

-- | Smart constructors for creating Hydra protocol transactions to be used in
-- the 'Hydra.Chain.Direct' way of talking to the main-chain.
--
-- This module also encapsulates the transaction format used when talking to the
-- cardano-node, which is currently different from the 'Hydra.Ledger.Cardano',
-- thus we have not yet "reached" 'isomorphism'.
module Hydra.Chain.Direct.Tx where

import Hydra.Prelude

import Cardano.Binary (serialize)
import Cardano.Ledger.Address (Addr (Addr))
import Cardano.Ledger.Alonzo (Script)
import Cardano.Ledger.Alonzo.Data (Data (Data), DataHash, getPlutusData, hashData)
import Cardano.Ledger.Alonzo.Language (Language (PlutusV1))
import Cardano.Ledger.Alonzo.Scripts (ExUnits (..), Script (PlutusScript), Tag (Spend))
import Cardano.Ledger.Alonzo.Tx (IsValid (IsValid), ScriptPurpose (Spending), ValidatedTx (..), rdptr)
import Cardano.Ledger.Alonzo.TxBody (TxBody (..), TxOut (TxOut))
import Cardano.Ledger.Alonzo.TxInfo (transKeyHash)
import Cardano.Ledger.Alonzo.TxWitness (RdmrPtr (RdmrPtr), Redeemers (..), TxDats (..), TxWitness (..), unRedeemers, unTxDats)
import Cardano.Ledger.Crypto (StandardCrypto)
import Cardano.Ledger.Era (hashScript)
import qualified Cardano.Ledger.SafeHash as SafeHash
import Cardano.Ledger.Shelley.API (
  Coin (..),
  Credential (ScriptHashObj),
  Network (Testnet),
  ScriptHash,
  StakeReference (StakeRefNull),
  StrictMaybe (..),
  TxId (TxId),
  TxIn (TxIn),
  VKey (VKey),
  Wdrl (Wdrl),
  hashKey,
  unUTxO,
 )
import Cardano.Ledger.ShelleyMA.Timelocks (ValidityInterval (..))
import Cardano.Ledger.Val (inject)
import qualified Data.Aeson as Aeson
import qualified Data.Map as Map
import qualified Data.Sequence.Strict as StrictSeq
import qualified Data.Set as Set
import Data.Time (Day (ModifiedJulianDay), UTCTime (UTCTime))
import Hydra.Chain (HeadParameters (..), OnChainTx (..))
import Hydra.Chain.Direct.Util (Era, VerificationKey)
import qualified Hydra.Contract.MockCommit as MockCommit
import qualified Hydra.Contract.MockHead as MockHead
import qualified Hydra.Contract.MockInitial as MockInitial
import Hydra.Data.ContestationPeriod (contestationPeriodFromDiffTime, contestationPeriodToDiffTime)
import Hydra.Data.Party (partyFromVerKey, partyToVerKey)
import qualified Hydra.Data.Party as OnChain
import Hydra.Data.Utxo (fromByteString)
import qualified Hydra.Data.Utxo as OnChain
import Hydra.Ledger (balance)
import Hydra.Ledger.Cardano (CardanoTx, IsShelleyBasedEra (shelleyBasedEra), Utxo, Utxo' (Utxo), toLedgerUtxo, toMaryValue, toShelleyTxIn, toShelleyTxOut, utxoPairs)
import qualified Hydra.Ledger.Cardano as Api
import Hydra.Party (Party (Party), vkey)
import Hydra.Snapshot (SnapshotNumber)
import Ledger.Value (AssetClass (..), currencyMPSHash)
import Plutus.V1.Ledger.Api (FromData, MintingPolicyHash, PubKeyHash (..), fromData, toData)
import qualified Plutus.V1.Ledger.Api as Plutus
import Plutus.V1.Ledger.Value (assetClass, currencySymbol, tokenName)

-- TODO(SN): parameterize
network :: Network
network = Testnet

-- * Post Hydra Head transactions

-- | Maintains information needed to construct on-chain transactions
-- depending on the current state of the head.
data OnChainHeadState
  = None
  | Initial
      { -- | The state machine UTxO produced by the Init transaction
        -- This output should always be present and 'threaded' across all
        -- transactions.
        -- NOTE(SN): The Head's identifier is somewhat encoded in the TxOut's address
        threadOutput :: (TxIn StandardCrypto, TxOut Era, Data Era)
      , initials :: [(TxIn StandardCrypto, TxOut Era, Data Era)]
      , commits :: [(TxIn StandardCrypto, TxOut Era, Data Era)]
      }
  | OpenOrClosed
      { -- | The state machine UTxO produced by the Init transaction
        -- This output should always be present and 'threaded' across all
        -- transactions.
        -- NOTE(SN): The Head's identifier is somewhat encoded in the TxOut's address
        threadOutput :: (TxIn StandardCrypto, TxOut Era, Data Era)
      }
  | Final
  deriving (Eq, Show, Generic)

-- FIXME: should not be hardcoded, for testing purposes only
threadToken :: AssetClass
threadToken = assetClass (currencySymbol "hydra") (tokenName "token")

-- FIXME: should not be hardcoded
policyId :: MintingPolicyHash
(policyId, _) = first currencyMPSHash (unAssetClass threadToken)

-- | Create the init transaction from some 'HeadParameters' and a single TxIn
-- which will be used as unique parameter for minting NFTs.
initTx ::
  -- | Participant's cardano public keys.
  [VerificationKey] ->
  HeadParameters ->
  TxIn StandardCrypto ->
  ValidatedTx Era
initTx cardanoKeys HeadParameters{contestationPeriod, parties} txIn =
  mkUnsignedTx body dats (Redeemers mempty) mempty
 where
  body =
    TxBody
      { inputs = Set.singleton txIn
      , collateral = mempty
      , outputs = StrictSeq.fromList (headOut : initials)
      , txcerts = mempty
      , txwdrls = Wdrl mempty
      , txfee = Coin 0
      , txvldt = ValidityInterval SNothing SNothing
      , txUpdates = SNothing
      , reqSignerHashes = mempty
      , mint = mempty
      , scriptIntegrityHash = SNothing
      , adHash = SNothing
      , txnetworkid = SNothing
      }

  dats =
    TxDats $
      Map.fromList $
        (headDatumHash, headDatum) :
          [(initialDatumHash vkey, initialDatum vkey) | vkey <- cardanoKeys]

  headOut = TxOut headAddress headValue (SJust headDatumHash)

  headAddress = scriptAddr $ plutusScript $ MockHead.validatorScript policyId

  -- REVIEW(SN): how much to store here / minUtxoValue / depending on assets?
  headValue = inject (Coin 2000000)

  headDatumHash = hashData @Era headDatum

  headDatum =
    Data . toData $
      MockHead.Initial
        (contestationPeriodFromDiffTime contestationPeriod)
        (map (partyFromVerKey . vkey) parties)

  initials = map mkInitial cardanoKeys

  mkInitial = TxOut @Era initialAddress initialValue . SJust . initialDatumHash

  initialAddress = scriptAddr $ plutusScript MockInitial.validatorScript

  -- TODO: should really be the minted PTs plus some ADA to make the ledger happy
  initialValue = headValue

  initialDatumHash = hashData @Era . initialDatum

  initialDatum vkey =
    let pubKeyHash = transKeyHash $ hashKey @StandardCrypto $ VKey vkey
     in Data . toData $ MockInitial.datum pubKeyHash

-- | Craft a commit transaction which includes the "committed" utxo as a datum.
-- TODO(SN): Eventually, this might not be necessary as the 'Utxo tx' would need
-- to be inputs of this transaction.
commitTx ::
  Party ->
  -- | A single UTxO to commit to the Head
  -- We currently limit committing one UTxO to the head because of size limitations.
  Maybe (Api.TxIn, Api.TxOut Api.CtxUTxO Api.Era) ->
  -- | The inital output (sent to each party) which should contain the PT and is
  -- locked by initial script
  (TxIn StandardCrypto, PubKeyHash) ->
  ValidatedTx Era
commitTx party utxo (initialIn, pkh) =
  mkUnsignedTx body datums redeemers scripts
 where
  body =
    TxBody
      { inputs =
          Set.singleton initialIn
            <> maybe mempty (Set.singleton . toShelleyTxIn . fst) utxo
      , collateral = mempty
      , outputs =
          StrictSeq.fromList
            [ TxOut
                (scriptAddr commitScript)
                (inject $ Coin 2000000) -- TODO: Value of utxo + whatever is in initialIn
                (SJust $ hashData @Era commitDatum)
            ]
      , txcerts = mempty
      , txwdrls = Wdrl mempty
      , txfee = Coin 0
      , txvldt = ValidityInterval SNothing SNothing
      , txUpdates = SNothing
      , reqSignerHashes = mempty
      , mint = mempty
      , scriptIntegrityHash = SNothing
      , adHash = SNothing
      , txnetworkid = SNothing
      }

  datums =
    datumsFromList [initialDatum, commitDatum]

  initialDatum = Data . toData $ MockInitial.datum pkh

  redeemers =
    redeemersFromList
      [(rdptr body (Spending initialIn), (initialRedeemer, ExUnits 0 0))]

  initialRedeemer = Data . toData $ MockInitial.redeemer ()

  scripts = fromList $ map withScriptHash [initialScript]

  initialScript = plutusScript MockInitial.validatorScript

  commitScript = plutusScript MockCommit.validatorScript

  commitDatum =
    Data . toData $
      MockCommit.datum (partyFromVerKey $ vkey party, commitUtxo)

  commitUtxo = fromByteString $
    toStrict $
      Aeson.encode $ case utxo of
        Nothing -> mempty
        Just (i, o) -> Utxo $ Map.singleton i o

-- | Create a transaction collecting all "committed" utxo and opening a Head,
-- i.e. driving the Head script state.
collectComTx ::
  -- | Committed UTxO to become U0 in the Head ledger state.
  -- This is only used as a datum passed to the Head state machine script.
  Utxo ->
  -- | Everything needed to spend the Head state-machine output.
  -- FIXME(SN): should also contain some Head identifier/address and stored Value (maybe the TxOut + Data?)
  (TxIn StandardCrypto, Data Era) ->
  -- | Data needed to spend the commit output produced by each party.
  -- Should contain the PT and is locked by @ν_commit@ script.
  Map (TxIn StandardCrypto) (Data Era) ->
  ValidatedTx Era
-- TODO(SN): utxo unused means other participants would not "see" the opened
-- utxo when observing. Right now, they would be trusting the OCV checks this
-- and construct their "world view" from observed commit txs in the HeadLogic
collectComTx utxo (headInput, headDatumBefore) _commits =
  mkUnsignedTx body datums redeemers scripts
 where
  body =
    TxBody
      { inputs = Set.fromList [headInput] <> Map.keysSet (unUTxO (toLedgerUtxo utxo))
      , collateral = mempty
      , outputs =
          StrictSeq.fromList
            [ TxOut
                (scriptAddr headScript)
                (inject (Coin 2000000) <> committedValue)
                (SJust $ hashData @Era headDatumAfter)
            ]
      , txcerts = mempty
      , txwdrls = Wdrl mempty
      , txfee = Coin 0
      , txvldt = ValidityInterval SNothing SNothing
      , txUpdates = SNothing
      , reqSignerHashes = mempty
      , mint = mempty
      , scriptIntegrityHash = SNothing
      , adHash = SNothing
      , txnetworkid = SNothing
      }

  committedValue = toMaryValue $ balance @CardanoTx utxo

  datums =
    datumsFromList [headDatumBefore, headDatumAfter]

  headDatumAfter = Data $ toData MockHead.Open

  redeemers =
    redeemersFromList [(rdptr body (Spending headInput), (headRedeemer, ExUnits 0 0))]

  headRedeemer = Data $ toData MockHead.CollectCom

  scripts = fromList $ map withScriptHash [headScript]

  headScript = plutusScript $ MockHead.validatorScript policyId

-- | Create a transaction closing a head with given snapshot number and utxo.
closeTx ::
  SnapshotNumber ->
  -- | Snapshotted Utxo to close the Head with.
  Utxo ->
  -- | Everything needed to spend the Head state-machine output.
  -- FIXME(SN): should also contain some Head identifier/address and stored Value (maybe the TxOut + Data?)
  (TxIn StandardCrypto, Data Era) ->
  ValidatedTx Era
closeTx snapshotNumber _utxo (headInput, headDatumBefore) =
  mkUnsignedTx body datums redeemers scripts
 where
  body =
    TxBody
      { inputs = Set.fromList [headInput]
      , collateral = mempty
      , outputs =
          StrictSeq.fromList
            [ TxOut
                (scriptAddr headScript)
                (inject $ Coin 2000000) -- TODO: This should be the total of commit outputs
                (SJust $ hashData @Era headDatumAfter)
            ]
      , txcerts = mempty
      , txwdrls = Wdrl mempty
      , txfee = Coin 0
      , txvldt = ValidityInterval SNothing SNothing
      , txUpdates = SNothing
      , reqSignerHashes = mempty
      , mint = mempty
      , scriptIntegrityHash = SNothing
      , adHash = SNothing
      , txnetworkid = SNothing
      }

  datums =
    datumsFromList [headDatumBefore, headDatumAfter]

  -- TODO(SN): store contestation deadline as tx validity range end +
  -- contestation period in Datum or compute in observeCloseTx?
  headDatumAfter = Data $ toData MockHead.Closed

  redeemers =
    redeemersFromList
      [(rdptr body (Spending headInput), (headRedeemer, ExUnits 0 0))]

  headRedeemer = Data $ toData $ MockHead.Close onChainSnapshotNumber

  onChainSnapshotNumber = fromIntegral snapshotNumber

  scripts = fromList $ map withScriptHash [headScript]

  headScript = plutusScript $ MockHead.validatorScript policyId

fanoutTx ::
  -- | Snapshotted Utxo to fanout on layer 1
  Utxo ->
  -- | Everything needed to spend the Head state-machine output.
  -- FIXME(SN): should also contain some Head identifier/address and stored Value (maybe the TxOut + Data?)
  (TxIn StandardCrypto, Data Era) ->
  ValidatedTx Era
fanoutTx utxo (headInput, headDatumBefore) =
  mkUnsignedTx body datums redeemers scripts
 where
  body =
    TxBody
      { inputs = Set.fromList [headInput]
      , collateral = mempty
      , outputs =
          StrictSeq.fromList outs
      , txcerts = mempty
      , txwdrls = Wdrl mempty
      , txfee = Coin 0
      , txvldt = ValidityInterval SNothing SNothing
      , txUpdates = SNothing
      , reqSignerHashes = mempty
      , mint = mempty
      , scriptIntegrityHash = SNothing
      , adHash = SNothing
      , txnetworkid = SNothing
      }

  outs =
    [ -- NOTE: we probably don't need an output for the head SM
      -- which we don't use anyway
      TxOut
        (scriptAddr headScript)
        (inject $ Coin 2000000)
        (SJust $ hashData @Era headDatumAfter)
        -- TODO: add utxo outputs
    ]
      <> map (toShelleyTxOut shelleyBasedEra . snd) (utxoPairs utxo)

  datums =
    datumsFromList [headDatumBefore, headDatumAfter]

  headDatumAfter = Data $ toData MockHead.Final

  redeemers =
    redeemersFromList
      [(rdptr body (Spending headInput), (headRedeemer, ExUnits 0 0))]

  headRedeemer = Data $ toData MockHead.Fanout

  scripts = fromList $ map withScriptHash [headScript]

  headScript = plutusScript $ MockHead.validatorScript policyId

data AbortTxError = OverlappingInputs
  deriving (Show)

-- | Create transaction which aborts a head by spending the Head output and all
-- other "initial" outputs.
abortTx ::
  -- | Everything needed to spend the Head state-machine output.
  (TxIn StandardCrypto, Data Era) ->
  -- | Data needed to spend the inital output sent to each party to the Head
  -- which should contain the PT and is locked by initial script.
  Map (TxIn StandardCrypto) (Data Era) ->
  Either AbortTxError (ValidatedTx Era)
abortTx (headInput, headDatum) initialInputs
  | isJust (lookup headInput initialInputs) =
    Left OverlappingInputs
  | otherwise =
    Right $ mkUnsignedTx body datums redeemers scripts
 where
  body =
    TxBody
      { inputs = Set.singleton headInput <> Map.keysSet initialInputs
      , collateral = mempty
      , outputs =
          StrictSeq.fromList
            [ TxOut
                (scriptAddr headScript)
                (inject $ Coin 2000000) -- TODO: This really needs to be passed as argument
                (SJust $ hashData @Era abortDatum)
            ]
      , txcerts = mempty
      , txwdrls = Wdrl mempty
      , txfee = Coin 0
      , txvldt = ValidityInterval SNothing SNothing
      , txUpdates = SNothing
      , reqSignerHashes = mempty
      , mint = mempty
      , scriptIntegrityHash = SNothing
      , adHash = SNothing
      , txnetworkid = SNothing
      }

  scripts =
    fromList $
      map withScriptHash $
        headScript : [initialScript | not (null initialInputs)]

  initialScript = plutusScript MockInitial.validatorScript

  headScript = plutusScript $ MockHead.validatorScript policyId

  redeemers =
    redeemersFromList $
      (rdptr body (Spending headInput), (headRedeemer, ExUnits 0 0)) : initialRedeemers

  headRedeemer = Data $ toData MockHead.Abort

  initialRedeemers =
    map
      ( \txin ->
          ( rdptr body (Spending txin)
          , (Data $ toData $ Plutus.getRedeemer $ MockInitial.redeemer (), ExUnits 0 0)
          )
      )
      $ Map.keys initialInputs

  -- NOTE: Those datums contain the datum of the spent state-machine input, but
  -- also, the datum of the created output which is necessary for the
  -- state-machine on-chain validator to control the correctness of the
  -- transition.
  datums =
    datumsFromList $ abortDatum : headDatum : Map.elems initialInputs

  abortDatum =
    Data $ toData MockHead.Final

-- * Observe Hydra Head transactions

-- XXX(SN): We should log decisions why a tx is not an initTx etc. instead of
-- only returning a Maybe, i.e. 'Either Reason (OnChainTx tx, OnChainHeadState)'
observeInitTx :: Party -> ValidatedTx Era -> Maybe (OnChainTx CardanoTx, OnChainHeadState)
observeInitTx party ValidatedTx{wits, body} = do
  (dh, headDatum, MockHead.Initial cp ps) <- getFirst $ foldMap (First . decodeHeadDatum) datumsList
  let parties = map convertParty ps
  let cperiod = contestationPeriodToDiffTime cp
  guard $ party `elem` parties
  (i, o) <- getFirst $ foldMap (First . findSmOutput dh) indexedOutputs
  pure
    ( OnInitTx cperiod parties
    , Initial
        { threadOutput = (i, o, headDatum)
        , initials
        , commits = mempty
        }
    )
 where
  decodeHeadDatum (dh, d) =
    (dh,d,) <$> fromData (getPlutusData d)

  findSmOutput dh (ix, o@(TxOut _ _ dh')) =
    guard (SJust dh == dh') $> (i, o)
   where
    i = TxIn (TxId $ SafeHash.hashAnnotated body) ix

  datumsList = Map.toList datums

  datums = unTxDats $ txdats wits

  indexedOutputs =
    zip [0 ..] (toList (outputs body))

  initials =
    let initialOutputs = filter (isInitial . snd) indexedOutputs
     in mapMaybe mkInitial initialOutputs

  mkInitial (ix, txOut) =
    (mkTxIn ix,txOut,) <$> lookupDatum wits txOut

  mkTxIn ix = TxIn (TxId $ SafeHash.hashAnnotated body) ix

  isInitial (TxOut addr _ _) =
    addr == scriptAddr initialScript

  initialScript = plutusScript MockInitial.validatorScript

convertParty :: OnChain.Party -> Party
convertParty = Party . partyToVerKey

-- | Identify a commit tx by looking for an output which pays to v_commit.
observeCommitTx :: ValidatedTx Era -> Maybe (OnChainTx CardanoTx, (TxIn StandardCrypto, TxOut Era, Data Era))
observeCommitTx tx@ValidatedTx{wits} = do
  txOut <- snd <$> findScriptOutput (utxoFromTx tx) commitScript
  dat <- lookupDatum wits txOut
  (party, utxo) <- fromData $ getPlutusData dat
  (,undefined) . OnCommitTx (convertParty party) <$> convertUtxo utxo
 where
  commitScript = plutusScript MockCommit.validatorScript

  convertUtxo = Aeson.decodeStrict' . OnChain.toByteString

-- TODO(SN): obviously the observeCollectComTx/observeAbortTx can be DRYed.. deliberately hold back on it though

-- | Identify a collectCom tx by lookup up the input spending the Head output
-- and decoding its redeemer.
observeCollectComTx ::
  -- | A Utxo set to lookup tx inputs
  Map (TxIn StandardCrypto) (TxOut Era) ->
  ValidatedTx Era ->
  Maybe (OnChainTx CardanoTx, OnChainHeadState)
observeCollectComTx utxo tx = do
  headInput <- fst <$> findScriptOutput utxo headScript
  redeemer <- getRedeemerSpending tx headInput
  case redeemer of
    MockHead.CollectCom -> do
      (newHeadInput, newHeadOutput) <- findScriptOutput (utxoFromTx tx) headScript
      newHeadDatum <- lookupDatum (wits tx) newHeadOutput
      pure
        ( OnCollectComTx
        , OpenOrClosed{threadOutput = (newHeadInput, newHeadOutput, newHeadDatum)}
        )
    _ -> Nothing
 where
  headScript = plutusScript $ MockHead.validatorScript policyId

-- | Identify a close tx by lookup up the input spending the Head output and
-- decoding its redeemer.
observeCloseTx ::
  -- | A Utxo set to lookup tx inputs
  Map (TxIn StandardCrypto) (TxOut Era) ->
  ValidatedTx Era ->
  Maybe (OnChainTx CardanoTx, OnChainHeadState)
observeCloseTx utxo tx = do
  headInput <- fst <$> findScriptOutput utxo headScript
  redeemer <- getRedeemerSpending tx headInput
  case redeemer of
    MockHead.Close sn -> do
      (newHeadInput, newHeadOutput) <- findScriptOutput (utxoFromTx tx) headScript
      newHeadDatum <- lookupDatum (wits tx) newHeadOutput
      let snapshotNumber = fromIntegral sn
      pure
        ( OnCloseTx{contestationDeadline, snapshotNumber}
        , OpenOrClosed{threadOutput = (newHeadInput, newHeadOutput, newHeadDatum)}
        )
    _ -> Nothing
 where
  headScript = plutusScript $ MockHead.validatorScript policyId

  -- FIXME(SN): store in/read from datum
  contestationDeadline = UTCTime (ModifiedJulianDay 0) 0

-- | Identify a fanout tx by lookup up the input spending the Head output and
-- decoding its redeemer.
--
-- TODO: Ideally, the fanout does not produce any state-machine output. That
-- means, to observe it, we need to look for a transaction with an input spent
-- from a known script (the head state machine script) with a "fanout" redeemer.
observeFanoutTx ::
  -- | A Utxo set to lookup tx inputs
  Map (TxIn StandardCrypto) (TxOut Era) ->
  ValidatedTx Era ->
  Maybe (OnChainTx CardanoTx, OnChainHeadState)
observeFanoutTx utxo tx = do
  headInput <- fst <$> findScriptOutput utxo headScript
  getRedeemerSpending tx headInput >>= \case
    MockHead.Fanout -> pure (OnFanoutTx, Final)
    _ -> Nothing
 where
  headScript = plutusScript $ MockHead.validatorScript policyId

-- | Identify an abort tx by looking up the input spending the Head output and
-- decoding its redeemer.
observeAbortTx ::
  -- | A Utxo set to lookup tx inputs
  Map (TxIn StandardCrypto) (TxOut Era) ->
  ValidatedTx Era ->
  Maybe (OnChainTx CardanoTx, OnChainHeadState)
observeAbortTx utxo tx = do
  headInput <- fst <$> findScriptOutput utxo headScript
  getRedeemerSpending tx headInput >>= \case
    MockHead.Abort -> pure (OnAbortTx, Final)
    _ -> Nothing
 where
  -- FIXME(SN): make sure this is aborting "the right head / your head" by not hard-coding policyId
  headScript = plutusScript $ MockHead.validatorScript policyId

-- * Functions related to OnChainHeadState

-- | Provide a UTXO map for given OnChainHeadState. Used by the TinyWallet and
-- the direct chain component to lookup inputs for balancing / constructing txs.
-- XXX(SN): This is a hint that we might want to track the Utxo directly?
knownUtxo :: OnChainHeadState -> Map (TxIn StandardCrypto) (TxOut Era)
knownUtxo = \case
  Initial{threadOutput, initials} ->
    Map.fromList . map onlyUtxo $ (threadOutput : initials)
  OpenOrClosed{threadOutput = (i, o, _)} ->
    Map.singleton i o
  _ ->
    mempty
 where
  onlyUtxo (i, o, _) = (i, o)

-- | Look for the "initial" which corresponds to given cardano verification key.
ownInitial :: VerificationKey -> [(TxIn StandardCrypto, TxOut Era, Data Era)] -> Maybe (TxIn StandardCrypto, PubKeyHash)
ownInitial vkey =
  foldl' go Nothing
 where
  go (Just x) _ = Just x
  go Nothing (i, _, dat) = do
    pkh <- fromData (getPlutusData dat)
    guard $ pkh == transKeyHash (hashKey @StandardCrypto $ VKey vkey)
    pure (i, pkh)

-- * Helpers

mkUnsignedTx ::
  TxBody Era ->
  TxDats Era ->
  Redeemers Era ->
  Map (ScriptHash StandardCrypto) (Script Era) ->
  ValidatedTx Era
mkUnsignedTx body datums redeemers scripts =
  ValidatedTx
    { body
    , wits =
        TxWitness
          { txwitsVKey = mempty
          , txwitsBoot = mempty
          , txscripts = scripts
          , txdats = datums
          , txrdmrs = redeemers
          }
    , isValid = IsValid True -- REVIEW(SN): no idea of the semantics of this
    , auxiliaryData = SNothing
    }

-- | Get the ledger address for a given plutus script.
scriptAddr :: Script Era -> Addr StandardCrypto
scriptAddr script =
  Addr
    network
    (ScriptHashObj $ hashScript @Era script)
    -- REVIEW(SN): stake head funds?
    StakeRefNull

plutusScript :: Plutus.Script -> Script Era
plutusScript = PlutusScript PlutusV1 . toShort . fromLazy . serialize

withDataHash :: Data Era -> (DataHash StandardCrypto, Data Era)
withDataHash d = (hashData d, d)

withScriptHash :: Script Era -> (ScriptHash StandardCrypto, Script Era)
withScriptHash s = (hashScript @Era s, s)

datumsFromList :: [Data Era] -> TxDats Era
datumsFromList = TxDats . Map.fromList . fmap withDataHash

-- | Slightly unsafe, as it drops `SNothing` values from the list silently.
redeemersFromList ::
  [(StrictMaybe RdmrPtr, (Data Era, ExUnits))] ->
  Redeemers Era
redeemersFromList =
  Redeemers . Map.fromList . foldl' hasRdmrPtr []
 where
  hasRdmrPtr acc = \case
    (SNothing, _) -> acc
    (SJust v, ex) -> (v, ex) : acc

-- | Lookup included datum of given 'TxOut'.
lookupDatum :: TxWitness Era -> TxOut Era -> Maybe (Data Era)
lookupDatum wits = \case
  (TxOut _ _ (SJust datumHash)) -> Map.lookup datumHash . unTxDats $ txdats wits
  _ -> Nothing

-- | Lookup and decode redeemer which is spending a given 'TxIn'.
getRedeemerSpending :: FromData a => ValidatedTx Era -> TxIn StandardCrypto -> Maybe a
getRedeemerSpending ValidatedTx{body, wits} txIn = do
  idx <- Set.lookupIndex txIn (inputs body)
  (d, _exUnits) <- Map.lookup (RdmrPtr Spend $ fromIntegral idx) redeemers
  fromData $ getPlutusData d
 where
  redeemers = unRedeemers $ txrdmrs wits

findScriptOutput ::
  Map (TxIn StandardCrypto) (TxOut Era) ->
  Script Era ->
  Maybe (TxIn StandardCrypto, TxOut Era)
findScriptOutput utxo script =
  find go $ Map.toList utxo
 where
  go (_, TxOut addr _ _) = addr == scriptAddr script

-- | Get the Utxo set created by given transaction.
-- TODO(SN): DRY with Hydra.Ledger.Cardano.utxoFromTx
utxoFromTx :: ValidatedTx Era -> Map (TxIn StandardCrypto) (TxOut Era)
utxoFromTx ValidatedTx{body} =
  Map.fromList $ zip (map mkTxIn [0 ..]) . toList $ outputs body
 where
  mkTxIn = TxIn (TxId $ SafeHash.hashAnnotated body)
