{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
module Vesting where
-- TRIM TO HERE
-- Vesting scheme as a PLC contract
import           Control.Lens                      ((&), (.~))
import           Control.Monad                     (void, when)
import           Control.Monad.Except              (throwError)
import           Data.Foldable                     (fold)
import qualified Data.Text                         as T

import           GHC.Generics                      (Generic)
import           Language.Plutus.Contract          hiding (when)
import qualified Language.Plutus.Contract.Typed.Tx as Typed
import qualified Language.PlutusTx                 as PlutusTx
import           Language.PlutusTx.Prelude         hiding (fold)
import           Ledger                            (Address, PubKey, Slot (Slot),
                                                    ValidatorScript, unitData)
import qualified Ledger.Ada                        as Ada
import qualified Ledger.AddressMap                 as AM
import qualified Ledger.Interval                   as Interval
import qualified Ledger.Slot                       as Slot
import qualified Ledger.Typed.Scripts              as Scripts
import           Ledger.Validation                 (PendingTx, PendingTx' (PendingTx, pendingTxValidRange))
import qualified Ledger.Validation                 as Validation
import           Ledger.Value                      (Value)
import qualified Ledger.Value                      as Value
import           Playground.Contract
import qualified Prelude                           as Haskell
import           Wallet.Emulator.Types             (walletPubKey)

{- |
    A simple vesting scheme. Money is locked by a contract and may only be
    retrieved after some time has passed.

    This is our first example of a contract that covers multiple transactions,
    with a contract state that changes over time.

    In our vesting scheme the money will be released in two _tranches_ (parts):
    A smaller part will be available after an initial number of slots have
    passed, and the entire amount will be released at the end. The owner of the
    vesting scheme does not have to take out all the money at once: They can
    take out any amount up to the total that has been released so far. The
    remaining funds stay locked and can be retrieved later.

    Let's start with the data types.

-}

type VestingSchema =
    BlockchainActions
        .\/ Endpoint "vest funds" ()
        .\/ Endpoint "retrieve funds" Value

-- | Tranche of a vesting scheme.
data VestingTranche = VestingTranche {
    vestingTrancheDate   :: Slot,
    vestingTrancheAmount :: Value
    } deriving Generic

PlutusTx.makeLift ''VestingTranche

-- | A vesting scheme consisting of two tranches. Each tranche defines a date
--   (slot) after which an additional amount can be spent.
data VestingParams = VestingParams {
    vestingTranche1 :: VestingTranche,
    vestingTranche2 :: VestingTranche,
    vestingOwner    :: PubKey
    } deriving Generic

PlutusTx.makeLift ''VestingParams

{-# INLINABLE totalAmount #-}
-- | The total amount vested
totalAmount :: VestingParams -> Value
totalAmount VestingParams{vestingTranche1,vestingTranche2} =
    vestingTrancheAmount vestingTranche1 + vestingTrancheAmount vestingTranche2

{-# INLINABLE availableFrom #-}
-- | The amount guaranteed to be available from a given tranche in a given slot range.
availableFrom :: VestingTranche -> Slot.SlotRange -> Value
availableFrom (VestingTranche d v) range =
    -- The valid range is an open-ended range starting from the tranche vesting date
    let validRange = Interval.from d
    -- If the valid range completely contains the argument range (meaning in particular
    -- that the start slot of the argument range is after the tranche vesting date), then
    -- the money in the tranche is available, otherwise nothing is available.
    in if validRange `Interval.contains` range then v else zero

availableAt :: VestingParams -> Slot -> Value
availableAt VestingParams{vestingTranche1, vestingTranche2} sl =
    let f VestingTranche{vestingTrancheDate, vestingTrancheAmount} =
            if sl >= vestingTrancheDate then vestingTrancheAmount else mempty
    in foldMap f [vestingTranche1, vestingTranche2]

{-# INLINABLE remainingFrom #-}
-- | The amount that has not been released from this tranche yet
remainingFrom :: VestingTranche -> Slot.SlotRange -> Value
remainingFrom t@VestingTranche{vestingTrancheAmount} range =
    vestingTrancheAmount - availableFrom t range

{-# INLINABLE validate #-}
validate :: VestingParams -> () -> () -> PendingTx -> Bool
validate VestingParams{vestingTranche1, vestingTranche2, vestingOwner} () () ptx@PendingTx{pendingTxValidRange} =
    let
        remainingActual  = Validation.valueLockedBy ptx (Validation.ownHash ptx)

        remainingExpected =
            remainingFrom vestingTranche1 pendingTxValidRange
            + remainingFrom vestingTranche2 pendingTxValidRange

    in remainingActual `Value.geq` remainingExpected
            -- The policy encoded in this contract
            -- is "vestingOwner can do with the funds what they want" (as opposed
            -- to "the funds must be paid to vestingOwner"). This is enforcey by
            -- the following condition:
            && Validation.txSignedBy ptx vestingOwner
            -- That way the recipient of the funds can pay them to whatever address they
            -- please, potentially saving one transaction.

data Vesting
instance Scripts.ScriptType Vesting where
    type instance RedeemerType Vesting = ()
    type instance DataType Vesting = ()

vestingScript :: VestingParams -> ValidatorScript
vestingScript = Scripts.validatorScript . scriptInstance

scriptInstance :: VestingParams -> Scripts.ScriptInstance Vesting
scriptInstance vesting = Scripts.Validator @Vesting
    ($$(PlutusTx.compile [|| validate ||]) `PlutusTx.applyCode` PlutusTx.liftCode vesting)
    $$(PlutusTx.compile [|| wrap ||])
    where
        wrap = Scripts.wrapValidator @() @()

contractAddress :: VestingParams -> Ledger.Address
contractAddress = Scripts.scriptAddress . scriptInstance

vestingContract :: VestingParams -> Contract VestingSchema T.Text ()
vestingContract vesting = vest <|> retrieve
  where
    vest = endpoint @"vest funds" >> vestFundsC vesting
    retrieve = do
        payment <- endpoint @"retrieve funds"
        liveness <- retrieveFundsC vesting payment
        case liveness of
            Alive -> retrieve
            Dead  -> pure ()

payIntoContract :: VestingParams -> Value -> UnbalancedTx
payIntoContract vp value = payToScript value (contractAddress vp) unitData

vestFundsC
    :: ( HasWriteTx s
       )
    => VestingParams
    -> Contract s T.Text ()
vestFundsC vesting = do
    let tx = payIntoContract vesting (totalAmount vesting)
    void $ writeTxSuccess tx

data Liveness = Alive | Dead

retrieveFundsC
    :: ( HasAwaitSlot s
       , HasUtxoAt s
       , HasWriteTx s
       )
    => VestingParams
    -> Value
    -> Contract s T.Text Liveness
retrieveFundsC vesting payment = do
    let addr = contractAddress vesting
    nextSlot <- awaitSlot 0
    unspentOutputs <- utxoAt addr
    let
        currentlyLocked = fold (AM.values unspentOutputs)
        remainingValue = currentlyLocked - payment
        mustRemainLocked = totalAmount vesting - availableAt vesting nextSlot
        maxPayment = currentlyLocked - mustRemainLocked

    when (remainingValue `Value.lt` mustRemainLocked)
        $ throwError
        $ T.unwords
            [ "Cannot take out"
            , T.pack (show payment) `T.append` "."
            , "The maximum is"
            , T.pack (show maxPayment) `T.append` "."
            , "At least"
            , T.pack (show mustRemainLocked)
            , "must remain locked by the script."
            ]

    let liveness = if remainingValue `Value.gt` mempty then Alive else Dead
        remainingOutputs = case liveness of
                            Alive -> payIntoContract vesting remainingValue
                            Dead  -> Haskell.mempty
        tx = Typed.collectFromScript unspentOutputs (scriptInstance vesting) () Haskell.<> remainingOutputs
                & validityRange .~ Interval.from nextSlot
                & requiredSignatures .~ [vestingOwner vesting]
                -- we don't need to add a pubkey output for 'vestingOwner' here
                -- because this will be done by the wallet when it balances the
                -- transaction.
    void $ writeTx tx
    return liveness

endpoints :: Contract VestingSchema T.Text ()
endpoints = vestingContract vestingParams
  where
    vestingParams =
        VestingParams {vestingTranche1, vestingTranche2, vestingOwner}
    vestingTranche1 =
        VestingTranche
            {vestingTrancheDate = Slot 10, vestingTrancheAmount = Ada.adaValueOf 5}
    vestingTranche2 =
        VestingTranche
            {vestingTrancheDate = Slot 20, vestingTrancheAmount = Ada.adaValueOf 3}
    vestingOwner = walletPubKey $ Wallet 1

mkSchemaDefinitions ''VestingSchema
