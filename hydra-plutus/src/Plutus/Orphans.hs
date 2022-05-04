{-# OPTIONS_GHC -Wno-orphans #-}

-- | Orphans instances partly copied from Plutus, partly coming from us for test
-- purpose.
module Plutus.Orphans where

import Hydra.Prelude

import qualified Data.Aeson as Aeson
import Plutus.V1.Ledger.Api (
  CurrencySymbol,
  POSIXTime (..),
  TokenName,
  UpperBound (..),
  ValidatorHash,
  Value,
  upperBound,
 )
import qualified PlutusTx.AssocMap as AssocMap
import PlutusTx.Prelude (BuiltinByteString, toBuiltin)

instance Arbitrary BuiltinByteString where
  arbitrary = toBuiltin <$> (arbitrary :: Gen ByteString)

instance Arbitrary TokenName where
  arbitrary = genericArbitrary
  shrink = genericShrink

instance Arbitrary CurrencySymbol where
  arbitrary = genericArbitrary
  shrink = genericShrink

instance Arbitrary Value where
  arbitrary = genericArbitrary
  shrink = genericShrink

instance (Arbitrary k, Arbitrary v) => Arbitrary (AssocMap.Map k v) where
  arbitrary = AssocMap.fromList <$> arbitrary

instance Arbitrary POSIXTime where
  arbitrary = POSIXTime <$> arbitrary

instance Arbitrary a => Arbitrary (UpperBound a) where
  arbitrary = upperBound <$> arbitrary

instance ToJSON ValidatorHash where
  toJSON = Aeson.String . show
