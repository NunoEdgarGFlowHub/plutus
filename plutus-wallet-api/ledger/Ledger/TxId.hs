{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DerivingVia       #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# OPTIONS_GHC -fno-strictness   #-}
-- | The type of transaction IDs
module Ledger.TxId(
    TxId (..)
    ) where

import           Codec.Serialise.Class     (Serialise)
import           Data.Aeson                (FromJSON, ToJSON)
import qualified Data.ByteString.Lazy      as BSL
import           Data.Text.Prettyprint.Doc (Pretty)
import           GHC.Generics              (Generic)
import           IOTS                      (IotsType)
import qualified Language.PlutusTx         as PlutusTx
import qualified Language.PlutusTx.Prelude as PlutusTx
import           LedgerBytes               (LedgerBytes(..))
import           Ledger.Orphans            ()
import           Schema                    (ToSchema)

-- | A transaction ID, using a SHA256 hash as the transaction id.
newtype TxId = TxId { getTxId :: BSL.ByteString }
    deriving (Eq, Ord, Generic, Show)
    deriving anyclass (ToJSON, FromJSON, ToSchema, IotsType)
    deriving newtype (PlutusTx.Eq, PlutusTx.Ord, Serialise)
    deriving (Pretty) via LedgerBytes

PlutusTx.makeLift ''TxId
PlutusTx.makeIsData ''TxId
