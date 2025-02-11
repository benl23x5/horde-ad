{-# LANGUAGE DataKinds, ImpredicativeTypes, TypeFamilies #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.KnownNat.Solver #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.Normalise #-}
-- | Shaped tensor-based implementation of fully connected neutral network
-- for classification of MNIST digits. Sports 2 hidden layers.
-- Written in the old style without adaptors and with @fcnnMnistLenS@
-- and the @atS@ function instead.
module OldMnistFcnnShaped where

import Prelude

import           Control.Exception (assert)
import qualified Data.Array.DynamicS as OT
import qualified Data.Array.Shape
import qualified Data.Array.ShapedS as OS
import qualified Data.Vector.Generic as V

import HordeAd.Core.DualNumber
import HordeAd.Core.Engine
import HordeAd.Core.PairOfVectors (ADInputs, atS)
import MnistData

-- | Fully connected neural network for the MNIST digit classification task.
-- There are two hidden layers and both use the same activation function.
-- The width of the layers is determined by the dimensions of the matrices
-- and vectors given as dual number parameters (inputs).
-- The dimensions, in turn, can be computed by the @len*@ functions
-- on the basis of the requested widths, see above.
fcnnMnistLayersS
  :: forall widthHidden widthHidden2 d r. ADModeAndNum d r
  => StaticNat widthHidden -> StaticNat widthHidden2
  -> (forall sh. OS.Shape sh
      => ADVal d (OS.Array sh r) -> ADVal d (OS.Array sh r))
  -> OS.Array '[SizeMnistGlyph] r
  -- All below is the type of all paramters of this nn. The same is reflected
  -- in the length function below and read from inputs further down.
  -> ADVal d (OS.Array '[widthHidden, SizeMnistGlyph] r)
  -> ADVal d (OS.Array '[widthHidden] r)
  -> ADVal d (OS.Array '[widthHidden2, widthHidden] r)
  -> ADVal d (OS.Array '[widthHidden2] r)
  -> ADVal d (OS.Array '[SizeMnistLabel, widthHidden2] r)
  -> ADVal d (OS.Array '[SizeMnistLabel] r)
  -> ADVal d (OS.Array '[SizeMnistLabel] r)
fcnnMnistLayersS MkSN MkSN factivationHidden datum
                 weightsL0 biasesV0 weightsL1 biasesV1 weightsL2 biasesV2 =
  let !_A = assert (sizeMnistGlyphInt == OS.size datum) ()
      hiddenLayer1 = weightsL0 #>$ constant datum + biasesV0
      nonlinearLayer1 = factivationHidden hiddenLayer1
      hiddenLayer2 = weightsL1 #>$ nonlinearLayer1 + biasesV1
      nonlinearLayer2 = factivationHidden hiddenLayer2
      outputLayer = weightsL2 #>$ nonlinearLayer2 + biasesV2
  in outputLayer

-- It seems that without plugins or TH we really have to copy-paste
-- the six-element type list from signature of @nnMnistLayersS@.
fcnnMnistLenS
  :: forall widthHidden widthHidden2.
      StaticNat widthHidden -> StaticNat widthHidden2
  -> (Int, [Int], [(Int, Int)], [OT.ShapeL])
fcnnMnistLenS MkSN MkSN =
  ( 0
  , []
  , []
  , [ Data.Array.Shape.shapeT @'[widthHidden, SizeMnistGlyph]
    , Data.Array.Shape.shapeT @'[widthHidden]
    , Data.Array.Shape.shapeT @'[widthHidden2, widthHidden]
    , Data.Array.Shape.shapeT @'[widthHidden2]
    , Data.Array.Shape.shapeT @'[SizeMnistLabel, widthHidden2]
    , Data.Array.Shape.shapeT @'[SizeMnistLabel]
    ]
  )

fcnnMnistS
  :: forall widthHidden widthHidden2 d r. ADModeAndNum d r
  => StaticNat widthHidden -> StaticNat widthHidden2
  -> (forall sh. OS.Shape sh
      => ADVal d (OS.Array sh r) -> ADVal d (OS.Array sh r))
  -> OS.Array '[SizeMnistGlyph] r
  -> ADInputs d r
  -> ADVal d (OS.Array '[SizeMnistLabel] r)
{-# INLINE fcnnMnistS #-}
fcnnMnistS widthHidden@MkSN widthHidden2@MkSN
           factivationHidden datum inputs =
  let weightsL0 = atS inputs 0
      biasesV0 = atS inputs 1
      weightsL1 = atS inputs 2
      biasesV1 = atS inputs 3
      weightsL2 = atS inputs 4
      biasesV2 = atS inputs 5
  in fcnnMnistLayersS widthHidden widthHidden2
                      factivationHidden datum
                      weightsL0 biasesV0 weightsL1 biasesV1 weightsL2 biasesV2

-- | The neural network applied to concrete activation functions
-- and composed with the appropriate loss function, using fused
-- softMax and cross entropy as the loss function.
fcnnMnistLossFusedS
  :: forall widthHidden widthHidden2 d r. ADModeAndNum d r
  => StaticNat widthHidden -> StaticNat widthHidden2
  -> MnistData r -> ADInputs d r -> ADVal d r
fcnnMnistLossFusedS widthHidden widthHidden2 (datum, target) inputs =
  let result = fcnnMnistS widthHidden widthHidden2
                          logistic (OS.fromVector datum) inputs
  in lossSoftMaxCrossEntropyV target $ fromS1 result

fcnnMnistLossFusedReluS
  :: forall widthHidden widthHidden2 d r. ADModeAndNum d r
  => StaticNat widthHidden -> StaticNat widthHidden2
  -> MnistData r -> ADInputs d r -> ADVal d r
fcnnMnistLossFusedReluS widthHidden widthHidden2 (datum, target) inputs =
  let result = fcnnMnistS widthHidden widthHidden2
                          relu (OS.fromVector datum) inputs
  in lossSoftMaxCrossEntropyV target $ fromS1 result

-- | A function testing the neural network given testing set of inputs
-- and the trained parameters.
fcnnMnistTestS
  :: forall widthHidden widthHidden2 r. ADModeAndNum 'ADModeValue r
  => StaticNat widthHidden -> StaticNat widthHidden2
  -> [MnistData r] -> Domains r -> r
fcnnMnistTestS widthHidden widthHidden2 inputs parameters =
  let matchesLabels :: MnistData r -> Bool
      matchesLabels (glyph, label) =
        let nn = fcnnMnistS widthHidden widthHidden2
                            logistic (OS.fromVector glyph)
            v = OS.toVector $ valueOnDomains nn parameters
        in V.maxIndex v == V.maxIndex label
  in fromIntegral (length (filter matchesLabels inputs))
     / fromIntegral (length inputs)
