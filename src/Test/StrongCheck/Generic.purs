-- | Generic deriving for `Arbitrary` and `CoArbitrary` instances.
-- | Generation of arbitrary `GenericSpine`s with corresponding `GenericSignature`s.
module Test.StrongCheck.Generic
  ( gArbitrary
  , gCoarbitrary
  , GenericValue
  , genericValue
  , runGenericValue
  , genGenericSignature
  , genGenericSpine
  ) where

import Prelude

import Control.Plus (empty)

import Data.Array (nub, uncons, zipWith, length, filter, (:))
import Data.Foldable (class Foldable, foldMap)
import Data.Generic (class Generic, GenericSignature(..), GenericSpine(..), isValidSpine, toSpine, toSignature, fromSpine)
import Data.Int (toNumber)
import Data.List (fromFoldable)
import Data.Maybe (Maybe(..), maybe, fromJust)
import Data.Monoid.Endo (Endo(..))
import Data.Newtype (unwrap)
import Data.Traversable (for, traverse)
import Data.Tuple (Tuple(..))

import Partial.Unsafe (unsafePartial)

import Test.StrongCheck.Arbitrary (class Arbitrary, arbitrary, coarbitrary)
import Test.StrongCheck.Gen (Gen, Size, frequency, arrayOf, oneOf, resize, sized, elements)

import Type.Proxy (Proxy(..))

-- | Generate arbitrary values for any `Generic` data structure
gArbitrary :: forall a. Generic a => Gen a
gArbitrary = unsafePartial fromJust <<< fromSpine <$> genGenericSpine (toSignature (Proxy :: Proxy a))

-- | Perturb a generator using a `Generic` data structure
gCoarbitrary :: forall a r. Generic a => a -> Gen r -> Gen r
gCoarbitrary = go <<< toSpine
  where
    go :: GenericSpine -> Gen r -> Gen r
    go (SArray ss) = applyAll (map (go <<< (_ $ unit)) ss)
    go (SBoolean b) = coarbitrary b
    go (SString s) = coarbitrary s
    go (SChar c) = coarbitrary c
    go (SInt i) = coarbitrary i
    go (SNumber n) = coarbitrary n
    go (SRecord fs) = applyAll (map (\f -> coarbitrary f.recLabel <<< go (f.recValue unit)) fs)
    go (SProd ctor ss) = coarbitrary ctor <<< applyAll (map (go <<< (_ $ unit)) ss)
    go SUnit = coarbitrary unit

applyAll :: forall f a. Foldable f => f (a -> a) -> a -> a
applyAll = unwrap <<< foldMap Endo

-- | Contains representation of an arbitrary value.
-- | Consists of `GenericSpine` and corresponding `GenericSignature`.
newtype GenericValue = GenericValue { signature :: GenericSignature
                                    , spine     :: GenericSpine
                                    }

-- | Extract `GenericSignature` and `GenericSpine` from a `GenericValue`
runGenericValue :: GenericValue -> { signature :: GenericSignature
                                   , spine     :: GenericSpine
                                   }
runGenericValue (GenericValue val) = val

-- | Smart constructor for `GenericValue`. Would return `Nothing` if given
-- | `GenericSpine` doesn't conform to given `GenericSignature`
genericValue :: GenericSignature -> GenericSpine -> Maybe GenericValue
genericValue sig spine
  | isValidSpine sig spine = Just $ GenericValue {signature: sig, spine: spine}
  | otherwise = Nothing

instance arbitraryGenericValue :: Arbitrary GenericValue where
  arbitrary = do
    signature <- sized genGenericSignature
    spine <- genGenericSpine signature
    maybe empty pure $ genericValue signature spine

-- | Generates `GenericSignature`s. Size parameter affects how nested the structure is.
genGenericSignature :: Size -> Gen GenericSignature
genGenericSignature size | size > 5 = genGenericSignature 5
genGenericSignature 0 = elements SigNumber
                                 (fromFoldable [ SigInt, SigString, SigBoolean ])
genGenericSignature size = resize (size - 1) $ oneOf sigArray [sigProd, sigRecord]
  where
    sigArray = SigArray <<< const <$> sized genGenericSignature
    sigRecord = do
      labels <- nub <$> arrayOf arbitrary
      values <- arrayOf (const <$> sized genGenericSignature)
      pure $ SigRecord $ zipWith { recLabel: _, recValue: _ } labels values
    sigProd = do
      typeConstr <- arbitrary
      constrs <- nub <$> arrayOf arbitrary
      values  <- arrayOf (arrayOf (const <$> sized genGenericSignature))
      pure $ SigProd typeConstr $ zipWith { sigConstructor: _, sigValues: _ } constrs values

-- | Generates `GenericSpine`s that conform to provided `GenericSignature`.
genGenericSpine :: GenericSignature -> Gen GenericSpine
genGenericSpine = genGenericSpine' empty

genGenericSpine' :: Array String -> GenericSignature -> Gen GenericSpine
genGenericSpine' trail SigBoolean     = SBoolean <$> arbitrary
genGenericSpine' trail SigNumber      = SNumber  <$> arbitrary
genGenericSpine' trail SigInt         = SInt     <$> arbitrary
genGenericSpine' trail SigString      = SString  <$> arbitrary
genGenericSpine' trail SigChar        = SChar    <$> arbitrary
genGenericSpine' trail SigUnit        = pure SUnit
genGenericSpine' trail (SigArray sig) = SArray   <$> arrayOf (const <$> genGenericSpine' trail (sig unit))
genGenericSpine' trail (SigProd _ sigs) = do
  alt =<< maybe empty (\cons -> frequency cons.head (fromFoldable cons.tail))
                      (uncons $ map (map pure) ctors)
  where
    trailCount sig = length $ filter ((==) sig.sigConstructor) trail
    probability sig = 6.0 / (5.0 + toNumber (trailCount sig))
    ctors = sigs <#> (\sig -> Tuple (probability sig) sig)
    alt altSig = SProd altSig.sigConstructor
                   <$> traverse (map const <<< genGenericSpine' (altSig.sigConstructor : trail) <<< (unit # _))
                                altSig.sigValues
genGenericSpine' trail (SigRecord fieldSigs) =
  SRecord <$> for fieldSigs \field -> do val <- genGenericSpine' trail (field.recValue unit)
                                         pure $ field { recValue = const val }
