{-# LANGUAGE CPP, ConstraintKinds, DataKinds, FlexibleInstances, GADTs,
             MultiParamTypeClasses, QuantifiedConstraints, RankNTypes,
             TypeFamilyDependencies #-}
{-# OPTIONS_GHC -fconstraint-solver-iterations=16 #-}
{-# OPTIONS_GHC -Wno-missing-methods #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.KnownNat.Solver #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.Normalise #-}
-- | Dual numbers and various operations on them, arithmetic and related
-- to tensors (vectors, matrices and others). This is a part of
-- the high-level API of the horde-ad library, defined using the mid-level
-- (and safely impure) API in "HordeAd.Core.DualClass". The other part
-- of the high-level API is in "HordeAd.Core.Engine".
module HordeAd.Core.DualNumber
  ( module HordeAd.Core.DualNumber
  , ADVal, dD, dDnotShared
  , ADMode(..)
  , IsPrimal (..), IsPrimalAndHasFeatures, IsPrimalAndHasInputs
  , Element, HasPrimal(..)
  , Domain0, Domain1, Domains(..), nullDomains  -- an important re-export
  , -- temporarily re-exported, until these are wrapped in sugar
    Ast(..), AstPrimalPart1(..)
  , AstVarName(..), AstVar(..)
  , AstInt(..), AstBool(..)
  , OpCode(..), OpCodeInt(..), OpCodeBool(..), OpCodeRel(..)
  ) where

import Prelude

import qualified Data.Array.DynamicS as OT
import qualified Data.Array.Ranked as ORB
import qualified Data.Array.RankedS as OR
import           Data.IORef.Unboxed (Counter, atomicAddCounter_, newCounter)
import           Data.MonoTraversable (MonoFunctor (omap))
import           Data.Proxy (Proxy (Proxy))
import qualified Data.Strict.IntMap as IM
import qualified Data.Strict.Vector as Data.Vector
import qualified Data.Vector.Generic as V
import           GHC.TypeLits (KnownNat, Nat, natVal, type (+))
import           Numeric.LinearAlgebra (Numeric, Vector)
import qualified Numeric.LinearAlgebra as LA
import           System.IO.Unsafe (unsafePerformIO)
import           Unsafe.Coerce (unsafeCoerce)

import HordeAd.Core.Ast
import HordeAd.Core.DualClass
import HordeAd.Internal.Delta
  (Delta0, Domain0, Domain1, Domains (..), nullDomains)
import HordeAd.Internal.TensorOps

-- * Auxiliary definitions

-- | A mega-shorthand for a bundle of connected type constraints.
-- The @Scalar@ in the name means that the second argument is the underlying
-- scalar type of a well behaved (wrt the differentiation mode in the first
-- argument) collection of primal and dual components of dual numbers.
type ADModeAndNum (d :: ADMode) r =
  ( Numeric r
  , Show r
  , HasRanks d r
  , IsPrimalAndHasFeatures d r r
  , IsPrimalR d r
  , VectorOf r ~ OR.Array 1 r
  , VectorNumeric r
  , Tensor r
  , IntOf r ~ Int
  , RealFloat (Vector r)
  )

-- | Is a scalar and will be used to compute gradients via delta-expressions.
type HasDelta r = ( ADModeAndNum 'ADModeGradient r
                  , HasInputs r
                  , Dual 'ADModeGradient r ~ Delta0 r )

-- Shims to reuse the tests for ordinary vectors.
type Vec r = OR.Array 1 r

vecToV :: Numeric r => Vec r -> Vector r
vecToV = OR.toVector

vToVec :: Numeric r => Vector r  -> Vec r
vToVec v = OR.fromVector [V.length v] v

-- All this is not needed in the simplified version, except for compilation
-- with the common test code.
-- | Sizes of tensor dimensions, of batches, etc., packed for passing
-- between functions as witnesses of type variable values.
data SNat (n :: Nat) where
  MkSNat :: KnownNat n => SNat n

staticNatValue :: forall n i. (KnownNat n, Num i) => SNat n -> i
{-# INLINE staticNatValue #-}
staticNatValue = fromInteger . natVal

staticNatFromProxy :: KnownNat n => Proxy n -> SNat n
staticNatFromProxy Proxy = MkSNat

-- | Add sharing information to the top level of a term, presumably
-- constructed using multiple applications of the `dDnotShared` operation.
-- The resulting term may not have sharing information inside,
-- but is ready to be shared as a whole.
ensureToplevelSharing :: IsPrimal d a => ADVal d a -> ADVal d a
ensureToplevelSharing (D u u') = dD u u'

scaleNotShared :: (Num a, IsPrimal d a) => a -> ADVal d a -> ADVal d a
scaleNotShared a (D u u') = dDnotShared (a * u) (dScale a u')

addNotShared :: (Num a, IsPrimal d a) => ADVal d a -> ADVal d a -> ADVal d a
addNotShared (D u u') (D v v') = dDnotShared (u + v) (dAdd u' v')

multNotShared :: (Num a, IsPrimal d a) => ADVal d a -> ADVal d a -> ADVal d a
multNotShared (D u u') (D v v') =
  dDnotShared (u * v) (dAdd (dScale v u') (dScale u v'))

addParameters :: (Numeric r, Num (Vector r))
              => Domains r -> Domains r -> Domains r
addParameters (Domains a0 a1) (Domains b0 b1) =
  Domains (a0 + b0)
          (V.zipWith (+) a1 b1)

-- Dot product and sum respective ranks and then sum it all.
dotParameters :: Numeric r => Domains r -> Domains r -> r
dotParameters (Domains a0 a1) (Domains b0 b1) =
  a0 LA.<.> b0
  + V.sum (V.zipWith (\v1 u1 ->
      if isTensorDummy v1 || isTensorDummy u1
      then 0
      else OT.toVector v1 LA.<.> OT.toVector u1) a1 b1)


-- * HasPrimal instances for all relevant types

-- We could accept any @RealFloat@ instead of @PrimalOf a@, but then
-- we'd need to coerce, e.g., via realToFrac, which is risky and lossy.
-- Also, the stricter typing is likely to catch real errors most of the time,
-- not just sloppy omission ofs explicit coercions.
class HasPrimal a where
  type PrimalOf a
  type DualOf a
  constant :: PrimalOf a -> a
  scale :: Num (PrimalOf a) => PrimalOf a -> a -> a
    -- expressible with @constant@ and multiplication, but we want the same
    -- name in each class instance, so it needs to be included in the class
  primalPart :: a -> PrimalOf a
  dualPart :: a -> DualOf a
  ddD :: PrimalOf a -> DualOf a -> a
  -- TODO: we'd probably also need dZero, dIndex0 and all others;
  -- basically DualOf a needs to have IsPrimal and HasRanks instances
  -- (and HasInputs?)
  -- TODO: if DualOf is supposed to be user-visible, we needed
  -- a better name for it; TangentOf? CotangentOf? SecondaryOf?
  --
  -- TODO: also put conditionals with AstBool condition here, at least initially

instance (Num a, IsPrimal d a) => HasPrimal (ADVal d a) where
  type PrimalOf (ADVal d a) = a
  type DualOf (ADVal d a) = Dual d a
  constant a = dD a dZero
  scale a (D u u') = dD (a * u) (dScale a u')
  primalPart (D u _) = u
  dualPart (D _ u') = u'
  ddD = dD

instance HasPrimal Float where
  type PrimalOf Float = Float
  type DualOf Float = ()
  constant = id
  scale = (*)
  primalPart = id
  dualPart _ = ()
  ddD u _ = u

instance HasPrimal Double where
  type PrimalOf Double = Double
  type DualOf Double = ()
  constant = id
  scale = (*)
  primalPart = id
  dualPart _ = ()
  ddD u _ = u

-- The constraint requires UndecidableInstances.
instance Numeric r
         => HasPrimal (OR.Array n r) where
  type PrimalOf (OR.Array n r) = OR.Array n r
  type DualOf (OR.Array n r) = ()
  constant = id
  scale = (*)
  primalPart = id
  dualPart _ = ()
  ddD u _ = u

instance HasPrimal (Ast n r) where
  type PrimalOf (Ast n r) = AstPrimalPart1 n r
  type DualOf (Ast n r) = ()  -- TODO: data AstDualPart: dScale, dAdd, dkonst1
  constant = AstConstant
  scale = AstScale
  primalPart = AstPrimalPart1
  dualPart = error "TODO"
  ddD = error "TODO"

-- * Numeric instances for ADVal

-- These instances are required by the @Real@ instance, which is required
-- by @RealFloat@, which gives @atan2@. No idea what properties
-- @Real@ requires here, so let it crash if it's really needed.
instance Eq (ADVal d a) where

instance Ord (ADVal d a) where

instance (Num a, IsPrimal d a) => Num (ADVal d a) where
  D u u' + D v v' = dD (u + v) (dAdd u' v')
  D u u' - D v v' = dD (u - v) (dAdd u' (dScale (fromInteger (-1)) v'))
    -- without @fromInteger@, this is interpreted as @negate 1@,
    -- causing a crash for ranked tensors (can't guess the rank of @1@
    -- and then no other argument to derive the rank of @negate@);
    -- dynamic tensors dont check at all; shaped have all needed info in types
  D u u' * D v v' = dD (u * v) (dAdd (dScale v u') (dScale u v'))
  negate (D v v') = dD (negate v) (dScale (fromInteger (-1)) v')
  abs (D v v') = dD (abs v) (dScale (signum v) v')
  signum (D v _) = dD (signum v) dZero
  fromInteger = constant . fromInteger

instance (Real a, IsPrimal d a) => Real (ADVal d a) where
  toRational = undefined  -- TODO?

instance (Fractional a, IsPrimal d a) => Fractional (ADVal d a) where
  D u u' / D v v' =
    let recipSq = recip (v * v)  -- ensure sharing; also elsewhere
    in dD (u / v) (dAdd (dScale (v * recipSq) u') (dScale (- u * recipSq) v'))
  recip (D v v') =
    let minusRecipSq = - recip (v * v)
    in dD (recip v) (dScale minusRecipSq v')
  fromRational = constant . fromRational

instance (Floating a, IsPrimal d a) => Floating (ADVal d a) where
  pi = constant pi
  exp (D u u') = let expU = exp u
                 in dD expU (dScale expU u')
  log (D u u') = dD (log u) (dScale (recip u) u')
  sqrt (D u u') = let sqrtU = sqrt u
                  in dD sqrtU (dScale (recip (sqrtU + sqrtU)) u')
  D u u' ** D v v' = dD (u ** v) (dAdd (dScale (v * (u ** (v - 1))) u')
                                       (dScale ((u ** v) * log u) v'))
  logBase x y = log y / log x
  sin (D u u') = dD (sin u) (dScale (cos u) u')
  cos (D u u') = dD (cos u) (dScale (- (sin u)) u')
  tan (D u u') = let cosU = cos u
                 in dD (tan u) (dScale (recip (cosU * cosU)) u')
  asin (D u u') = dD (asin u) (dScale (recip (sqrt (1 - u*u))) u')
  acos (D u u') = dD (acos u) (dScale (- recip (sqrt (1 - u*u))) u')
  atan (D u u') = dD (atan u) (dScale (recip (1 + u*u)) u')
  sinh (D u u') = dD (sinh u) (dScale (cosh u) u')
  cosh (D u u') = dD (cosh u) (dScale (sinh u) u')
  tanh (D u u') = let y = tanh u
                  in dD y (dScale (1 - y * y) u')
  asinh (D u u') = dD (asinh u) (dScale (recip (sqrt (1 + u*u))) u')
  acosh (D u u') = dD (acosh u) (dScale (recip (sqrt (u*u - 1))) u')
  atanh (D u u') = dD (atanh u) (dScale (recip (1 - u*u)) u')

instance (RealFrac a, IsPrimal d a) => RealFrac (ADVal d a) where
  properFraction = undefined
    -- TODO: others, but low priority, since these are extremely not continuous

instance (RealFloat a, IsPrimal d a) => RealFloat (ADVal d a) where
  atan2 (D u u') (D v v') =
    let t = 1 / (u * u + v * v)
    in dD (atan2 u v) (dAdd (dScale (- u * t) v') (dScale (v * t) u'))
      -- we can be selective here and omit the other methods,
      -- most of which don't even have a differentiable codomain


-- * VectorNumeric class definition and instances for arrays, ADVal and Ast

-- TODO: when we have several times more operations, split into
-- VectorContainer and VectorNumeric, with the latter containing the few
-- Ord and Num operations and the superclasses below, extended with
-- VectorContainer.
-- TODO: change the method prefix ("l") now that the name is changed.
-- | The superclasses indicate that it's not only a container vector,
-- but also a mathematical vector, sporting numeric operations.
class (RealFloat r, RealFloat (VectorOf r), Integral (IntOf r))
      => VectorNumeric r where
  type VectorOf r = result | result -> r
  type IntOf r

  llength :: VectorOf r -> IntOf r
  lminIndex :: VectorOf r -> IntOf r
  lmaxIndex :: VectorOf r -> IntOf r

  lindex0 :: VectorOf r -> IntOf r -> r
  lsum0 :: VectorOf r -> r
  ldot0 :: VectorOf r -> VectorOf r -> r
  lminimum0 :: VectorOf r -> r
  lmaximum0 :: VectorOf r -> r
  fromIntOf0 :: IntOf r -> r
  fromIntOf0 = fromInteger . fromIntegral

  lfromList1 :: [r] -> VectorOf r
  lfromVector1 :: Data.Vector.Vector r -> VectorOf r
  lkonst1 :: IntOf r -> r -> VectorOf r
  lappend1 :: VectorOf r -> VectorOf r -> VectorOf r
  lslice1 :: IntOf r -> IntOf r -> VectorOf r -> VectorOf r
  lreverse1 :: VectorOf r -> VectorOf r
  lbuild1 :: IntOf r -> (IntOf r -> r) -> VectorOf r
  lmap1 :: (r -> r) -> VectorOf r -> VectorOf r
  lzipWith1 :: (r -> r -> r) -> VectorOf r -> VectorOf r -> VectorOf r
  fromIntOf1 :: IntOf r -> VectorOf r
  fromIntOf1 = fromInteger . fromIntegral
    -- TODO: this one is probably spurious, but let's keep it until
    -- we verify if the variant from HasPrimal, working for all ranks,
    -- can be recovered in the final formulation

  -- Default methods for Float, Double and all future scalars users will add.
  default llength
    :: (VectorOf r ~ OR.Array 1 r, IntOf r ~ Int)
    => VectorOf r -> IntOf r
  llength = tsizeR
  default lminIndex
    :: (Numeric r, VectorOf r ~ OR.Array 1 r, IntOf r ~ Int)
    => VectorOf r -> IntOf r
  lminIndex = tminIndexR
  default lmaxIndex
    :: (Numeric r, VectorOf r ~ OR.Array 1 r, IntOf r ~ Int)
    => VectorOf r -> IntOf r
  lmaxIndex = tmaxIndexR

  default lindex0
    :: (Numeric r, VectorOf r ~ OR.Array 1 r, IntOf r ~ Int)
    => VectorOf r -> IntOf r -> r
  lindex0 v ix = (V.! ix) $ OR.toVector v
  default lsum0
    :: (Numeric r, VectorOf r ~ OR.Array 1 r)
    => VectorOf r -> r
  lsum0 = tsum0R
  default ldot0
    :: (Numeric r, VectorOf r ~ OR.Array 1 r)
    => VectorOf r -> VectorOf r -> r
  ldot0 = tdot0R
  default lminimum0
    :: (Numeric r, VectorOf r ~ OR.Array 1 r)
    => VectorOf r -> r
  lminimum0 = tminimum0R
  default lmaximum0
    :: (Numeric r, VectorOf r ~ OR.Array 1 r)
    => VectorOf r -> r
  lmaximum0 = tmaximum0R

  default lfromList1
    :: (Numeric r, VectorOf r ~ OR.Array 1 r)
    => [r] -> VectorOf r
  lfromList1 l = OR.fromList [length l] l
  default lfromVector1
    :: (Numeric r, VectorOf r ~ OR.Array 1 r)
    => Data.Vector.Vector r -> VectorOf r
  lfromVector1 v = OR.fromVector [V.length v] $ V.convert v
  default lkonst1
    :: (Numeric r, VectorOf r ~ OR.Array 1 r, IntOf r ~ Int)
    => IntOf r -> r -> VectorOf r
  lkonst1 n r = OR.constant [n] r
  default lappend1
    :: (Numeric r, VectorOf r ~ OR.Array 1 r)
    => VectorOf r -> VectorOf r -> VectorOf r
  lappend1 = tappendR
  default lslice1
    :: (VectorOf r ~ OR.Array 1 r, IntOf r ~ Int)
    => IntOf r -> IntOf r -> VectorOf r -> VectorOf r
  lslice1 = tsliceR
  default lreverse1
    :: (VectorOf r ~ OR.Array 1 r)
    => VectorOf r -> VectorOf r
  lreverse1 = treverseR
  default lbuild1
    :: (Numeric r, VectorOf r ~ OR.Array 1 r, IntOf r ~ Int)
    => IntOf r -> (IntOf r -> r) -> VectorOf r
  lbuild1 n f = OR.generate [n] (\l -> f (head l))
  default lmap1
    :: (Numeric r, VectorOf r ~ OR.Array 1 r)
    => (r -> r) -> VectorOf r -> VectorOf r
  lmap1 = tmap0NR
  default lzipWith1
    :: (Numeric r, VectorOf r ~ OR.Array 1 r)
    => (r -> r -> r) -> VectorOf r -> VectorOf r -> VectorOf r
  lzipWith1 = tzipWith0NR

type ADReady r = (VectorNumeric r, HasPrimal r, HasPrimal (VectorOf r))

-- These instances are a faster way to get an objective function value.
-- However, they don't do vectorization, so won't work on GPU, ArrayFire, etc.
-- For vectorization, go through Ast and valueOnDomains.
instance VectorNumeric Double where
  type VectorOf Double = OR.Array 1 Double
  type IntOf Double = Int

instance VectorNumeric Float where
  type VectorOf Float = OR.Array 1 Float
  type IntOf Float = Int

-- Not that this instance doesn't do vectorization. To enable it,
-- use the Ast instance, which vectorizes and finally interpret in ADVal.
-- In principle, this instance is only useful for comparative tests,
-- though for code without build/map/etc., it should be equivalent
-- to going via Ast.
instance ADModeAndNum d r
         => VectorNumeric (ADVal d r) where
  type VectorOf (ADVal d r) = ADVal d (OR.Array 1 r)
  type IntOf (ADVal d r) = Int

  llength (D u _) = llength u
  lminIndex (D u _) = lminIndex u
  lmaxIndex (D u _) = lmaxIndex u

  lindex0 d ix = unScalar $ index d ix
  lsum0 = sum0
  ldot0 = dot0
  lminimum0 (D u u') =
    dD (lminimum0 u) (dIndex0 u' [lminIndex u] [llength u])
  lmaximum0 (D u u') =
    dD (lmaximum0 u) (dIndex0 u' [lmaxIndex u] [llength u])

  lfromList1 l = fromList0N [length l] l
  lfromVector1 l = fromVector0N [V.length l] l
  lkonst1 n = konst0N [n]
  lappend1 = append
  lslice1 = slice
  lreverse1 = reverse'
  lbuild1 = build1Closure
    -- uses the implementation that stores closures on tape to test against
    -- the elementwise implementation used by the fallback from vectorizing Ast
  lmap1 f v = build1Closure (llength v) (\i -> f (v `lindex0` i))
  lzipWith1 f v u =
    build1Closure (llength v) (\i -> f (v `lindex0` i) (u `lindex0` i))

instance (Numeric r, RealFloat r, RealFloat (Vector r))
         => VectorNumeric (Ast 0 r) where
  type VectorOf (Ast 0 r) = Ast 1 r
  type IntOf (Ast 0 r) = AstInt r

  llength = AstLength
  lminIndex = AstMinIndex
  lmaxIndex = AstMaxIndex

  lindex0 = AstIndex
  lsum0 = AstSum
  ldot0 = AstDot0
  lminimum0 v = AstIndex v (AstMinIndex v)
  lmaximum0 v = AstIndex v (AstMaxIndex v)
  fromIntOf0 = AstConstInt
    -- toInteger is not defined for Ast, hence a special implementation

  lfromList1 = AstFromList
  lfromVector1 = AstFromVector
  lkonst1 = AstKonst
  lappend1 = AstAppend
  lslice1 = AstSlice
  lreverse1 = AstReverse
  lbuild1 = astBuild1
  lmap1 f v = astBuild1 (llength v) (\i -> f (v `lindex0` i))
  lzipWith1 f v u =
    astBuild1 (llength v) (\i -> f (v `lindex0` i) (u `lindex0` i))
  fromIntOf1 = AstConstInt

-- Impure but in the most trivial way (only ever incremented counter).
unsafeAstVarCounter :: Counter
{-# NOINLINE unsafeAstVarCounter #-}
unsafeAstVarCounter = unsafePerformIO (newCounter 0)

unsafeGetFreshAstVar :: IO (AstVarName a)
{-# INLINE unsafeGetFreshAstVar #-}
unsafeGetFreshAstVar = AstVarName <$> atomicAddCounter_ unsafeAstVarCounter 1

astBuild1 :: AstInt r -> (AstInt r -> Ast 0 r) -> Ast 1 r
{-# NOINLINE astBuild1 #-}
astBuild1 n f = unsafePerformIO $ do
  freshAstVar <- unsafeGetFreshAstVar
  return $! build1Vectorize n ( freshAstVar
                               , (f (AstIntVar freshAstVar)) )
    -- TODO: this vectorizes depth-first, which is needed. But do we
    -- also need a translation to non-vectorized terms for anything
    -- (other than for comparative tests)?


-- * Tensor class definition and instances for arrays, ADVal and Ast

-- TODO: when we have several times more operations, split into
-- Array (Container) and Tensor (Numeric), with the latter containing the few
-- Ord and Num operations and numeric superclasses.
-- | The transitive superclasses indicate that it's not only a container array,
-- but also a mathematical tensor, sporting numeric operations.
-- The @VectorNumeric@ superclass is for @IntOf@ and potential interoperability
-- (TODO: add coversions between VectorOf and TensorOf to facilitate this)
-- but all its operations have straightforwardly generalized analogues below.
class VectorNumeric r
      => Tensor r where
  type TensorOf (n :: Nat) r = result | result -> n r

  tlength :: KnownNat n => TensorOf (1 + n) r -> IntOf r
  tsize :: KnownNat n => TensorOf n r -> IntOf r
  -- tshape :: TensorOf n r -> [IntOf r]  -- TODO: a new Ast type needed
  tminIndex :: TensorOf 1 r -> IntOf r
  tmaxIndex :: TensorOf 1 r -> IntOf r

  tindex :: KnownNat n => TensorOf (1 + n) r -> IntOf r -> TensorOf n r
  tindex0 :: KnownNat n => TensorOf (1 + n) r -> [IntOf r] -> r
  tindexN :: (KnownNat n, KnownNat m)
          => TensorOf (1 + m + n) r -> [IntOf r] -> TensorOf n r
  tsum :: KnownNat n => TensorOf (1 + n) r -> TensorOf n r
  tsum0 :: KnownNat n => TensorOf n r -> r
  tdot0 :: KnownNat n => TensorOf n r -> TensorOf n r -> r
  tminimum0 :: TensorOf 1 r -> r
  tmaximum0 :: TensorOf 1 r -> r
  tfromIntOf0 :: IntOf r -> r
  tfromIntOf0 = fromInteger . fromIntegral

  tfromList :: KnownNat n => [TensorOf n r] -> TensorOf (1 + n) r
  tfromList0N :: KnownNat n => [IntOf r] -> [r] -> TensorOf n r
  tfromVector :: KnownNat n
              => Data.Vector.Vector (TensorOf n r) -> TensorOf (1 + n) r
  tfromVector0N :: KnownNat n
                => [IntOf r] -> Data.Vector.Vector r -> TensorOf n r
  tkonst :: KnownNat n => IntOf r -> TensorOf n r -> TensorOf (1 + n) r
  tkonst0N :: KnownNat n => [IntOf r] -> r -> TensorOf (1 + n) r
  tappend :: KnownNat n => TensorOf n r -> TensorOf n r -> TensorOf n r
  tslice :: KnownNat n => IntOf r -> IntOf r -> TensorOf n r -> TensorOf n r
  treverse :: KnownNat n => TensorOf n r -> TensorOf n r
  ttranspose :: KnownNat n => TensorOf n r -> TensorOf n r
  ttranspose = ttransposeGeneral [1, 0]
  ttransposeGeneral :: KnownNat n => [Int] -> TensorOf n r -> TensorOf n r
  tflatten :: KnownNat n => TensorOf n r -> TensorOf 1 r
  tflatten u = treshape [tsize u] u
  treshape :: (KnownNat n, KnownNat m)
           => [IntOf r] -> TensorOf n r -> TensorOf m r
  tbuild :: KnownNat n
         => IntOf r -> (IntOf r -> TensorOf n r) -> TensorOf (1 + n) r
  tbuild0N :: KnownNat n => [IntOf r] -> ([IntOf r] -> r) -> TensorOf n r
  tmap :: KnownNat n
       => (TensorOf n r -> TensorOf n r)
       -> TensorOf (1 + n) r -> TensorOf (1 + n) r
  tmap f u = tbuild (tlength u) (\i -> f (u `tindex` i))
  tmap0N :: KnownNat n => (r -> r) -> TensorOf n r -> TensorOf n r
  tzipWith :: KnownNat n
           => (TensorOf n r -> TensorOf n r -> TensorOf n r)
           -> TensorOf (1 + n) r -> TensorOf (1 + n) r -> TensorOf (1 + n) r
  tzipWith f u v = tbuild (tlength u) (\i -> f (u `tindex` i) (v `tindex` i))
  tzipWith0N :: KnownNat n
             => (r -> r -> r) -> TensorOf n r -> TensorOf n r -> TensorOf n r

type ADReady' r = (Tensor r, HasPrimal r)
  -- TODO: there is probably no way to also specify
  -- HasPrimal (TensorOf 17 r))
  -- for all n, not just 17. That means the user needs add such
  -- constraints for all n relevant to the defined function (usually
  -- just an unspecified n and sometimes also n+1).

-- These instances are a faster way to get an objective function value.
-- However, they don't do vectorization, so won't work on GPU, ArrayFire, etc.
-- For vectorization, go through Ast and valueOnDomains.
instance Tensor Double where
  type TensorOf n Double = OR.Array n Double
  tlength = tlengthR
  tsize = tsizeR
  tminIndex = tminIndexR
  tmaxIndex = tmaxIndexR
  tindex = tindexR
  tindex0 = tindex0R
  tindexN = tindexNR
  tsum = tsumR
  tsum0 = tsum0R
  tdot0 = tdot0R
  tminimum0 = tminimum0R
  tmaximum0 = tmaximum0R
  tfromList = tfromListR
  tfromList0N = tfromList0NR
  tfromVector = tfromVectorR
  tfromVector0N = tfromVector0NR
  tkonst = tkonstR
  tkonst0N = tkonst0NR
  tappend = tappendR
  tslice = tsliceR
  treverse = treverseR
  ttransposeGeneral = ttransposeGeneralR
  treshape = treshapeR
  tbuild = tbuildR
  tbuild0N = tbuild0NR
  tmap0N = tmap0NR
  tzipWith0N = tzipWith0NR

instance Tensor Float where
  type TensorOf n Float = OR.Array n Float
  tlength = tlengthR
  tsize = tsizeR
  tminIndex = tminIndexR
  tmaxIndex = tmaxIndexR
  tindex = tindexR
  tindex0 = tindex0R
  tindexN = tindexNR
  tsum = tsumR
  tsum0 = tsum0R
  tdot0 = tdot0R
  tminimum0 = tminimum0R
  tmaximum0 = tmaximum0R
  tfromList = tfromListR
  tfromList0N = tfromList0NR
  tfromVector = tfromVectorR
  tfromVector0N = tfromVector0NR
  tkonst = tkonstR
  tkonst0N = tkonst0NR
  tappend = tappendR
  tslice = tsliceR
  treverse = treverseR
  ttransposeGeneral = ttransposeGeneralR
  treshape = treshapeR
  tbuild = tbuildR
  tbuild0N = tbuild0NR
  tmap0N = tmap0NR
  tzipWith0N = tzipWith0NR

-- Not that this instance doesn't do vectorization. To enable it,
-- use the Ast instance, which vectorizes and finally interpret in ADVal.
-- In principle, this instance is only useful for comparative tests,
-- though for code without build/map/etc., it should be equivalent
-- to going via Ast.
instance (ADModeAndNum d r, TensorOf 1 r ~ OR.Array 1 r)
         => Tensor (ADVal d r) where
  type TensorOf n (ADVal d r) = ADVal d (OR.Array n r)

  -- Here and elsewhere I can't use methods of the @r@ instance of @Tensor@
  -- (the one implemented as @OR.Array n r@). Therefore, I inline them
  -- manually. There is probably no solution to that (2 parameters to Tensor
  -- would solve this, but we'd need infinitely many instances
  -- for @ADVal d (OR.Array n r)@ and @OR.Array n r@). As a workaround,
  -- the methods are defined as calls to tensor functions provided elsewhere,
  -- so there is no code duplication.
  tlength (D u _) = tlengthR u
  tsize (D u _) = tsizeR u
  tminIndex (D u _) = tminIndexR u
  tmaxIndex (D u _) = tmaxIndexR u

  tindex = index
  tindex0 d ix = unScalar $ indexN d ix
    -- TODO: due to this definition and the lack of sized lists,
    -- tindex0 currently does not accept empty paths, etc.
  tindexN = indexN
  tsum = sum'
  tsum0 = sum0
  tdot0 = dot0
  tminimum0 (D u u') =
    dD (tminimum0 u) (dIndex0 u' [tminIndex u] [tlength u])
  tmaximum0 (D u u') =
    dD (tmaximum0 u) (dIndex0 u' [tmaxIndex u] [tlength u])

  tfromList = fromList
  tfromList0N = fromList0N
  tfromVector = fromVector
  tfromVector0N = fromVector0N
  tkonst = konst
  tkonst0N = konst0N
  tappend = append
  tslice = slice
  treverse = reverse'
  ttransposeGeneral = transposeGeneral
  treshape = reshape
  tbuild n f =
    let g i = let D u _ = f i in u
        h i = let D _ u' = f i in u'
    in dD (tbuildR n g) (dBuild1 n h)
      -- uses the implementation that stores closures on tape to test against
      -- the elementwise implementation used by fallback from vectorizing Ast
  tbuild0N sh f =
    let g ixs = let D u _ = f ixs in u
        h ixs = let D _ u' = f ixs in u'
    in dD (tbuild0NR sh g) (dBuild01 sh h)
  tmap0N = undefined  -- TODO
  tzipWith0N = undefined  -- TODO

instance (Numeric r, RealFloat r, RealFloat (Vector r))
         => Tensor (Ast 0 r) where
  type TensorOf n (Ast 0 r) = Ast n r

  tlength = AstLength
  tsize = AstSize
  tminIndex = AstMinIndex
  tmaxIndex = AstMaxIndex

  tindex = AstIndex
  tindex0 = AstIndexN
  tindexN = AstIndexN
  tsum = AstSum
  tsum0 = AstSum0
  tdot0 = AstDot0
  tminimum0 v = AstIndex v (AstMinIndex v)
  tmaximum0 v = AstIndex v (AstMaxIndex v)
  tfromIntOf0 = AstConstInt
    -- toInteger is not defined for Ast, hence a special implementation

  tfromList = AstFromList
  tfromList0N = AstFromList0N
  tfromVector = AstFromVector
  tfromVector0N = AstFromVector0N
  tkonst = AstKonst
  tkonst0N = AstKonst0N
  tappend = AstAppend
  tslice = AstSlice
  treverse = AstReverse
  ttransposeGeneral = AstTransposeGeneral
  treshape = AstReshape
  tbuild = astBuild
  tbuild0N = undefined  -- TODO: type-level woes
  tmap0N = undefined  -- TODO
  tzipWith0N = undefined  -- TODO

astBuild :: AstInt r -> (AstInt r -> Ast n r) -> Ast (n + 1) r
{-# NOINLINE astBuild #-}
astBuild n f = unsafePerformIO $ do
  freshAstVar <- unsafeGetFreshAstVar
  return $! build1Vectorize n ( freshAstVar
                              , (f (AstIntVar freshAstVar)) )
    -- TODO: this vectorizes depth-first, which is needed. But do we
    -- also need a translation to non-vectorized terms for anything
    -- (other than for comparative tests)?


-- * Legacy operations needed to re-use vector differentiation tests

-- General operations, for any tensor rank

logistic :: (Floating a, IsPrimal d a) => ADVal d a -> ADVal d a
logistic (D u u') =
  let y = recip (1 + exp (- u))
  in dD y (dScale (y * (1 - y)) u')

-- Optimized and more clearly written @u ** 2@.
square :: (Num a, IsPrimal d a) => ADVal d a -> ADVal d a
square (D u u') = dD (u * u) (dScale (2 * u) u')

squaredDifference :: (Num a, IsPrimal d a)
                  => a -> ADVal d a -> ADVal d a
squaredDifference targ res = square $ res - constant targ

relu, reluLeaky
  :: ( HasPrimal a, MonoFunctor (PrimalOf a), Num (PrimalOf a)
     , Ord (Element (PrimalOf a)), Fractional (Element (PrimalOf a)) )
  => a -> a
relu v =
  let oneIfGtZero = omap (\x -> if x > 0 then 1 else 0) (primalPart v)
  in scale oneIfGtZero v

reluLeaky v =
  let oneIfGtZero = omap (\x -> if x > 0 then 1 else 0.01) (primalPart v)
  in scale oneIfGtZero v

-- TODO: generalize the function @relu@ above so that
-- it has a sensible Ast instance and then kill reluAst;
-- we'd need Conditional class that works with our AstBool type
-- and some sugar to be able to use >, &&, etc.
reluAst
  :: ( KnownNat n, Num (Vector r), MonoFunctor (PrimalOf (Ast n r))
     , Numeric r )
  => Ast n r -> Ast n r
reluAst v =
  let oneIfGtZero = omap (\(AstPrimalPart1 x) ->
                            AstPrimalPart1 $ AstCond (AstRel GtOp [x, 0]) 1 0)
                         (primalPart v)
  in scale oneIfGtZero v


-- Operations resulting in a scalar

sumElements10 :: ADModeAndNum d r
              => ADVal d (Vec r) -> ADVal d r
sumElements10 = lsum0

index10 :: ADModeAndNum d r => ADVal d (Vec r) -> Int -> ADVal d r
index10 = lindex0

minimum0 :: ADModeAndNum d r => ADVal d (Vec r) -> ADVal d r
minimum0 = lminimum0

maximum0 :: ADModeAndNum d r => ADVal d (Vec r) -> ADVal d r
maximum0 = lmaximum0

foldl'0 :: ADModeAndNum d r
        => (ADVal d r -> ADVal d r -> ADVal d r)
        -> ADVal d r -> ADVal d (Vec r)
        -> ADVal d r
foldl'0 f uu' (D v v') =
  let k = llength v
      g !acc ix p = f (dD p (dIndex0 v' [ix] [k])) acc
  in V.ifoldl' g uu' (OR.toVector v)

altSumElements10 :: ADModeAndNum d r => ADVal d (Vec r) -> ADVal d r
altSumElements10 = foldl'0 (+) 0

-- | Dot product.
infixr 8 <.>!
(<.>!) :: ADModeAndNum d r
       => ADVal d (Vec r) -> ADVal d (Vec r) -> ADVal d r
(<.>!) = ldot0

-- | Dot product with a constant vector.
infixr 8 <.>!!
(<.>!!) :: ADModeAndNum d r
        => ADVal d (Vec r) -> Vec r -> ADVal d r
(<.>!!) (D u u') v = dD (ldot0 u v) (dDot0 v u')

sumElementsVectorOfDual
  :: ADModeAndNum d r => Data.Vector.Vector (ADVal d r) -> ADVal d r
sumElementsVectorOfDual = V.foldl' (+) 0

softMax :: ADModeAndNum d r
        => Data.Vector.Vector (ADVal d r)
        -> Data.Vector.Vector (ADVal d r)
softMax us =
  let expUs = V.map exp us  -- used twice below, so named, to enable sharing
      sumExpUs = sumElementsVectorOfDual expUs
  in V.map (\r -> r * recip sumExpUs) expUs

-- In terms of hmatrix: @-(log res <.> targ)@.
lossCrossEntropy :: forall d r. ADModeAndNum d r
                 => Vector r
                 -> Data.Vector.Vector (ADVal d r)
                 -> ADVal d r
lossCrossEntropy targ res =
  let f :: ADVal d r -> Int -> ADVal d r -> ADVal d r
      f !acc i d = acc + scale (targ V.! i) (log d)
  in negate $ V.ifoldl' f 0 res

-- In terms of hmatrix: @-(log res <.> targ)@.
lossCrossEntropyV :: ADModeAndNum d r
                  => Vec r
                  -> ADVal d (Vec r)
                  -> ADVal d r
lossCrossEntropyV targ res = negate $ log res <.>!! targ

-- Note that this is equivalent to a composition of softMax and cross entropy
-- only when @target@ is one-hot. Otherwise, results vary wildly. In our
-- rendering of the MNIST data all labels are one-hot.
lossSoftMaxCrossEntropyV
  :: ADModeAndNum d r
  => Vec r -> ADVal d (Vec r) -> ADVal d r
lossSoftMaxCrossEntropyV target (D u u') =
  -- The following protects from underflows, overflows and exploding gradients
  -- and is required by the QuickCheck test in TestMnistCNN.
  -- See https://github.com/tensorflow/tensorflow/blob/5a566a7701381a5cf7f70fce397759483764e482/tensorflow/core/kernels/sparse_softmax_op.cc#L106
  -- and https://github.com/tensorflow/tensorflow/blob/5a566a7701381a5cf7f70fce397759483764e482/tensorflow/core/kernels/xent_op.h
  let expU = exp (u - lkonst1 (llength u) (lmaximum0 u))
      sumExpU = lsum0 expU
      recipSum = recip sumExpU
-- not exposed: softMaxU = LA.scaleRecip sumExpU expU
      softMaxU = lkonst1 (llength expU) recipSum * expU
  in dD (negate $ log softMaxU `ldot0` target)  -- TODO: avoid: log . exp
        (dDot0 (softMaxU - target) u')


-- Operations resulting in a vector (really, a rank 1 OR.Array)

-- @1@ means rank one, so the dual component represents a vector.
fromList1 :: ADModeAndNum d r
          => [ADVal d r] -> ADVal d (Vec r)
fromList1 = lfromList1

fromVector1 :: ADModeAndNum d r
            => Data.Vector.Vector (ADVal d r) -> ADVal d (Vec r)
fromVector1 = lfromVector1

konst1 :: ADModeAndNum d r => ADVal d r -> Int -> ADVal d (Vec r)
konst1 d n = lkonst1 n d

append1 :: ADModeAndNum d r
        => ADVal d (Vec r) -> ADVal d (Vec r) -> ADVal d (Vec r)
append1 = lappend1

slice1 :: ADModeAndNum d r
       => Int -> Int -> ADVal d (Vec r) -> ADVal d (Vec r)
slice1 = lslice1

reverse1 :: ADModeAndNum d r => ADVal d (Vec r) -> ADVal d (Vec r)
reverse1 = lreverse1

-- TODO: define Enum instance of (AstInt r) to enable AST for this.
-- No padding; remaining areas ignored.
maxPool1 :: ADModeAndNum d r
         => Int -> Int -> ADVal d (Vec r) -> ADVal d (Vec r)
maxPool1 ksize stride v =
  let slices = [slice1 i ksize v | i <- [0, stride .. llength v - ksize]]
  in fromList1 $ map maximum0 slices

softMaxV :: ADModeAndNum d r
         => ADVal d (Vec r) -> ADVal d (Vec r)
softMaxV d =
  let expU = exp d  -- shared in 2 places, though cse may do this for us
      sumExpU = sumElements10 expU
  in lkonst1 (llength d) (recip sumExpU) * expU


-- Build and map variants

build1POPL :: Int -> (Int -> ADVal d r) -> Data.Vector.Vector (ADVal d r)
build1POPL n f = V.fromList $ map f [0 .. n - 1]

-- Fake rank 1. This is still an array of delta expressions, thinly wrapped,
-- instead of a single delta expression representing an array.
-- We gain a little by storing the primal part in an unboxed vector.
build1Elementwise
  :: ADModeAndNum d r
  => Int -> (Int -> ADVal d r) -> ADVal d (Vec r)
build1Elementwise n f = fromList1 $ map f [0 .. n - 1]
  -- equivalent to @fromVector1 $ build1POPL n f@

build1Closure
  :: ADModeAndNum d r
  => Int -> (Int -> ADVal d r) -> ADVal d (Vec r)
build1Closure n f =
  let g i = let D u _ = f i in u
      h i = let D _ u' = f i in u'
  in dD (lfromList1 $ map g [0 .. n - 1]) (dBuild01 [n] (\l -> h (head l)))

build1
  :: ADModeAndNum d r
  => Int -> (Int -> ADVal d r) -> ADVal d (Vec r)
build1 = build1Closure

map1POPL :: (ADVal d r -> ADVal d r) -> Data.Vector.Vector (ADVal d r)
         -> Data.Vector.Vector (ADVal d r)
map1POPL f vd = V.map f vd

map1Elementwise
  :: ADModeAndNum d r
  => (ADVal d r -> ADVal d r) -> ADVal d (Vec r) -> ADVal d (Vec r)
map1Elementwise f d =
  build1Elementwise (llength d) $ \i -> f (lindex0 d i)
    -- equivalent to
    -- @fromVector1 . map1POPL f . rank1toVector
    --   where rank1toVector d@(D v _v') = V.generate (llength d) (lindex0 d)@


-- * Vectorization of the build operation

build1Vectorize
  :: AstInt r -> (AstVarName Int, Ast n r) -> Ast (1 + n) r
build1Vectorize n (var, u) =
  if intVarInAst var u
  then build1VectorizeVar n (var, u)
  else AstKonst n u

-- | The variable is known to occur in the term.
build1VectorizeVar
  :: AstInt r -> (AstVarName Int, Ast n r) -> Ast (1 + n) r
build1VectorizeVar n (var, u) =
  case u of
    AstOp opCode args ->
      AstOp opCode $ map (\w -> build1Vectorize n (var, w)) args
    AstCond b v w ->
      if intVarInAstBool var b then
        -- This handles conditionals that depend on var,
        -- so that we produce conditional delta expressions
        -- of size proportional to the exponent of conditional
        -- nesting, instead of proportional to the number of elements
        -- of the tensor.
        AstSelect n (var, b)
                  (build1Vectorize n (var, v))
                  (build1Vectorize n (var, w))
      else
        AstCond b (build1Vectorize n (var, v))
                  (build1Vectorize n (var, w))
    AstSelect n2 (var2, b) v w ->
      AstTranspose $ AstSelect n2 (var2, b)
        (AstTranspose $ build1Vectorize n (var, v))
        (AstTranspose $ build1Vectorize n (var, w))
    AstConstInt{} -> AstConstant $ AstPrimalPart1 $ AstBuildPair n (var, u)
    AstConst{} ->
      error "build1VectorizeVar: AstConst can't have free int variables"
    AstConstant{} -> AstConstant $ AstPrimalPart1 $ AstBuildPair n (var, u)
      -- this is very fast when interpreted in a smart way, but constant
      -- character needs to be exposed for nested cases;
      -- TODO: similarly propagate AstConstant upwards elsewhere
    AstScale (AstPrimalPart1 r) d ->
      AstScale (AstPrimalPart1 $ AstBuildPair n (var, r))  -- no need to vect
               (build1Vectorize n (var, d))

    AstIndex v i -> build1VectorizeIndexVar n var v [i]
      -- @var@ is in @v@ or @i@; TODO: simplify i first or even fully
      -- evaluate (may involve huge data processing) if contains no vars
      -- and then some things simplify a lot
    AstIndexN v is -> build1VectorizeIndexVar n var v is
    AstSum v -> AstTranspose $ AstSum $ AstTranspose
                $ build1VectorizeVar n (var, v)
      -- that's because @build n (f . g) == map f (build n g)@
      -- and @map f == transpose1 . f . transpose1@
      -- TODO: though only for some f; check and fail early
    AstFromList l ->
      AstTranspose
      $ AstFromList (map (\v -> build1Vectorize n (var, v)) l)
    AstFromVector l ->
      AstTranspose
      $ AstFromVector (V.map (\v -> build1Vectorize n (var, v)) l)
    AstKonst k _v | intVarInAstInt var k -> AstBuildPair n (var, u)  -- TODO
    AstKonst k v -> AstTranspose $ AstKonst k $ AstTranspose
                    $ build1Vectorize n (var, v)
    AstAppend v w -> AstTranspose $ AstAppend
                       (AstTranspose $ build1Vectorize n (var, v))
                       (AstTranspose $ build1Vectorize n (var, w))
    AstSlice i k _v | intVarInAstInt var i || intVarInAstInt var k ->
      AstBuildPair n (var, u)  -- TODO
    AstSlice i k v -> AstTranspose $ AstSlice i k $ AstTranspose
                      $ build1Vectorize n (var, v)
    AstReverse v -> AstTranspose $ AstReverse $ AstTranspose
                    $ build1VectorizeVar n (var, v)
    AstTranspose v ->
      build1VectorizeVar n (var, AstTransposeGeneral [1, 0] v)
    AstTransposeGeneral perm v -> AstTransposeGeneral (0 : map succ perm)
                                  $ build1VectorizeVar n (var, v)
    AstFlatten v -> build1Vectorize n (var, AstReshape [AstLength u] v)
    AstReshape ns _v | or $ map (intVarInAstInt var) ns ->
      AstBuildPair n (var, u)  -- TODO
    AstReshape ns v -> AstReshape (n : ns) $ build1Vectorize n (var, v)
    AstBuildPair{} -> AstBuildPair n (var, u)
      -- TODO: a previous failure of vectorization that should have
      -- led to an abort instead of showing up late
    AstGatherPair _n (_var2, _ixs2) _v -> AstBuildPair n (var, u)
      -- TODO: if var not in _v, then create a generalized gather
      -- that builds more than one rank using var and var2 together;
      -- then the function would be from a list of build1 indexes,
      -- but for this I *really* need a Nat-sized list, becuause I will
      -- then need to vectorize buildN and so all vectorization function
      -- signatures will contain complex type-level arithmetic
    -- AstScatterPair (var2, ixs2) v sh -> ...
    -- no idea how to vectorize AstScatterPair, so let's not add it prematurely

    -- Rewriting syntactic sugar in the simplest way (but much more efficient
    -- non-sugar implementations/vectorizations exist):
    AstSum0 v -> build1VectorizeVar n (var, AstSum $ AstFlatten v)
    AstDot0 v w ->
      build1VectorizeVar n (var, AstSum (AstOp TimesOp [ AstFlatten v
                                                          , AstFlatten w ]))
      -- AstDot1 is dubious, because dot product results in a scalar,
      -- not in one rank less and also (some) fast implementations
      -- depend on it resulting in a scalar.
      -- AstOp does not require Numeric constraint, so better than @*@.
    AstFromList0N sh l ->
      build1VectorizeVar n (var, AstReshape sh $ AstFromList l)
    AstFromVector0N sh l ->
      build1VectorizeVar n (var, AstReshape sh $ AstFromVector l)
    AstKonst0N sh v ->
      let k = product sh
      in build1VectorizeVar n (var, AstReshape sh $ AstKonst k v)
    AstBuildPair0N{} -> AstBuildPair n (var, u)  -- see AstBuildPair above

    AstOMap0{} -> AstConstant $ AstPrimalPart1 $ AstBuildPair n (var, u)
    AstOMap1{} -> AstConstant $ AstPrimalPart1 $ AstBuildPair n (var, u)
    AstVar0{} ->
      error "build1VectorizeVar: AstVar0 can't have free int variables"
    AstVar1{} ->
      error "build1VectorizeVar: AstVar1 can't have free int variables"
    -- All other patterns are redundant due to GADT typing.

-- | The application @build1VectorizeIndex n var v is@
-- vectorizes the term @AstBuildPair n (var, AstIndexN v is@.
-- The length of the path (the index list) is @1 + m@, which is
-- a hack until we can have proper sized lists of exactly length @m@.
-- The hack causes @m@ to, morally, have value -1 when the path is empty,
-- but it reduces the use of @unsafeCoerce@.
build1VectorizeIndex
  :: forall m n r. KnownNat m
  => AstInt r -> AstVarName Int -> Ast (1 + m + n) r -> [AstInt r]
  -> Ast (1 + n) r
build1VectorizeIndex n var v [] =
  unsafeCoerce $ build1Vectorize n (var, v)  -- m is -1
build1VectorizeIndex n var v is =
  if intVarInAst var v || or (map (intVarInAstInt var) is)
  then build1VectorizeIndexVar n var v is
  else AstKonst n (AstIndexN v is)

-- | The variable is known to occur in the term or in the index
-- (it doesn't matter much which, because other variables may occur, too).
-- We try to push the indexing down the term tree and partially
-- evalute/simplify the term, if possible in constant time. Eventually,
-- we are down to indexing of a too simple but non-constant expression,
-- and then the only hope is in analyzing the index expression in turn.
build1VectorizeIndexVar
  :: forall m n r. KnownNat m
  => AstInt r -> AstVarName Int -> Ast (1 + m + n) r -> [AstInt r]
  -> Ast (1 + n) r
build1VectorizeIndexVar n var v1 [] =
  unsafeCoerce $ build1VectorizeVar n (var, v1)  -- m is -1
build1VectorizeIndexVar n var v1 is@(i1 : rest1) =
  case v1 of
    AstOp opCode args ->
      AstOp opCode $ map (\w -> build1VectorizeIndex n var w is) args
    AstCond b v w ->
      if intVarInAstBool var b then
        AstSelect n (var, b)
                  (build1VectorizeIndex n var v is)
                  (build1VectorizeIndex n var w is)
      else
        AstCond b (build1VectorizeIndex n var v is)
                  (build1VectorizeIndex n var w is)
    AstSelect{} -> build1VectorizeIndexTry n var v1 is
      -- can't push the indexing down, so try analyzing the index instead;
      -- we may want to add yet another constructor that says "pick the element
      -- on this path out of this select" and hope it reduces fine elsewhere
      -- or we may partially evaluate @i@ and try to reduce on the spot
    AstConstInt{} ->
      AstConstant $ AstPrimalPart1 $ AstBuildPair n (var, AstIndexN v1 is)
    AstConst{} ->  -- var must be in i
      AstConstant $ AstPrimalPart1 $ AstBuildPair n (var, AstIndexN v1 is)
    AstConstant{} ->
      AstConstant $ AstPrimalPart1 $ AstBuildPair n (var, AstIndexN v1 is)
    AstScale (AstPrimalPart1 r) d ->
      AstScale (AstPrimalPart1 $ AstBuildPair n (var, AstIndexN r is))
               (build1VectorizeIndex n var d is)

    AstIndex v i -> build1VectorizeIndexVar n var v (i : is)
    AstIndexN v is2 -> build1VectorizeIndexVar n var v (is2 ++ is)
    AstSum v ->
      build1VectorizeVar n
        (var, AstSum (AstTranspose $ AstIndexN (AstTranspose v) is))
          -- that's because @index (sum v) i == sum (map (index i) v)@
    -- Can't push indexing down, so try analyzing the index instead:
    AstFromList{} -> build1VectorizeIndexTry n var v1 is
    AstFromVector{} -> build1VectorizeIndexTry n var v1 is
    -- Partially evaluate in constant time:
    AstKonst _k (v :: Ast n1 r) -> case rest1 of
      [] -> let v2 = (unsafeCoerce :: Ast n1 r -> Ast n r) v  -- m is -1
            in build1Vectorize n (var, v2)
              -- type of build1VectorizeIndex prevents rank 0
              -- TODO: simplify when/if it doesn't
      _ -> let v2 = (unsafeCoerce :: Ast n1 r -> Ast (1 + m + n) r) v
           in build1VectorizeIndex n var v2 rest1
    AstAppend v w ->
      let is2 = map (\i -> AstIntOp PlusIntOp [i, AstLength v]) is
      in build1Vectorize n
           (var, AstCond (AstRelInt LsOp [i1, AstLength v])
                         (AstIndexN v is)
                         (AstIndexN w is2))
          -- this is basically partial evaluation, but in constant
          -- time unlike evaluating AstFromList, etc.;
          -- this may get stuck as AstSelect eventually, but pushing indexing
          -- down into both v and w would then get stuck as well (twice!)
    AstSlice i2 _k v ->
      build1VectorizeIndex n var v (map (\i -> AstIntOp PlusIntOp [i, i2]) is)
    AstReverse v ->
      let revIs = AstIntOp MinusIntOp [AstIntOp MinusIntOp [AstLength v, 1], i1]
                  : rest1
      in build1VectorizeIndexVar n var v revIs
    -- Can't push indexing down, so try analyzing the index instead:
    AstTranspose{} -> build1VectorizeIndexTry n var v1 is
      -- a more general indexing needed, one intespersed with transpose
      -- or operating on the underlying vector of elements instead?
    AstTransposeGeneral{} -> build1VectorizeIndexTry n var v1 is
      -- an even more general indexing needed?
    AstFlatten{} -> build1VectorizeIndexTry n var v1 is
    AstReshape{} -> build1VectorizeIndexTry n var v1 is
      -- an even more general indexing needed?
    AstBuildPair{} -> AstBuildPair n (var, AstIndexN v1 is)
      -- TODO: a previous failure of vectorization that should have
      -- led to an abort instead of showing up late
      -- TODO: or a wonderful chance to recover failed vectorization,
      -- by taking only an element of this build! so shall failed
      -- vectorization not abort, after all? and only check at whole program
      -- vectorization end that no build has been left unvectorized?
      -- the code would be
      -- build1Vectorize n (var, substitute var2 i u2))
      -- or we'd use environments instead of the substitution
    AstGatherPair _n (_var2, _ixs2) _v -> undefined
      -- TODO: simplify to build (indexN v (subst i1 for var2 in ixs2 ++ rest1))

    AstSum0{} -> error "build1VectorizeIndexVar: wrong rank"
    AstDot0{} -> error "build1VectorizeIndexVar: wrong rank"
    AstFromList0N sh l ->
      build1VectorizeIndexVar @m n var (AstReshape sh $ AstFromList l) is
    AstFromVector0N sh l ->
      build1VectorizeIndexVar @m n var (AstReshape sh $ AstFromVector l) is
    AstKonst0N sh v ->
      let k = product sh
      in build1VectorizeIndexVar @m n var (AstReshape sh $ AstKonst k v) is
    AstBuildPair0N{} ->
      AstBuildPair n (var, AstIndexN v1 is)  -- see AstBuildPair above

    AstOMap0{} -> error "build1VectorizeIndexVar: wrong rank"
    AstOMap1{} ->
      AstConstant $ AstPrimalPart1 $ AstBuildPair n (var, AstIndexN v1 is)
    AstVar0{} -> error "build1VectorizeIndexVar: wrong rank"
    AstVar1{} ->  -- var must be in i, so it's hard to simplify
      build1VectorizeIndexTry n var v1 is
    -- All other patterns are redundant due to GADT typing.

-- This has to be done after indexing is pushed down as much as possible,
-- because it may eliminate some occurences of @var@ and so make this
-- analysis applicable. The downside is that we'd vectorize terms
-- we don't have to, but if we are nested in outer build1, the vectorization
-- would be needed anyway, so this hurts only at top-level.
-- TODO: a more nuanced approach would be to push indexing down
-- only as far as needed to eliminate the build variable from the term.
-- Not sure about nested builds and so multiple variables.
build1VectorizeIndexTry
  :: forall m n r. KnownNat m
  => AstInt r -> AstVarName Int -> Ast (1 + m + n) r -> [AstInt r]
  -> Ast (1 + n) r
build1VectorizeIndexTry n var v [] =
  unsafeCoerce $ build1Vectorize n (var, v)  -- m is -1
build1VectorizeIndexTry n var v is = case reverse is of
  [] -> error "build1VectorizeIndexTry: impossible empty path"
  iN : restRev ->
    if | intVarInAst var v -> AstBuildPair n (var, AstIndexN v is)  -- fail
       | or (map (intVarInAstInt var) restRev) -> AstGatherPair n (var, is) v
       | otherwise ->
         let w =
               -- this check is only needed due to the 1 + m hack
               -- and will vanish when we have sized index lists
               if null restRev
               then (unsafeCoerce :: Ast (1 + m + n) r -> Ast (1 + n) r) v
               else (unsafeCoerce :: Ast n r -> Ast (1 + n) r)
                       -- indexing one less
                      (AstIndexN v (reverse restRev))
         in case build1VectorizeIndexAnalyze n var w iN of
              Just u -> u  -- an extremely simple form found
              Nothing -> AstGatherPair n (var, is) v
                -- we didn't really need it anyway

-- TODO: we probably need to simplify to some normal form, but possibly
-- this would be even better to do and take advantage of earlier,
-- perhaps even avoiding pushing all the other indexing down
build1VectorizeIndexAnalyze
  :: forall n r.
     AstInt r -> AstVarName Int -> Ast (1 + n) r -> AstInt r
  -> Maybe (Ast (1 + n) r)
build1VectorizeIndexAnalyze n var v iN = case iN of
  AstIntVar var2 | var2 == var ->
    Just $ AstSlice 0 n v
  AstIntOp PlusIntOp [AstIntVar var2, i2]
    | var2 == var && not (intVarInAstInt var i2) ->
      Just $ AstSlice i2 n v
  AstIntOp PlusIntOp [i2, AstIntVar var2]
    | var2 == var && not (intVarInAstInt var i2) ->
      Just $ AstSlice i2 n v
  _ -> Nothing
    -- TODO: many more cases; not sure how systematic it can be

intVarInAst :: AstVarName Int -> Ast n r -> Bool
intVarInAst var = \case
  AstOp _ l -> or $ map (intVarInAst var) l
  AstCond b x y ->
    intVarInAstBool var b || intVarInAst var x || intVarInAst var y
  AstSelect n (_, b) x y ->
    intVarInAstInt var n || intVarInAstBool var b
    || intVarInAst var x || intVarInAst var y
  AstConstInt n -> intVarInAstInt var n
  AstConst{} -> False
  AstConstant (AstPrimalPart1 v) -> intVarInAst var v
  AstScale (AstPrimalPart1 v) u -> intVarInAst var v || intVarInAst var u

  AstIndex v ix -> intVarInAst var v || intVarInAstInt var ix
  AstIndexN v is -> intVarInAst var v || or (map (intVarInAstInt var) is)
  AstSum v -> intVarInAst var v
  AstFromList l -> or $ map (intVarInAst var) l  -- down from rank 1 to 0
  AstFromVector vl -> or $ map (intVarInAst var) $ V.toList vl
  AstKonst n v -> intVarInAstInt var n || intVarInAst var v
  AstAppend v u -> intVarInAst var v || intVarInAst var u
  AstSlice i k v -> intVarInAstInt var i || intVarInAstInt var k
                    || intVarInAst var v
  AstReverse v -> intVarInAst var v
  AstTranspose v -> intVarInAst var v
  AstTransposeGeneral _ v -> intVarInAst var v
  AstFlatten v -> intVarInAst var v
  AstReshape sh v -> or (map (intVarInAstInt var) sh) || intVarInAst var v
  AstBuildPair n (_, v) -> intVarInAstInt var n || intVarInAst var v
  AstGatherPair n (_, is) v ->
    intVarInAstInt var n || or (map (intVarInAstInt var) is)
    || intVarInAst var v

  AstSum0 v -> intVarInAst var v
  AstDot0 v u -> intVarInAst var v || intVarInAst var u
  AstFromList0N sh l -> or (map (intVarInAstInt var) sh)
                        || or (map (intVarInAst var) l)
  AstFromVector0N sh l -> or (map (intVarInAstInt var) sh)
                          || V.or (V.map (intVarInAst var) l)
  AstKonst0N sh v -> or (map (intVarInAstInt var) sh) || intVarInAst var v
  AstBuildPair0N sh (_, v) -> or (map (intVarInAstInt var) sh)
                              || intVarInAst var v

  AstOMap0 (_, v) u -> intVarInAst var v || intVarInAst var u
    -- the variable in binder position, so ignored (and should be distinct)
  AstOMap1 (_, v) u -> intVarInAst var v || intVarInAst var u
  AstVar0{} -> False  -- not an int variable
  AstVar1{} -> False  -- not an int variable

intVarInAstInt :: AstVarName Int -> AstInt r -> Bool
intVarInAstInt var = \case
  AstIntOp _ l -> or $ map (intVarInAstInt var) l
  AstIntCond b x y ->
    intVarInAstBool var b || intVarInAstInt var x || intVarInAstInt var y
  AstIntConst{} -> False
  AstIntVar var2 -> var == var2  -- the only int variable not in binder position
  AstLength v -> intVarInAst var v
  AstSize v -> intVarInAst var v
  AstMinIndex v -> intVarInAst var v
  AstMaxIndex v -> intVarInAst var v

intVarInAstBool :: AstVarName Int -> AstBool r -> Bool
intVarInAstBool var = \case
  AstBoolOp _ l -> or $ map (intVarInAstBool var) l
  AstBoolConst{} -> False
  AstRel _ l -> or $ map (intVarInAst var) l
  AstRelInt _ l  -> or $ map (intVarInAstInt var) l


-- * Odds and ends

leqAst :: Ast 0 r -> Ast 0 r -> AstBool r
leqAst d e = AstRel LeqOp [d, e]

gtAst :: Ast 0 r -> Ast 0 r -> AstBool r
gtAst d e = AstRel GtOp [d, e]

gtIntAst :: AstInt r -> AstInt r -> AstBool r
gtIntAst i j = AstRelInt GtOp [i, j]


-- * Interpretation of Ast in ADVal

-- First come definition of some ADVal combinators to be used below.
-- They are more general than their legacy versions for rank 1 above
-- and sometimes more general than the Ast operations.
index :: (ADModeAndNum d r, KnownNat n)
      => ADVal d (OR.Array (1 + n) r) -> Int -> ADVal d (OR.Array n r)
index (D u u') ix = dD (u `tindexR` ix)
                       (dIndex1 u' ix (head $ OR.shapeL u))

-- | First index is for outermost dimension; @1 + m@ is the length of the path;
-- empty path means identity.
-- TODO: speed up by using atPathInTensorR and dIndex0 if the codomain is 0.
indexN :: forall m n d r. (ADModeAndNum d r, KnownNat n, KnownNat m)
        => ADVal d (OR.Array (1 + m + n) r) -> [Int]
        -> ADVal d (OR.Array n r)
-- TODO: This is much faster, but gradient of dIndexN is not implemented yet:
-- indexN (D u u') ixs = dD (u `atPathInTensorNR` ixs)
--                          (dIndexN u' ixs (OR.shapeL u))
indexN d [] = (unsafeCoerce :: ADVal d (OR.Array (1 + m + n) r)
                             -> ADVal d (OR.Array n r)) d  -- m is -1
indexN d (ix : rest) =
  (unsafeCoerce  -- m is (1 + m2)
     :: (ADVal d (OR.Array (1 + m + n) r) -> [Int]
         -> ADVal d (OR.Array n r))
     -> (ADVal d (OR.Array (m + n) r) -> [Int]
         -> ADVal d (OR.Array n r)))
    indexN
      (index d ix) rest

sum' :: (ADModeAndNum d r, KnownNat n)
     => ADVal d (OR.Array (1 + n) r) -> ADVal d (OR.Array n r)
sum' (D u u') = dD (tsumR u)
                   (dSum1 (head $ OR.shapeL u) u')

fromList :: (ADModeAndNum d r, KnownNat n)
         => [ADVal d (OR.Array n r)]
         -> ADVal d (OR.Array (1 + n) r)
fromList lu =
  -- TODO: if lu is empty, crash if n =\ 0 or use List.NonEmpty.
  dD (tfromListR $ map (\(D u _) -> u) lu)
     (dFromList1 $ map (\(D _ u') -> u') lu)

fromVector :: (ADModeAndNum d r, KnownNat n)
           => Data.Vector.Vector (ADVal d (OR.Array n r))
           -> ADVal d (OR.Array (1 + n) r)
fromVector lu =
  dD (tfromVectorR $ V.map (\(D u _) -> u) lu)
     (dFromVector1 $ V.map (\(D _ u') -> u') lu)

konst :: (ADModeAndNum d r, KnownNat n)
      => Int -> ADVal d (OR.Array n r) -> ADVal d (OR.Array (1 + n) r)
konst n (D u u') = dD (tkonstR n u) (dKonst1 n u')

append :: (ADModeAndNum d r, KnownNat n)
       => ADVal d (OR.Array n r) -> ADVal d (OR.Array n r)
       -> ADVal d (OR.Array n r)
append (D u u') (D v v') = dD (tappendR u v)
                              (dAppend1 u' (head $ OR.shapeL u) v')

slice :: (ADModeAndNum d r, KnownNat n)
      => Int -> Int -> ADVal d (OR.Array n r) -> ADVal d (OR.Array n r)
slice i k (D u u') = dD (tsliceR i k u)
                        (dSlice1 i k u' (head $ OR.shapeL u))

reverse' :: (ADModeAndNum d r, KnownNat n)
         => ADVal d (OR.Array n r) -> ADVal d (OR.Array n r)
reverse' (D u u') = dD (treverseR u) (dReverse1 u')

transposeGeneral :: (ADModeAndNum d r, KnownNat n)
                 => [Int] -> ADVal d (OR.Array n r) -> ADVal d (OR.Array n r)
transposeGeneral perm (D u u') = dD (ttransposeGeneralR perm u)
                                    (dTransposeGeneral1 perm u')

reshape :: (ADModeAndNum d r, KnownNat n, KnownNat m)
        => OR.ShapeL -> ADVal d (OR.Array n r) -> ADVal d (OR.Array m r)
reshape sh (D u u') = dD (treshapeR sh u) (dReshape1 (OR.shapeL u) sh u')

-- The element-wise (POPL) version, but only one rank at a time.
build :: (ADModeAndNum d r, KnownNat n)
      => Int -> (Int -> ADVal d (OR.Array n r))
      -> ADVal d (OR.Array (1 + n) r)
build n f = fromList $ map f [0 .. n - 1]

gatherClosure :: (ADModeAndNum d r, KnownNat n, KnownNat m)
              => Int -> (Int -> [Int])
              -> ADVal d (OR.Array (m + n) r) -> ADVal d (OR.Array (1 + n) r)
gatherClosure n f (D u u') = dD (tgatherR n f u) (dGather1 n f (OR.shapeL u) u')

sum0 :: (ADModeAndNum d r, KnownNat n)
     => ADVal d (OR.Array n r) -> ADVal d r
sum0 (D u u') = dD (tsum0R u) (dSum0 (OR.shapeL u) u')

dot0 :: (ADModeAndNum d r, KnownNat n)
     => ADVal d (OR.Array n r) -> ADVal d (OR.Array n r) -> ADVal d r
dot0 (D u u') (D v v') = dD (tdot0R u v)
                            (dAdd (dDot0 v u') (dDot0 u v'))

fromList0N :: (ADModeAndNum d r, KnownNat n)
           => OR.ShapeL -> [ADVal d r]
           -> ADVal d (OR.Array n r)
fromList0N sh l =
  dD (tfromList0NR sh $ map (\(D u _) -> u) l)  -- I hope this fuses
     (dFromList01 sh $ map (\(D _ u') -> u') l)

fromVector0N :: (ADModeAndNum d r, KnownNat n)
             => OR.ShapeL -> Data.Vector.Vector (ADVal d r)
             -> ADVal d (OR.Array n r)
fromVector0N sh l =
  dD (tfromVector0NR sh $ V.convert $ V.map (\(D u _) -> u) l)  -- hope it fuses
     (dFromVector01 sh $ V.map (\(D _ u') -> u') l)

konst0N :: (ADModeAndNum d r, KnownNat n)
        => OR.ShapeL -> ADVal d r -> ADVal d (OR.Array (1 + n) r)
konst0N sh (D u u') = dD (tkonst0NR sh u) (dKonst01 sh u')

scalar :: ADModeAndNum d r => ADVal d r -> ADVal d (OR.Array 0 r)
scalar (D u u') = dD (OR.scalar u) (dScalar1 u')

unScalar :: ADModeAndNum d r => ADVal d (OR.Array 0 r) -> ADVal d r
unScalar (D u u') = dD (OR.unScalar u) (dUnScalar0 u')

interpretLambdaD1
  :: ADModeAndNum d r
  => IM.IntMap (AstVar (ADVal d r) (ADVal d (Vec r)))
  -> (AstVarName r, Ast 0 r)
  -> ADVal d r -> ADVal d r
interpretLambdaD1 env (AstVarName var, ast) =
  \d -> unScalar $ interpretAst (IM.insert var (AstVarR0 d) env) ast

interpretLambdaI1
  :: (ADModeAndNum d r, KnownNat n)
  => IM.IntMap (AstVar (ADVal d r) (ADVal d (Vec r)))
  -> (AstVarName Int, Ast n r)
  -> Int -> ADVal d (OR.Array n r)
interpretLambdaI1 env (AstVarName var, ast) =
  \i -> interpretAst (IM.insert var (AstVarI i) env) ast

interpretLambdaPath
  :: ADModeAndNum d r
  => IM.IntMap (AstVar (ADVal d r) (ADVal d (Vec r)))
  -> (AstVarName Int, [AstInt r])
  -> Int -> [Int]
interpretLambdaPath env (AstVarName var, asts) =
  \i -> map (interpretAstInt (IM.insert var (AstVarI i) env)) asts

interpretAstPrimal
  :: (ADModeAndNum d r, KnownNat n)
  => IM.IntMap (AstVar (ADVal d r) (ADVal d (Vec r)))
  -> Ast n r -> OR.Array n r
interpretAstPrimal env v = let D u _ = interpretAst env v in u

interpretAst
  :: (ADModeAndNum d r, KnownNat n)
  => IM.IntMap (AstVar (ADVal d r) (ADVal d (Vec r)))
  -> Ast n r -> ADVal d (OR.Array n r)
interpretAst env = \case
  AstOp opCode args ->
    interpretAstOp (interpretAst env) opCode args
  AstCond b a1 a2 -> if interpretAstBool env b
                     then interpretAst env a1
                     else interpretAst env a2
  AstSelect n (AstVarName var, b) a1 a2 ->
    let k = interpretAstInt env n
        f [i] = if interpretAstBool (IM.insert var (AstVarI i) env) b
                then 1
                else 0
        f _ = error "interpretAst: unexpected argument to AstSelect"
        bitmap = constant $ OR.generate [k] f
        v1 = interpretAst env a1
        v2 = interpretAst env a2
    in bitmap * v1 + v2 - bitmap * v2
  AstConstInt i -> fromInteger $ fromIntegral $ interpretAstInt env i
  AstConst a -> constant a
  AstConstant (AstPrimalPart1 a) -> constant $ interpretAstPrimal env a
  AstScale (AstPrimalPart1 r) d ->
    scale (interpretAstPrimal env r) (interpretAst env d)

  AstIndex v i -> index (interpretAst env v) (interpretAstInt env i)
  AstIndexN v is -> indexN (interpretAst env v) (map (interpretAstInt env) is)
  AstSum v -> sum' (interpretAst env v)
  AstFromList l -> fromList (map (interpretAst env) l)
  AstFromVector l -> fromVector (V.map (interpretAst env) l)
  AstKonst n v -> konst (interpretAstInt env n) (interpretAst env v)
  AstAppend x y -> append (interpretAst env x) (interpretAst env y)
  AstSlice i k v -> slice (interpretAstInt env i) (interpretAstInt env k)
                          (interpretAst env v)
  AstReverse v -> reverse' (interpretAst env v)
  AstTranspose v -> interpretAst env $ AstTransposeGeneral [1, 0] v
  AstTransposeGeneral perm v ->
    let d@(D u _) = interpretAst env v
    in if OR.rank u <= length perm - 1 then d else transposeGeneral perm d
  AstFlatten v -> let d@(D u _) = interpretAst env v
                  in reshape [OR.size u] d
  AstReshape ns v -> reshape (map (interpretAstInt env) ns)
                             (interpretAst env v)
  AstBuildPair i (var, AstConstant r) ->
    let n = interpretAstInt env i
    in constant
       $ OR.ravel . ORB.fromVector [n] . V.generate n
       $ \j -> let D v _ = interpretLambdaI1 env (var, AstConstant r) j
               in v
  AstBuildPair i (var, v) ->
    build (interpretAstInt env i) (interpretLambdaI1 env (var, v))
      -- fallback to POPL (memory blowup, but avoids functions on tape);
      -- an alternative is to use dBuild1 and store function on tape
  AstGatherPair i (var, is) v ->
    gatherClosure (interpretAstInt env i) (interpretLambdaPath env (var, is))
                  (interpretAst env v)
    -- TODO: currently we store the function on tape, because it doesn't
    -- cause recomputation of the gradient per-cell, unlike storing the build
    -- function on tape; for GPUs and libraries that don't understand Haskell
    -- closures, we cneck if the expressions involve tensor operations
    -- too hard for GPUs and, if not, we can store the AST expression
    -- on tape and translate it to whatever backend sooner or later;
    -- and if yes, fall back to POPL pre-computation that, unfortunately,
    -- leads to a tensor of deltas

  AstSum0 v -> scalar $ sum0 (interpretAst env v)
  AstDot0 x y -> scalar $ dot0 (interpretAst env x) (interpretAst env y)
  AstFromList0N sh l -> fromList0N (map (interpretAstInt env) sh)
                        $ map (unScalar . interpretAst env) l
  AstFromVector0N sh l -> fromVector0N (map (interpretAstInt env) sh)
                          $ V.map (unScalar . interpretAst env) l
  AstKonst0N sh r -> konst0N (map (interpretAstInt env) sh)
                             (unScalar $ interpretAst env r)
  AstBuildPair0N _sh (_vars, _r) -> undefined  -- TODO: type-level woes
    -- TODO: wait if vectorization forces us to generalize this to accept
    -- any rank and build it up according to @sh@ (which will then be
    -- only a partial shape, so should change its name)

  AstOMap0 (var, r) e ->  -- this only works on the primal part hence @constant@
    constant
    $ omap (\x -> let D u _ = interpretLambdaD1 env (var, r) (constant x)
                  in u)
           (interpretAstPrimal env e)
  AstOMap1 (var, r) e ->  -- this only works on the primal part hence @constant@
    constant
    $ omap (\x -> let D u _ = interpretLambdaD1 env (var, r) (constant x)
                  in u)
           (interpretAstPrimal env e)
  AstVar0 (AstVarName var) -> case IM.lookup var env of
    Just (AstVarR0 d) -> scalar d
    Just AstVarR1{} ->
      error $ "interpretAst: type mismatch for var " ++ show var
    Just AstVarI{} ->
      error $ "interpretAst: type mismatch for var " ++ show var
    Nothing -> error $ "interpretAst: unknown variable var " ++ show var
  AstVar1 (AstVarName var) -> case IM.lookup var env of
    Just AstVarR0{} ->
      error $ "interpretAst: type mismatch for var " ++ show var
    Just (AstVarR1 d) -> d
    Just AstVarI{} ->
      error $ "interpretAst: type mismatch for var " ++ show var
    Nothing -> error $ "interpretAst: unknown variable var " ++ show var

interpretAstInt :: ADModeAndNum d r
                => IM.IntMap (AstVar (ADVal d r) (ADVal d (Vec r)))
                -> AstInt r -> Int
interpretAstInt env = \case
  AstIntOp opCodeInt args ->
    interpretAstIntOp (interpretAstInt env) opCodeInt args
  AstIntCond b a1 a2 -> if interpretAstBool env b
                        then interpretAstInt env a1
                        else interpretAstInt env a2
  AstIntConst a -> a
  AstIntVar (AstVarName var) -> case IM.lookup var env of
    Just AstVarR0{} ->
      error $ "interpretAstInt: type mismatch for var " ++ show var
    Just AstVarR1{} ->
      error $ "interpretAstInt: type mismatch for var " ++ show var
    Just (AstVarI i) -> i
    Nothing -> error $ "interpretAstInt: unknown variable var " ++ show var
  AstLength v -> case OR.shapeL $ interpretAstPrimal env v of
    [] -> error "interpretAstInt: impossible shape for rank >= 1"
    len_outermost : _ -> len_outermost
  AstSize v -> product $ OR.shapeL $ interpretAstPrimal env v
  AstMinIndex v -> lminIndex $ interpretAst env v
  AstMaxIndex v -> lmaxIndex $ interpretAst env v

interpretAstBool :: ADModeAndNum d r
                 => IM.IntMap (AstVar (ADVal d r) (ADVal d (Vec r)))
                 -> AstBool r -> Bool
interpretAstBool env = \case
  AstBoolOp opCodeBool args ->
    interpretAstBoolOp (interpretAstBool env) opCodeBool args
  AstBoolConst a -> a
  AstRel opCodeRel args ->
    let f x = interpretAstPrimal env x
    in interpretAstRelOp f opCodeRel args
  AstRelInt opCodeRel args ->
    let f = interpretAstInt env
    in interpretAstRelOp f opCodeRel args

interpretAstOp :: RealFloat b
               => (c -> b) -> OpCode -> [c] -> b
{-# INLINE interpretAstOp #-}
interpretAstOp f PlusOp [u, v] = f u + f v
interpretAstOp f MinusOp [u, v] = f u - f v
interpretAstOp f TimesOp [u, v] = f u * f v
interpretAstOp f NegateOp [u] = negate $ f u
interpretAstOp f AbsOp [u] = abs $ f u
interpretAstOp f SignumOp [u] = signum $ f u
interpretAstOp f DivideOp [u, v] = f u / f v
interpretAstOp f RecipOp [u] = recip $ f u
interpretAstOp f ExpOp [u] = exp $ f u
interpretAstOp f LogOp [u] = log $ f u
interpretAstOp f SqrtOp [u] = sqrt $ f u
interpretAstOp f PowerOp [u, v] = f u ** f v
interpretAstOp f LogBaseOp [u, v] = logBase (f u) (f v)
interpretAstOp f SinOp [u] = sin $ f u
interpretAstOp f CosOp [u] = cos $ f u
interpretAstOp f TanOp [u] = tan $ f u
interpretAstOp f AsinOp [u] = asin $ f u
interpretAstOp f AcosOp [u] = acos $ f u
interpretAstOp f AtanOp [u] = atan $ f u
interpretAstOp f SinhOp [u] = sinh $ f u
interpretAstOp f CoshOp [u] = cosh $ f u
interpretAstOp f TanhOp [u] = tanh $ f u
interpretAstOp f AsinhOp [u] = asinh $ f u
interpretAstOp f AcoshOp [u] = acosh $ f u
interpretAstOp f AtanhOp [u] = atanh $ f u
interpretAstOp f Atan2Op [u, v] = atan2 (f u) (f v)
interpretAstOp f MaxOp [u, v] = max (f u) (f v)
interpretAstOp f MinOp [u, v] = min (f u) (f v)
interpretAstOp _ opCode args =
  error $ "interpretAstOp: wrong number of arguments"
          ++ show (opCode, length args)

interpretAstIntOp :: (AstInt r -> Int) -> OpCodeInt -> [AstInt r] -> Int
{-# INLINE interpretAstIntOp #-}
interpretAstIntOp f PlusIntOp [u, v] = f u + f v
interpretAstIntOp f MinusIntOp [u, v] = f u - f v
interpretAstIntOp f TimesIntOp [u, v] = f u * f v
interpretAstIntOp f NegateIntOp [u] = negate $ f u
interpretAstIntOp f AbsIntOp [u] = abs $ f u
interpretAstIntOp f SignumIntOp [u] = signum $ f u
interpretAstIntOp f MaxIntOp [u, v] = max (f u) (f v)
interpretAstIntOp f MinIntOp [u, v] = min (f u) (f v)
interpretAstIntOp f QuotIntOp [u, v] = quot (f u) (f v)
interpretAstIntOp f RemIntOp [u, v] = rem (f u) (f v)
interpretAstIntOp f DivIntOp [u, v] = div (f u) (f v)
interpretAstIntOp f ModIntOp [u, v] = mod (f u) (f v)
interpretAstIntOp _ opCodeInt args =
  error $ "interpretAstIntOp: wrong number of arguments"
          ++ show (opCodeInt, length args)

interpretAstBoolOp :: (AstBool r -> Bool) -> OpCodeBool -> [AstBool r]
                   -> Bool
{-# INLINE interpretAstBoolOp #-}
interpretAstBoolOp f NotOp [u] = not $ f u
interpretAstBoolOp f AndOp [u, v] = f u && f v
interpretAstBoolOp f OrOp [u, v] = f u || f v
interpretAstBoolOp f IffOp [u, v] = f u == f v
interpretAstBoolOp _ opCodeBool args =
  error $ "interpretAstBoolOp: wrong number of arguments"
          ++ show (opCodeBool, length args)

interpretAstRelOp :: Ord b => (a -> b) -> OpCodeRel -> [a] -> Bool
{-# INLINE interpretAstRelOp #-}
interpretAstRelOp f EqOp [u, v] = f u == f v
interpretAstRelOp f NeqOp [u, v] = f u /= f v
interpretAstRelOp f LeqOp [u, v] = f u <= f v
interpretAstRelOp f GeqOp [u, v] = f u >= f v
interpretAstRelOp f LsOp [u, v] = f u < f v
interpretAstRelOp f GtOp [u, v] = f u > f v
interpretAstRelOp _ opCodeRel args =
  error $ "interpretAstRelOp: wrong number of arguments"
          ++ show (opCodeRel, length args)
