{-# LANGUAGE FlexibleContexts, GADTs, KindSignatures #-}
-- | The second component of dual numbers, @Delta@, with it's evaluation
-- function. Neel Krishnaswami calls that "sparse vector expressions",
-- and indeed the codomain of the evaluation function is a vector,
-- because the gradient of an @R^n@ to @R@ function is an @R^n@ vector.
--
-- The algebraic structure here is, more or less, a vector space.
-- The extra ingenious variable constructor is used both to represent
-- sharing in order to avoid exponential blowup and to replace the one-hot
-- functionality with something cheaper and more uniform.
module HordeAd.Delta
  ( Delta (..)
  , DeltaId (..)
  , DeltaState (..)
  , evalBindings
  ) where

import Prelude

import           Control.Exception (assert)
import           Control.Monad (foldM, when)
import           Control.Monad.ST.Strict (ST, runST)
import           Data.Kind (Type)
import qualified Data.Vector
import qualified Data.Vector.Generic as V
import qualified Data.Vector.Generic.Mutable as VM
import qualified Data.Vector.Mutable
import qualified Data.Vector.Storable
import qualified Data.Vector.Storable.Mutable
import           Numeric.LinearAlgebra (Numeric)
import qualified Numeric.LinearAlgebra

data Delta :: Type -> Type where
  Zero :: Delta r
  Scale :: r -> Delta r -> Delta r
  Add :: Delta r -> Delta r -> Delta r
  Var :: DeltaId -> Delta r
  Dot :: Data.Vector.Storable.Vector r -> Delta (Data.Vector.Storable.Vector r)
      -> Delta r
  Konst :: Delta r -> Int -> Delta (Data.Vector.Storable.Vector r)
  Seq :: Data.Vector.Vector (Delta r) -> Delta (Data.Vector.Storable.Vector r)

newtype DeltaId = DeltaId Int
  deriving (Show, Eq, Ord)

data DeltaState r = DeltaState
  { deltaCounter  :: DeltaId
  , deltaBindings :: [Either (Delta r) (Delta (Data.Vector.Storable.Vector r))]
  }

buildVector :: forall s r.
                 (Eq r, Numeric r, Num (Data.Vector.Storable.Vector r))
            => Int -> Int -> DeltaState r -> Delta r
            -> ST s ( Data.Vector.Storable.Mutable.MVector s r
                    , Data.Vector.Mutable.MVector
                        s (Data.Vector.Storable.Vector r) )
buildVector dim dimV st d0 = do
  let DeltaId storeSize = deltaCounter st
  store <- VM.replicate storeSize 0
  -- TODO: this allocation costs us 7% runtime in 25/train2 2500 750
  -- (in general, it's costly whenever there's a lot of scalars):
  storeV <- VM.replicate storeSize (V.empty :: Data.Vector.Storable.Vector r)
  let eval :: r -> Delta r -> ST s ()
      eval !r = \case
        Zero -> return ()
        Scale k d -> eval (k * r) d
        Add d1 d2 -> eval r d1 >> eval r d2
        Var (DeltaId i) -> VM.modify store (+ r) i
        Dot vr vd -> evalV (Numeric.LinearAlgebra.scale r vr) vd
        Konst{} -> error "buildVector: Konst can't result in a scalar"
        Seq{} -> error "buildVector: Seq can't result in a scalar"
      evalV :: Data.Vector.Storable.Vector r
            -> Delta (Data.Vector.Storable.Vector r)
            -> ST s ()
      evalV !vr = \case
        Zero -> return ()
        Scale k d -> evalV (k * vr) d
        Add d1 d2 -> evalV vr d1 >> evalV vr d2
        Var (DeltaId i) -> let addToVector v = if V.null v then vr else v + vr
                           in VM.modify storeV addToVector i
        Dot{} -> error "buildVector: unboxed vectors of vectors not possible"
        Konst d _n -> V.mapM_ (`eval` d) vr
        Seq vd -> V.imapM_ (\i d -> eval (vr V.! i) d) vd
  eval 1 d0  -- dt is 1 or hardwired in f
  let evalUnlessZero :: DeltaId
                     -> Either (Delta r) (Delta (Data.Vector.Storable.Vector r))
                     -> ST s DeltaId
      evalUnlessZero (DeltaId !i) (Left d) = do
        r <- store `VM.read` i
        when (r /= 0) $  -- we init with exactly 0 above so the comparison is OK
          eval r d
        return $! DeltaId (pred i)
      evalUnlessZero (DeltaId !i) (Right d) = do
        r <- storeV `VM.read` i
        when (r /= V.empty) $
          evalV r d
        return $! DeltaId (pred i)
  minusOne <- foldM evalUnlessZero (DeltaId $ pred storeSize) (deltaBindings st)
  let _A = assert (minusOne == DeltaId (-1)) ()
  return (VM.slice 0 dim store, VM.slice dim dimV storeV)

evalBindings :: forall r.
                  (Eq r, Numeric r, Num (Data.Vector.Storable.Vector r))
             => Int -> Int -> DeltaState r -> Delta r
             -> ( Data.Vector.Storable.Vector r
                , Data.Vector.Vector (Data.Vector.Storable.Vector r) )
evalBindings dim dimV st d0 =
  -- We can't just call @V.create@ twice, because it would run
  -- the @ST@ action twice.
  runST $ do
    (res, resV) <- buildVector dim dimV st d0
    r <- V.unsafeFreeze res
    rV <- V.unsafeFreeze resV
    return (r, rV)
