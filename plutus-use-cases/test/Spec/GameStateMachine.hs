{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE MonoLocalBinds   #-}
module Spec.GameStateMachine(tests) where

import           Test.Tasty
import qualified Test.Tasty.HUnit                                          as HUnit

import qualified Spec.Lib                                                  as Lib

import qualified Language.PlutusTx as PlutusTx

import           Language.Plutus.Contract.Test
import           Language.PlutusTx.Coordination.Contracts.GameStateMachine as G
import           Language.PlutusTx.Coordination.Contracts.GameStateMachine (GameStateMachineSchema, LockArgs(..), GuessArgs(..))
import           Language.PlutusTx.Lattice
import qualified Ledger.Ada                                                as Ada
import           Ledger.Value                                              (Value)
import qualified Ledger.Typed.Scripts                                      as Scripts
import qualified Wallet.Emulator                                           as EM

tests :: TestTree
tests =
    testGroup "state machine tests"
    [ checkPredicate @GameStateMachineSchema "run a successful game trace"
        G.contract
        (walletFundsChange w2 (Ada.lovelaceValueOf 3 <> G.gameTokenVal)
        /\ fundsAtAddress (Scripts.scriptAddress G.scriptInstance) (Ada.lovelaceValueOf 5 ==)
        /\ walletFundsChange w1 (Ada.lovelaceValueOf (-8)))
        successTrace

    , checkPredicate @GameStateMachineSchema "run a 2nd successful game trace"
        G.contract
        (walletFundsChange w2 (Ada.lovelaceValueOf 3)
        /\ fundsAtAddress (Scripts.scriptAddress G.scriptInstance) (Ada.lovelaceValueOf 1 ==)
        /\ walletFundsChange w1 (Ada.lovelaceValueOf (-4) <> G.gameTokenVal))
        ( successTrace
        >> payToWallet w2 w1 G.gameTokenVal 
        >> callEndpoint @"guess" w1 GuessArgs{guessArgsOldSecret="new secret", guessArgsNewSecret="hello", guessArgsValueLocked=Ada.lovelaceValueOf 1}
        >> handleBlockchainEvents w1
        )

    , checkPredicate @GameStateMachineSchema "run a failed trace"
        G.contract
        (walletFundsChange w2 G.gameTokenVal
        /\ fundsAtAddress (Scripts.scriptAddress G.scriptInstance) (Ada.lovelaceValueOf 8 ==)
        /\ walletFundsChange w1 (Ada.lovelaceValueOf (-8)))
        ( callEndpoint @"lock" w1 LockArgs{lockArgsSecret="hello", lockArgsValue= Ada.lovelaceValueOf 8}
        >> handleBlockchainEvents w1
        >> payToWallet w1 w2 G.gameTokenVal
        >> callEndpoint @"guess" w2 GuessArgs{guessArgsOldSecret="hola", guessArgsNewSecret="new secret", guessArgsValueLocked=Ada.lovelaceValueOf 5}
        >> handleBlockchainEvents w2)


    , Lib.goldenPir "test/Spec/gameStateMachine.pir" $$(PlutusTx.compile [|| mkValidator ||])

    , HUnit.testCase "script size is reasonable" 
        (Lib.reasonable (Scripts.validatorScript G.scriptInstance) 35000)

    ]

initialVal :: Value
initialVal = Ada.adaValueOf 10

w1 :: EM.Wallet
w1 = EM.Wallet 1

w2 :: EM.Wallet
w2 = EM.Wallet 2

w3 :: EM.Wallet
w3 = EM.Wallet 3

successTrace :: MonadEmulator (TraceError e) m => ContractTrace GameStateMachineSchema e m a ()
successTrace = do
    callEndpoint @"lock" w1 LockArgs{lockArgsSecret="hello", lockArgsValue= Ada.lovelaceValueOf 8}
    handleBlockchainEvents w1
    payToWallet w1 w2 G.gameTokenVal
    callEndpoint @"guess" w2 GuessArgs{guessArgsOldSecret="hello", guessArgsNewSecret="new secret", guessArgsValueLocked=Ada.lovelaceValueOf 5}
    handleBlockchainEvents w2
