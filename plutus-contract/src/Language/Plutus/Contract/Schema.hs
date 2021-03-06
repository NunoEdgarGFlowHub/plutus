{-# LANGUAGE AllowAmbiguousTypes     #-}
{-# LANGUAGE DataKinds               #-}
{-# LANGUAGE DerivingVia             #-}
{-# LANGUAGE FlexibleContexts        #-}
{-# LANGUAGE GADTs                   #-}
{-# LANGUAGE OverloadedLabels        #-}
{-# LANGUAGE PolyKinds               #-}
{-# LANGUAGE RankNTypes              #-}
{-# LANGUAGE TypeApplications        #-}
{-# LANGUAGE TypeFamilies            #-}
{-# LANGUAGE TypeOperators           #-}
{-# LANGUAGE UndecidableInstances    #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}
module Language.Plutus.Contract.Schema(
      Handlers(..)
    , Event(..)
    , generalise
    , initialise
    , Input
    , Output
    ) where

import           Data.Aeson            (FromJSON, ToJSON)
import           Data.Row
import           Data.Row.Internal
import qualified Data.Row.Records      as Records
import qualified Data.Row.Variants     as Variants
import           Data.Text.Prettyprint.Doc

import           Data.Row.Extras

import           GHC.TypeLits

{- Note [Contract Schema]

Every contract has a schema that describes the data types used by the contract
to interact with the outside world. Conceptually the schema is a map of symbols
to pairs of types. Each entry in this map stands for a named request-response
pair.

For example, the 'WriteTx' interaction is defined as

  type WriteTx = "tx" .== ((), [UnbalancedTx])

Meaning that the output produced by the contract (2nd element) is a list of
unbalanced transactions, and the input the contract expects as a result (1st
element) is the unit value, telling it that the transactions have been
submitted.

In practice the schema is a type of the 'Data.Row.Row' kind.

-}

newtype Event s = Event { unEvent :: Var (Input s) }

deriving newtype instance Forall (Input s) Show => Show (Event s)
deriving newtype instance Forall (Input s) Eq => Eq (Event s)

instance (Forall (Input s) Pretty) => Pretty (Event s) where
  pretty (Event e) =
    let (lbl, vl) = Variants.eraseWithLabels @Pretty pretty e in
    hang 1 (braces $ vsep [lbl <> colon, vl])

deriving via JsonVar (Input s) instance (AllUniqueLabels (Input s), Forall (Input s) FromJSON) => FromJSON (Event s)

deriving via JsonVar (Input s) instance (Forall (Input s) ToJSON) => ToJSON (Event s)

newtype Handlers s = Handlers { unHandlers :: Rec (Output s) }

deriving via (JsonRec (Output s)) instance Forall (Output s) ToJSON => ToJSON (Handlers s)
deriving via (JsonRec (Output s)) instance (AllUniqueLabels (Output s), Forall (Output s) FromJSON) => FromJSON (Handlers s)

deriving newtype instance Forall (Output s) Show => Show (Handlers s)
deriving newtype instance Forall (Output s) Eq   => Eq (Handlers s)

instance (Forall (Output s) Pretty) => Pretty (Handlers s) where
  pretty (Handlers s) = 
    let entries = Records.eraseWithLabels @Pretty pretty s in
    hang 1 (braces (vsep (fmap (\(lbl, vl) -> lbl <> colon <+> vl) entries)))

deriving via (MonoidRec (Output s)) instance (Forall (Output s) Semigroup) => Semigroup (Handlers s)

deriving via (MonoidRec (Output s)) instance (AllUniqueLabels (Output s), Forall (Output s) Semigroup, Forall (Output s) Monoid) => Monoid (Handlers s)

initialise :: forall (s :: Row *) l a. (AllUniqueLabels (Output s), Forall (Output s) Semigroup, Forall (Output s) Monoid, KnownSymbol l, HasType l a (Output s)) => a -> Handlers s
initialise a =
  let Handlers h = mempty @(Handlers s)
  in Handlers (Records.update (Label @l) a h)

generalise :: forall s s'. (AllUniqueLabels (Output s'), Forall (Output s') Monoid, (Output s .// Output s') ~ (Output s')) => Handlers s -> Handlers s'
generalise (Handlers l) = Handlers $ l .// Records.default' @Monoid @(Output s') mempty

--  | Given a schema 's', 'Input s' is the 'Row' type of the inputs that 
--    contracts with this schema accept. See [Contract Schema]
type family Input (r :: Row *) where
  Input ('R r) = 'R (InputR r)

type family InputR (r :: [LT *]) where
  InputR '[] = '[]
  InputR (l ':-> (t1, _) ': r) =
    l ':-> t1 ': InputR r
  InputR (l ':-> t ': _) =
    TypeError ('Text "Input requires all types to be tuples."
                :$$: 'Text "For one, the field labelled " :<>: ShowType l :<>: 'Text " has type " :<>: ShowType t)

--  | Given a schema 's', 'Output s' is the 'Row' type of the outputs that 
--    contracts with this schema produce. See [Contract Schema]
type family Output (r :: Row *) where
  Output ('R r) = 'R (OutputR r)

type family OutputR (r :: [LT *]) where
  OutputR '[] = '[]
  OutputR (l ':-> (_, t2) ': r) =
    l ':-> t2 ': OutputR r
  OutputR (l ':-> t ': _) =
    TypeError ('Text "Output requires all types to be tuples."
                :$$: 'Text "For one, the field labelled " :<>: ShowType l :<>: 'Text " has type " :<>: ShowType t)

