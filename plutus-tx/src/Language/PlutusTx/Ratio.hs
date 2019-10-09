{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE NoImplicitPrelude    #-}
module Language.PlutusTx.Ratio(
    Ratio
    , Rational
    , (%)
    , numerator
    , denominator
    , round
    , truncate
    , properFraction
    , half
    -- * Misc.
    , quotRem
    , gcd
    ) where

import qualified Language.PlutusTx.Numeric     as P
import qualified Language.PlutusTx.Eq          as P
import qualified Language.PlutusTx.Ord         as P

import qualified Language.PlutusTx.Builtins as Builtins

import GHC.Real (Ratio(..))
import Data.Ratio (Rational)
import Prelude (Bool(True), Integer)

infixl 7  %

-- |Forms the ratio of two integral numbers.
(%) :: Integer -> Integer -> Ratio Integer
x % y = reduce (x P.* signum y) (abs y)

-- | Extract the numerator of the ratio in reduced form: the numerator and denominator have no common factor and the denominator is positive.
numerator :: Ratio a -> a
numerator (n :% _) = n

-- | Extract the denominator of the ratio in reduced form: the numerator and denominator have no common factor and the denominator is positive.
denominator :: Ratio a -> a
denominator (_ :% d) = d

-- From GHC.Real
-- | @'gcd' x y@ is the non-negative factor of both @x@ and @y@ of which
-- every common factor of @x@ and @y@ is also a factor; for example
-- @'gcd' 4 2 = 2@, @'gcd' (-4) 6 = 2@, @'gcd' 0 4@ = @4@. @'gcd' 0 0@ = @0@.
gcd :: Integer -> Integer -> Integer
gcd a 0  =  a
gcd a b  =  gcd b (a `Builtins.remainderInteger` b)

-- | truncate @x@ returns the integer nearest @x@ between zero and @x@
truncate :: Ratio Integer -> Integer
truncate (n :% d) = n `Builtins.divideInteger` d

-- From GHC.Real
-- | The function 'properFraction' takes a real fractional number @x@
-- and returns a pair @(n,f)@ such that @x = n+f@, and:
--
-- * @n@ is an integral number with the same sign as @x@; and
--
-- * @f@ is a fraction with the same type and sign as @x@,
--   and with absolute value less than @1@.
--
-- The default definitions of the 'ceiling', 'floor', 'truncate'
-- and 'round' functions are in terms of 'properFraction'.
properFraction :: Ratio Integer -> (Integer, Ratio Integer)
properFraction (n :% d) = (q, r :% d) where (q, r) = quotRem n d

-- | simultaneous quot and rem
quotRem :: Integer -> Integer -> (Integer, Integer)
quotRem x y = (x `Builtins.divideInteger` y, x `Builtins.remainderInteger` y)
  -- no quotRem builtin :(

-- | 0.5
half :: Ratio Integer
half = 1 :% 2

-- | From GHC.Real
-- | 'reduce' is a subsidiary function used only in this module.
-- It normalises a ratio by dividing both numerator and denominator by
-- their greatest common divisor.
reduce :: Integer -> Integer -> Ratio Integer
reduce _ 0 =  Builtins.error ()
reduce x y =  (x `Builtins.divideInteger` d) :% (y `Builtins.divideInteger` d) where d = gcd x y

abs :: (P.Ord n, P.AdditiveGroup n) => n -> n
abs x = if x P.< P.zero then (P.negate x) else x

signum :: (P.AdditiveMonoid a, P.Ord a) => a -> Integer
signum d
        | d P.== P.zero = 0
        | d P.> P.zero  = 1
        | True          = -1

even :: Integer -> Bool
even x = (x `Builtins.remainderInteger` 2) P.== P.zero

-- | From GHC.Real
-- | @round x@ returns the nearest integer to @x@; the even integer if @x@ is equidistant between two integers
round :: Ratio Integer -> Integer
round x =
  let (n, r) = properFraction x
      m      = if r P.< P.zero then n P.- P.one else n P.+ P.one
  in case signum (abs r P.- half) of
      -1 -> n
      0  -> if even n then n else m
      1  -> m
      _  -> Builtins.error ()
