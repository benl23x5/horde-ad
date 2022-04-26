{-# LANGUAGE AllowAmbiguousTypes, DataKinds, RankNTypes, TypeFamilies,
             TypeOperators #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# OPTIONS_GHC -fconstraint-solver-iterations=16 #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.KnownNat.Solver #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.Normalise #-}
-- | Shaped tensor-based implementation of Convolutional Neural Network
-- for classification of MNIST digits. Sports 2 hidden layers.
module HordeAd.Tool.MnistCnnShaped where

import Prelude

import qualified Data.Array.DynamicS as OT
import           Data.Array.Internal (valueOf)
import qualified Data.Array.ShapedS as OS
import           Data.Proxy (Proxy)
import qualified Data.Vector.Generic as V
import           GHC.TypeLits (KnownNat, type (+), type (<=), type Div)
import qualified Numeric.LinearAlgebra as HM

-- until stylish-haskell accepts NoStarIsType
import qualified GHC.TypeLits

import HordeAd.Core.DualClass
import HordeAd.Core.DualNumber
import HordeAd.Core.Engine
import HordeAd.Core.PairOfVectors (DualNumberVariables, varS)
import HordeAd.Tool.MnistData

patch_size, batch_size0, depth0, num_hidden0, final_image_size :: Int
patch_size = 5
batch_size0 = 16
depth0 = 16
num_hidden0 = 64
final_image_size = 10  -- if size was not increased: 7, see below

convMnistLenS :: Int -> Int -> Int -> (Int, [Int], [(Int, Int)], [OT.ShapeL])
convMnistLenS final_image_sz depth num_hidden =
  ( 0
  , []
  , []
  , [ [depth, 1, patch_size, patch_size]
    , [depth]
    , [depth, depth, patch_size, patch_size]
    , [depth]
    , [num_hidden, final_image_sz * final_image_sz * depth]
    , [num_hidden]
    , [sizeMnistLabel, num_hidden]
    , [sizeMnistLabel] ]
 )

convMnistMiddleS
  :: forall kheight_minus_1 kwidth_minus_1 out_channels
            in_height in_width in_channels batch_size r m.
     ( KnownNat kheight_minus_1, KnownNat kwidth_minus_1, KnownNat out_channels
     , KnownNat in_height, KnownNat in_width
     , KnownNat in_channels, KnownNat batch_size
     , 1 <= kheight_minus_1
     , 1 <= kwidth_minus_1  -- wrongly reported as redundant
     , DualMonad r m )
  => DualNumber (TensorS r '[ out_channels, in_channels
                            , kheight_minus_1 + 1, kwidth_minus_1 + 1 ])
  -> DualNumber (TensorS r '[batch_size, in_channels, in_height, in_width])
  -> DualNumber (TensorS r '[out_channels])
  -> m (DualNumber (TensorS r '[ batch_size, out_channels
                               , (in_height + kheight_minus_1) `Div` 2
                               , (in_width + kwidth_minus_1) `Div` 2 ]))
convMnistMiddleS ker x bias = do
  let yConv = conv24 ker x
      replicateBias
        :: DualNumber (TensorS r '[])
           -> DualNumber (TensorS r '[ in_height + kheight_minus_1
                                     , in_width + kwidth_minus_1 ])
      replicateBias = konstS . fromS0
      biasStretched = ravelFromListS
                      $ replicate (valueOf @batch_size)
                      $ mapS replicateBias bias
        -- TODO: this is weakly typed; add and use replicateS instead
  yRelu <- reluAct $ yConv + biasStretched
  maxPool24 @1 @2 yRelu

convMnistTwoS
  :: forall kheight_minus_1 kwidth_minus_1 num_hidden out_channels
            in_height in_width in_channels batch_size r m.
     ( KnownNat kheight_minus_1, KnownNat kwidth_minus_1
     , KnownNat num_hidden, KnownNat out_channels
     , KnownNat in_height, KnownNat in_width
     , KnownNat in_channels, KnownNat batch_size
     , 1 <= kheight_minus_1
     , 1 <= kwidth_minus_1
     , DualMonad r m )
  => Primal (TensorS r '[batch_size, in_channels, in_height, in_width])
  -> DualNumber (TensorS r '[ out_channels, in_channels
                            , kheight_minus_1 + 1, kwidth_minus_1 + 1 ])
  -> DualNumber (TensorS r '[out_channels])
  -> DualNumber (TensorS r '[ out_channels, out_channels
                            , kheight_minus_1 + 1, kwidth_minus_1 + 1 ])
  -> DualNumber (TensorS r '[out_channels])
  -> DualNumber (TensorS r '[ num_hidden
                            , out_channels
                                GHC.TypeLits.*
                                  ((in_height + kheight_minus_1) `Div` 2
                                   + kheight_minus_1) `Div` 2
                                GHC.TypeLits.*
                                  ((in_width + kwidth_minus_1) `Div` 2
                                   + kheight_minus_1) `Div` 2
                            ])
  -> DualNumber (TensorS r '[num_hidden])
  -> DualNumber (TensorS r '[SizeMnistLabel, num_hidden])
  -> DualNumber (TensorS r '[SizeMnistLabel])
  -> m (DualNumber (TensorS r '[SizeMnistLabel, batch_size]))
convMnistTwoS x ker1 bias1 ker2 bias2
              weigthsDense biasesDense weigthsReadout biasesReadout = do
  t1 <- convMnistMiddleS ker1 (scalar x) bias1
  t2 <- convMnistMiddleS ker2 t1 bias2
  let m1 = mapS reshapeS t2
      m2 = from2S (transpose2 (fromS2 m1))  -- TODO: add permuation transposeS
      denseLayer = weigthsDense <>$ m2 + asColumnS biasesDense
  denseRelu <- reluAct denseLayer
  returnLet $ weigthsReadout <>$ denseRelu + asColumnS biasesReadout

convMnistS
  :: forall kheight_minus_1 kwidth_minus_1 num_hidden out_channels
            in_height in_width in_channels batch_size r m.
     ( KnownNat kheight_minus_1, KnownNat kwidth_minus_1
     , KnownNat num_hidden, KnownNat out_channels
     , KnownNat in_height, KnownNat in_width
     , KnownNat in_channels, KnownNat batch_size
     , 1 <= kheight_minus_1
     , 1 <= kwidth_minus_1
     , DualMonad r m )
  => Primal (TensorS r '[batch_size, in_channels, in_height, in_width])
  -> DualNumberVariables r
  -> m (DualNumber (TensorS r '[SizeMnistLabel, batch_size]))
convMnistS x variables = do
  let ker1 = varS variables 0
      bias1 = varS variables 1
      ker2 = varS variables 2
      bias2 = varS variables 3
      weigthsDense = varS variables 4
      biasesDense = varS variables 5
      weigthsReadout = varS variables 6
      biasesReadout = varS variables 7
  convMnistTwoS @kheight_minus_1 @kwidth_minus_1 @num_hidden @out_channels
                x ker1 bias1 ker2 bias2
                weigthsDense biasesDense weigthsReadout biasesReadout

convMnistLossFusedSPoly
  :: forall kheight_minus_1 kwidth_minus_1 num_hidden out_channels
            in_height in_width in_channels batch_size r m.
     ( KnownNat kheight_minus_1, KnownNat kwidth_minus_1
     , KnownNat num_hidden, KnownNat out_channels
     , KnownNat in_height, KnownNat in_width
     , KnownNat in_channels, KnownNat batch_size
     , 1 <= kheight_minus_1
     , 1 <= kwidth_minus_1
     , DualMonad r m )
  => [MnistData2 (Primal r)]
  -> DualNumberVariables r
  -> m (DualNumber r)
convMnistLossFusedSPoly lmnistData variables = do
  let (lx, ltarget) = unzip lmnistData
      tx :: Primal (TensorS r '[batch_size, in_channels, in_height, in_width])
      tx = OS.fromList $ concatMap (HM.toList . HM.flatten) lx
  result <- convMnistS @kheight_minus_1 @kwidth_minus_1
                       @num_hidden @out_channels
                       tx variables
  vec@(D u _) <-
    lossSoftMaxCrossEntropyL (HM.fromColumns ltarget) (fromS2 result)
  returnLet $ scale (recip $ fromIntegral $ V.length u) $ sumElements0 vec

convMnistLossFusedS
  :: forall kheight_minus_1 kwidth_minus_1 num_hidden out_channels
            in_height in_width in_channels batch_size r m.
     ( DualMonad r m
     , kheight_minus_1 ~ 4
     , kwidth_minus_1 ~ 4
     , num_hidden ~ 64
     , out_channels ~ 16
     , in_height ~ 28
     , in_width ~ 28
     , in_channels ~ 1
     , batch_size ~ 16
     )
  => [MnistData2 (Primal r)]
  -> DualNumberVariables r
  -> m (DualNumber r)
convMnistLossFusedS =
  convMnistLossFusedSPoly @kheight_minus_1 @kwidth_minus_1
                          @num_hidden @out_channels
                          @in_height @in_width @in_channels @batch_size

convMnistTestSPoly
  :: forall kheight_minus_1 kwidth_minus_1 num_hidden out_channels
            in_height in_width in_channels batch_size r.
     ( KnownNat kheight_minus_1, KnownNat kwidth_minus_1
     , KnownNat num_hidden, KnownNat out_channels
     , KnownNat in_height, KnownNat in_width
     , KnownNat in_channels, KnownNat batch_size
     , 1 <= kheight_minus_1
     , 1 <= kwidth_minus_1
     , IsScalar r )
  => Proxy r -> [MnistData2 (Primal r)] -> Domains r -> Primal r
convMnistTestSPoly _ inputs parameters =
  let matchesLabels :: MnistData2 (Primal r) -> Bool
      matchesLabels (glyph, label) =
        let tx :: Primal (TensorS r '[ batch_size, in_channels
                                     , in_height, in_width ])
            tx = OS.fromVector $ HM.flatten glyph
            nn :: DualNumberVariables r
               -> DualMonadValue r (DualNumber (Tensor1 r))
            nn variables = do
              m <- convMnistS @kheight_minus_1 @kwidth_minus_1
                              @num_hidden @out_channels
                              tx variables
              softMaxActV $ flatten1 (fromS2 m)
            value = primalValue @r nn parameters
        in V.maxIndex value == V.maxIndex label
  in fromIntegral (length (filter matchesLabels inputs))
     / fromIntegral (length inputs)

convMnistTestS
  :: forall kheight_minus_1 kwidth_minus_1 num_hidden out_channels
            in_height in_width in_channels batch_size r.
     ( IsScalar r
     , kheight_minus_1 ~ 4
     , kwidth_minus_1 ~ 4
     , num_hidden ~ 64
     , out_channels ~ 16
     , in_height ~ 28
     , in_width ~ 28
     , in_channels ~ 1
     , batch_size ~ 1
     )
  => Proxy r -> [MnistData2 (Primal r)] -> Domains r -> Primal r
convMnistTestS =
  convMnistTestSPoly @kheight_minus_1 @kwidth_minus_1
                     @num_hidden @out_channels
                     @in_height @in_width @in_channels @batch_size
