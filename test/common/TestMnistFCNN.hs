{-# LANGUAGE DataKinds, RankNTypes, TypeFamilies #-}
module TestMnistFCNN
  ( testTrees, shortTestForCITrees, mnistTestCase2T, mnistTestCase2D
  ) where

import Prelude

import           Control.Arrow ((&&&))
import           Control.DeepSeq
import           Control.Monad (foldM, when)
import qualified Data.Array.DynamicS as OT
import           Data.Coerce (coerce)
import           Data.List (foldl')
import           Data.List.Index (imap)
import           Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import qualified Data.Vector.Generic as V
import qualified Numeric.LinearAlgebra as LA
import           System.IO (hFlush, hPutStrLn, stderr)
import           System.Random
import           Test.Tasty
import           Test.Tasty.HUnit hiding (assert)
import           Test.Tasty.QuickCheck hiding (label, shuffle)
import           Text.Printf
import           Unsafe.Coerce (unsafeCoerce)

import HordeAd
import HordeAd.External.OptimizerTools
import MnistData
import MnistFcnnMatrix
import MnistFcnnShaped
import MnistFcnnVector
import OldMnistFcnnShaped

import Tool.EqEpsilon
import Tool.Shared

testTrees :: [TestTree]
testTrees = [ dumbMnistTests
            , vectorMnistTests
            , matrixMnistTests
            , shortCIMnistTests
            , longMnistTests
            ]

shortTestForCITrees :: [TestTree]
shortTestForCITrees = [ dumbMnistTests
                      , shortCIMnistTests
                      ]
mnistTestCase2VA
  :: String
  -> Int
  -> Int
  -> (Int
      -> Int
      -> MnistData Double
      -> ADFcnnMnist1Parameters 'ADModeGradient Double
      -> ADVal 'ADModeGradient Double)
  -> Int
  -> Int
  -> Double
  -> Double
  -> TestTree
mnistTestCase2VA prefix epochs maxBatches trainWithLoss widthHidden widthHidden2
                 gamma expected =
  let (nParams0, nParams1, _, _) = afcnnMnistLen1 widthHidden widthHidden2
      params0Init = LA.randomVector 44 LA.Uniform nParams0 - LA.scalar 0.5
      params1Init = V.fromList $
        imap (\i nPV -> LA.randomVector (44 + nPV + i) LA.Uniform nPV
                        - LA.scalar 0.5)
             nParams1
      -- This is a very ugly and probably unavoidable boilerplate:
      -- we have to manually define a dummy value of type ADFcnnMnist1Parameters
      -- with the correct list lengths (vector lengths can be fake)
      -- to bootstrap the adaptor machinery. Such boilerplate can be
      -- avoided only with shapely typed tensors and scalars or when
      -- not using adaptors.
      valsInit = ( (replicate widthHidden V.empty, V.empty)
                 , (replicate widthHidden2 V.empty, V.empty)
                 , (replicate sizeMnistLabelInt V.empty, V.empty) )
      name = prefix ++ ": "
             ++ unwords [ show epochs, show maxBatches
                        , show widthHidden, show widthHidden2
                        , show nParams0, show (length nParams1)
                        , show (sum nParams1 + nParams0), show gamma ]
      ftest mnist testParams =
        afcnnMnistTest1 widthHidden widthHidden2 mnist
                        (valueAtDomains valsInit
                         $ uncurry domainsFrom01 testParams)
  in testCase name $ do
       hPutStrLn stderr $ printf "\n%s: Epochs to run/max batches per epoch: %d/%d"
              prefix epochs maxBatches
       trainData <- loadMnistData trainGlyphsPath trainLabelsPath
       testData <- loadMnistData testGlyphsPath testLabelsPath
       -- Mimic how backprop tests and display it, even though tests
       -- should not print, in principle.
       let runBatch :: (Domain0 Double, Domain1 Double)
                    -> (Int, [MnistData Double])
                    -> IO (Domain0 Double, Domain1 Double)
           runBatch (!params0, !params1) (k, chunk) = do
             let f mnist adinputs =
                   trainWithLoss widthHidden widthHidden2
                                 mnist (parseADInputs valsInit adinputs)
                 (resS, resV) =
                   (domains0 &&& domains1) . fst
                   $ sgd gamma f chunk (domainsFrom01 params0 params1)
                 res = (resS, resV)
                 !trainScore = ftest chunk res
                 !testScore = ftest testData res
                 !lenChunk = length chunk
             hPutStrLn stderr $ printf "\n%s: (Batch %d with %d points)" prefix k lenChunk
             hPutStrLn stderr $ printf "%s: Training error:   %.2f%%" prefix ((1 - trainScore) * 100)
             hPutStrLn stderr $ printf "%s: Validation error: %.2f%%" prefix ((1 - testScore ) * 100)
             return res
       let runEpoch :: Int -> (Domain0 Double, Domain1 Double)
                    -> IO (Domain0 Double, Domain1 Double)
           runEpoch n params2 | n > epochs = return params2
           runEpoch n params2 = do
             hPutStrLn stderr $ printf "\n%s: [Epoch %d]" prefix n
             let trainDataShuffled = shuffle (mkStdGen $ n + 5) trainData
                 chunks = take maxBatches
                          $ zip [1 ..] $ chunksOf 5000 trainDataShuffled
             !res <- foldM runBatch params2 chunks
             runEpoch (succ n) res
       res <- runEpoch 1 (params0Init, params1Init)
       let testErrorFinal = 1 - ftest testData res
       testErrorFinal @?~ expected

mnistTestCase2L
  :: String
  -> Int
  -> Int
  -> (MnistData Double
      -> ADInputs 'ADModeGradient Double
      -> ADVal 'ADModeGradient Double)
  -> Int
  -> Int
  -> Double
  -> Double
  -> TestTree
mnistTestCase2L prefix epochs maxBatches trainWithLoss widthHidden widthHidden2
                gamma expected =
  let ((nParams0, nParams1, nParams2, _), totalParams, range, parameters0) =
        initializerFixed 44 0.5 (fcnnMnistLen2 widthHidden widthHidden2)
      name = prefix ++ ": "
             ++ unwords [ show epochs, show maxBatches
                        , show widthHidden, show widthHidden2
                        , show nParams0, show nParams1, show nParams2
                        , show totalParams, show gamma, show range]
  in testCase name $ do
       hPutStrLn stderr $ printf "\n%s: Epochs to run/max batches per epoch: %d/%d"
              prefix epochs maxBatches
       trainData <- loadMnistData trainGlyphsPath trainLabelsPath
       testData <- loadMnistData testGlyphsPath testLabelsPath
       -- Mimic how backprop tests and display it, even though tests
       -- should not print, in principle.
       let runBatch :: Domains Double
                    -> (Int, [MnistData Double])
                    -> IO (Domains Double)
           runBatch !domains (k, chunk) = do
             let f = trainWithLoss
                 res = fst $ sgd gamma f chunk domains
                 !trainScore = fcnnMnistTest2 @Double chunk res
                 !testScore = fcnnMnistTest2 @Double testData res
                 !lenChunk = length chunk
             hPutStrLn stderr $ printf "\n%s: (Batch %d with %d points)" prefix k lenChunk
             hPutStrLn stderr $ printf "%s: Training error:   %.2f%%" prefix ((1 - trainScore) * 100)
             hPutStrLn stderr $ printf "%s: Validation error: %.2f%%" prefix ((1 - testScore ) * 100)
             return res
       let runEpoch :: Int
                    -> Domains Double
                    -> IO (Domains Double)
           runEpoch n params2 | n > epochs = return params2
           runEpoch n params2 = do
             hPutStrLn stderr $ printf "\n%s: [Epoch %d]" prefix n
             let trainDataShuffled = shuffle (mkStdGen $ n + 5) trainData
                 chunks = take maxBatches
                          $ zip [1 ..] $ chunksOf 5000 trainDataShuffled
             !res <- foldM runBatch params2 chunks
             runEpoch (succ n) res
       res <- runEpoch 1 parameters0
       let testErrorFinal = 1 - fcnnMnistTest2 testData res
       testErrorFinal @?~ expected

mnistTestCase2T
  :: Bool
  -> String
  -> Int
  -> Int
  -> (MnistData Double
      -> ADInputs 'ADModeGradient Double
      -> ADVal 'ADModeGradient Double)
  -> Int
  -> Int
  -> Double
  -> Double
  -> TestTree
mnistTestCase2T reallyWriteFile
                prefix epochs maxBatches trainWithLoss widthHidden widthHidden2
                gamma expected =
  let ((nParams0, nParams1, nParams2, _), totalParams, range, !parameters0) =
        initializerFixed 44 0.5 (fcnnMnistLen2 widthHidden widthHidden2)
      name = prefix ++ " "
             ++ unwords [ show epochs, show maxBatches
                        , show widthHidden, show widthHidden2
                        , show nParams0, show nParams1, show nParams2
                        , show totalParams, show gamma, show range]
  in testCase name $ do
       hPutStrLn stderr $ printf "\n%s: Epochs to run/max batches per epoch: %d/%d"
              prefix epochs maxBatches
       trainData0 <- loadMnistData trainGlyphsPath trainLabelsPath
       testData <- loadMnistData testGlyphsPath testLabelsPath
       let !trainData = force $ shuffle (mkStdGen 6) trainData0
       -- Mimic how backprop tests and display it, even though tests
       -- should not print, in principle.
       let runBatch :: (Domains Double, [(POSIXTime, Double)])
                    -> (Int, [MnistData Double])
                    -> IO (Domains Double, [(POSIXTime, Double)])
           runBatch (!domains, !times)
                    (k, chunk) = do
             when (k `mod` 100 == 0) $ do
               hPutStrLn stderr $ printf "%s: %d " prefix k
               hFlush stderr
             let f = trainWithLoss
                 (!params0New, !v) = sgd gamma f chunk domains
             time <- getPOSIXTime
             return (params0New, (time, v) : times)
       let runEpoch :: Int
                    -> (Domains Double, [(POSIXTime, Double)])
                    -> IO (Domains Double, [(POSIXTime, Double)])
           runEpoch n params2times | n > epochs = return params2times
           runEpoch n (!params2, !times2) = do
             hPutStrLn stderr $ printf "\n%s: [Epoch %d]" prefix n
             let !trainDataShuffled =
                   if n > 1
                   then shuffle (mkStdGen $ n + 5) trainData
                   else trainData
                 chunks = take maxBatches
                          $ zip [1 ..] $ chunksOf 1 trainDataShuffled
             res <- foldM runBatch (params2, times2) chunks
             runEpoch (succ n) res
       timeBefore <- getPOSIXTime
       (res, times) <- runEpoch 1 (parameters0, [])
       let ppTime (t, l) = init (show (t - timeBefore)) ++ " " ++ show l
       when reallyWriteFile $
         writeFile "walltimeLoss.txt" $ unlines $ map ppTime times
       let testErrorFinal = 1 - fcnnMnistTest2 testData res
       testErrorFinal @?~ expected


mnistTestCase2D
  :: Bool
  -> Int
  -> Bool
  -> String
  -> Int
  -> Int
  -> (MnistData Double
      -> ADInputs 'ADModeGradient Double
      -> ADVal 'ADModeGradient Double)
  -> Int
  -> Int
  -> Double
  -> Double
  -> TestTree
mnistTestCase2D reallyWriteFile miniBatchSize decay
                prefix epochs maxBatches trainWithLoss widthHidden widthHidden2
                gamma0 expected =
  let np = fcnnMnistLen2 widthHidden widthHidden2
      ((nParams0, nParams1, nParams2, _), totalParams, range, !parameters0) =
        initializerFixed 44 0.5 np
      name = prefix ++ " "
             ++ unwords [ show epochs, show maxBatches
                        , show widthHidden, show widthHidden2
                        , show nParams0, show nParams1, show nParams2
                        , show totalParams, show gamma0, show range]
  in testCase name $ do
       hPutStrLn stderr $ printf "\n%s: Epochs to run/max batches per epoch: %d/%d"
              prefix epochs maxBatches
       trainData0 <- loadMnistData trainGlyphsPath trainLabelsPath
       testData <- loadMnistData testGlyphsPath testLabelsPath
       let !trainData = force $ shuffle (mkStdGen 6) trainData0
       -- Mimic how backprop tests and display it, even though tests
       -- should not print, in principle.
       let runBatch :: (Domains Double, [(POSIXTime, Double)])
                    -> (Int, [MnistData Double])
                    -> IO (Domains Double, [(POSIXTime, Double)])
           runBatch (!domains, !times)
                    (k, chunk) = do
             when (k `mod` 100 == 0) $ do
               hPutStrLn stderr $ printf "%s: %d " prefix k
               hFlush stderr
             let f = trainWithLoss
                 gamma = if decay
                         then gamma0 * exp (- fromIntegral k * 1e-4)
                         else gamma0
                 (!params0New, !v) =
                   sgdBatchForward (33 + k * 7) miniBatchSize gamma f chunk
                                   domains np
             time <- getPOSIXTime
             return (params0New, (time, v) : times)
       let runEpoch :: Int
                    -> (Domains Double, [(POSIXTime, Double)])
                    -> IO (Domains Double, [(POSIXTime, Double)])
           runEpoch n params2times | n > epochs = return params2times
           runEpoch n (!params2, !times2) = do
             hPutStrLn stderr $ printf "\n%s: [Epoch %d]" prefix n
             let !trainDataShuffled =
                   if n > 1
                   then shuffle (mkStdGen $ n + 5) trainData
                   else trainData
                 chunks = take maxBatches
                          $ zip [1 ..]
                          $ chunksOf miniBatchSize trainDataShuffled
             res <- foldM runBatch (params2, times2) chunks
             runEpoch (succ n) res
       timeBefore <- getPOSIXTime
       (res, times) <- runEpoch 1 (parameters0, [])
       let ppTime (t, l) = init (show (t - timeBefore)) ++ " " ++ show l
       when reallyWriteFile $
         writeFile "walltimeLoss.txt" $ unlines $ map ppTime times
       let testErrorFinal = 1 - fcnnMnistTest2 testData res
       testErrorFinal @?~ expected

-- | Stochastic Gradient Descent with mini-batches, taking the mean
-- of the results from each mini-batch. Additionally, it uses
-- "forward gradient" from "Gradients without Backpropagation"
-- by Atilim Gunes Baydin, Barak A. Pearlmutter, Don Syme, Frank Wood,
-- Philip Torr.
--
-- Note that we can't generalize this to use either
-- @slowFwdGeneral@ or @revGeneral@, because the optimized call
-- to @updateWithGradient@ below would not be possible with the common API
-- for obtaining gradients and at least twice more allocations would
-- be done there. With small mini-batch sizes this matters,
-- especially for optimal forward gradient implementation
-- @fwdOnADInputs@, where there's no overhead from storing
-- and evaluating delta-expressions.
--
-- An option: vectorize and only then take the mean of the vector of results
-- and also parallelize taking advantage of vectorization (but currently
-- we have a global state, so that's tricky).
sgdBatchForward
  :: forall a.
     Int
  -> Int  -- ^ batch size
  -> Double  -- ^ gamma (learning_rate?)
  -> (a -> ADInputs 'ADModeGradient Double -> ADVal 'ADModeGradient Double)
  -> [a]  -- ^ training data
  -> Domains Double  -- ^ initial parameters
  -> (Int, [Int], [(Int, Int)], [OT.ShapeL])
  -> (Domains Double, Double)
sgdBatchForward seed0 batchSize gamma f trainingData parameters0 nParameters =
  go seed0 trainingData parameters0 0
 where
  deltaInputs = generateDeltaInputs parameters0
  go :: Int -> [a] -> Domains Double -> Double -> (Domains Double, Double)
  go _ [] parameters v = (parameters, v)
  go seed l parameters _ =
    let (batch, rest) = splitAt batchSize l
        fAdd :: ADInputs 'ADModeGradient Double
             -> ADVal 'ADModeGradient Double -> a
             -> ADVal 'ADModeGradient Double
        fAdd vars !acc a = acc + f a vars
        fBatch :: ADInputs 'ADModeGradient Double
               -> ADVal 'ADModeGradient Double
        fBatch vars =
          let resBatch = foldl' (fAdd vars) 0 batch
          in resBatch / fromIntegral (length batch)
        unitVarianceRange = sqrt 12 / 2
        (g1, g2) = (seed + 5, seed + 13)
        (_, _, _, direction) = initializerFixed g1 unitVarianceRange nParameters
        inputs = makeADInputs parameters deltaInputs
        (directionalDerivative, valueNew) =
          slowFwdOnADInputs inputs fBatch direction
        gammaDirectional = gamma * directionalDerivative
        parametersNew = updateWithGradient gammaDirectional parameters direction
    in go g2 rest parametersNew valueNew


mnistTestCase2F
  :: Bool
  -> Int
  -> Bool
  -> String
  -> Int
  -> Int
  -> (MnistData Double
      -> ADInputs 'ADModeDerivative Double
      -> ADVal 'ADModeDerivative Double)
  -> Int
  -> Int
  -> Double
  -> Double
  -> TestTree
mnistTestCase2F reallyWriteFile miniBatchSize decay
                prefix epochs maxBatches trainWithLoss widthHidden widthHidden2
                gamma0 expected =
  let np = fcnnMnistLen2 widthHidden widthHidden2
      ((nParams0, nParams1, nParams2, _), totalParams, range, !parameters0) =
        initializerFixed 44 0.5 np
      name = prefix ++ " "
             ++ unwords [ show epochs, show maxBatches
                        , show widthHidden, show widthHidden2
                        , show nParams0, show nParams1, show nParams2
                        , show totalParams, show gamma0, show range]
  in testCase name $ do
       hPutStrLn stderr $ printf "\n%s: Epochs to run/max batches per epoch: %d/%d"
              prefix epochs maxBatches
       trainData0 :: [MnistData Float]
         <- loadMnistData trainGlyphsPath trainLabelsPath
       testData <- loadMnistData testGlyphsPath testLabelsPath
       let !trainData = coerce $ force $ shuffle (mkStdGen 6) trainData0
       -- Mimic how backprop tests and display it, even though tests
       -- should not print, in principle.
       let runBatch :: (Domains Double, [(POSIXTime, Double)])
                    -> (Int, [MnistData Double])
                    -> IO (Domains Double, [(POSIXTime, Double)])
           runBatch (!domains, !times)
                    (k, chunk) = do
             when (k `mod` 100 == 0) $ do
               hPutStrLn stderr $ printf "%s: %d " prefix k
               hFlush stderr
             let f = trainWithLoss
                 gamma = if decay
                         then gamma0 * exp (- fromIntegral k * 1e-4)
                         else gamma0
                 (!params0New, !v) =
                   sgdBatchFastForward (33 + k * 7) miniBatchSize gamma f chunk
                                       domains np
             time <- getPOSIXTime
             return (params0New, (time, v) : times)
       let runEpoch :: Int
                    -> (Domains Double, [(POSIXTime, Double)])
                    -> IO (Domains Double, [(POSIXTime, Double)])
           runEpoch n params2times | n > epochs = return params2times
           runEpoch n (!params2, !times2) = do
             hPutStrLn stderr $ printf "\n%s: [Epoch %d]" prefix n
             let !trainDataShuffled =
                   if n > 1
                   then shuffle (mkStdGen $ n + 5) trainData
                   else trainData
                 chunks = take maxBatches
                          $ zip [1 ..]
                          $ chunksOf miniBatchSize trainDataShuffled
             res <- foldM runBatch (params2, times2) chunks
             runEpoch (succ n) res
       timeBefore <- getPOSIXTime
       (res, times) <- runEpoch 1 (parameters0, [])
       let ppTime (t, l) = init (show (t - timeBefore)) ++ " " ++ show l
       when reallyWriteFile $
         writeFile "walltimeLoss.txt" $ unlines $ map ppTime times
       let testErrorFinal = 1 - fcnnMnistTest2 testData res
       testErrorFinal @?~ expected

-- | A variant of 'sgdBatchForward' with fast forward derivative computation.
sgdBatchFastForward
  :: forall a.
     Int
  -> Int  -- ^ batch size
  -> Double  -- ^ gamma (learning_rate?)
  -> (a -> ADInputs 'ADModeDerivative Double -> ADVal 'ADModeDerivative Double)
  -> [a]  -- ^ training data
  -> Domains Double  -- ^ initial parameters
  -> (Int, [Int], [(Int, Int)], [OT.ShapeL])
  -> (Domains Double, Double)
sgdBatchFastForward seed0 batchSize gamma f trainingData
                    parameters0 nParameters =
  go seed0 trainingData parameters0 0
 where
  go :: Int -> [a] -> Domains Double -> Double -> (Domains Double, Double)
  go _ [] parameters v = (parameters, v)
  go seed l parameters@Domains{..} _ =
    let (batch, rest) = splitAt batchSize l
        fAdd :: ADInputs 'ADModeDerivative Double
             -> ADVal 'ADModeDerivative Double
             -> a
             -> ADVal 'ADModeDerivative Double
        fAdd vars !acc a = acc + f a vars
        fBatch :: ADInputs 'ADModeDerivative Double
               -> ADVal 'ADModeDerivative Double
        fBatch vars =
          let resBatch = foldl' (fAdd vars) 0 batch
          in resBatch / fromIntegral (length batch)
        unitVarianceRange = sqrt 12 / 2
        (g1, g2) = (seed + 5, seed + 13)
        (_, _, _, direction@(Domains dparams0 dparams1 dparams2 dparamsX)) =
          initializerFixed g1 unitVarianceRange nParameters
        inputs =
          makeADInputs
            (Domains (coerce domains0) (coerce domains1) (coerce domains2)
                     ( unsafeCoerce domainsX))
            (V.convert dparams0, dparams1, dparams2, dparamsX)
        (directionalDerivative, valueNew) =
          fwdOnADInputs inputs fBatch
        gammaDirectional = gamma * directionalDerivative
        parametersNew = updateWithGradient gammaDirectional parameters direction
    in go g2 rest parametersNew valueNew


mnistTestCase2S
  :: forall widthHidden widthHidden2.
     StaticNat widthHidden -> StaticNat widthHidden2
  -> String
  -> Int
  -> Int
  -> (forall d r. ADModeAndNum d r
      => StaticNat widthHidden -> StaticNat widthHidden2
      -> MnistData r
      -> ADFcnnMnistParameters widthHidden widthHidden2 d r
      -> ADVal d r)
  -> Double
  -> Double
  -> TestTree
mnistTestCase2S widthHidden@MkSN widthHidden2@MkSN
                prefix epochs maxBatches trainWithLoss gamma expected =
  let seed = mkStdGen 44
      range = 0.5
      valsInit
        :: Value (ADFcnnMnistParameters widthHidden widthHidden2
                                       'ADModeGradient Double)
      valsInit = fst $ randomVals range seed
      parametersInit = toDomains valsInit
      name = prefix ++ ": "
             ++ unwords [ show epochs, show maxBatches
                        , show (staticNatValue widthHidden :: Int)
                        , show (staticNatValue widthHidden2 :: Int)
                        , show (nParams valsInit)
                        , show (nScalars valsInit)
                        , show gamma, show range ]
      ftest :: [MnistData Double]
            -> Domains Double
            -> Double
      ftest mnist testParams =
        afcnnMnistTestS widthHidden widthHidden2
                        mnist (valueAtDomains valsInit testParams)
  in testCase name $ do
    hPutStrLn stderr $ printf "\n%s: Epochs to run/max batches per epoch: %d/%d"
                              prefix epochs maxBatches
    trainData <- loadMnistData trainGlyphsPath trainLabelsPath
    testData <- loadMnistData testGlyphsPath testLabelsPath
    let runBatch :: Domains Double
                 -> (Int, [MnistData Double])
                 -> IO (Domains Double)
        runBatch !domains (k, chunk) = do
          let f mnist adinputs =
                trainWithLoss widthHidden widthHidden2
                              mnist (parseADInputs valsInit adinputs)
              res = fst $ sgd gamma f chunk domains
              !trainScore = ftest chunk res
              !testScore = ftest testData res
              !lenChunk = length chunk
          hPutStrLn stderr $ printf "\n%s: (Batch %d with %d points)" prefix k lenChunk
          hPutStrLn stderr $ printf "%s: Training error:   %.2f%%" prefix ((1 - trainScore) * 100)
          hPutStrLn stderr $ printf "%s: Validation error: %.2f%%" prefix ((1 - testScore ) * 100)
          return res
    let runEpoch :: Int
                 -> Domains Double
                 -> IO (Domains Double)
        runEpoch n params2 | n > epochs = return params2
        runEpoch n params2 = do
          hPutStrLn stderr $ printf "\n%s: [Epoch %d]" prefix n
          let trainDataShuffled = shuffle (mkStdGen $ n + 5) trainData
              chunks = take maxBatches
                       $ zip [1 ..] $ chunksOf 5000 trainDataShuffled
          !res <- foldM runBatch params2 chunks
          runEpoch (succ n) res
    res <- runEpoch 1 parametersInit
    let testErrorFinal = 1 - ftest testData res
    testErrorFinal @?~ expected

mnistTestCase2O
  :: forall widthHidden widthHidden2.
     StaticNat widthHidden -> StaticNat widthHidden2
  -> String
  -> Int
  -> Int
  -> (forall d r. ADModeAndNum d r
      => StaticNat widthHidden -> StaticNat widthHidden2
      -> MnistData r -> ADInputs d r -> ADVal d r)
  -> Double
  -> Double
  -> TestTree
mnistTestCase2O widthHidden@MkSN widthHidden2@MkSN
                prefix epochs maxBatches trainWithLoss gamma expected =
  let ((_, _, _, nParamsX), totalParams, range, parametersInit) =
        initializerFixed 44 0.5 (fcnnMnistLenS widthHidden widthHidden2)
      name = prefix ++ ": "
             ++ unwords [ show epochs, show maxBatches
                        , show (staticNatValue widthHidden :: Int)
                        , show (staticNatValue widthHidden2 :: Int)
                        , show nParamsX, show totalParams
                        , show gamma, show range ]
  in testCase name $ do
    hPutStrLn stderr $ printf "\n%s: Epochs to run/max batches per epoch: %d/%d"
           prefix epochs maxBatches
    trainData <- loadMnistData trainGlyphsPath trainLabelsPath
    testData <- loadMnistData testGlyphsPath testLabelsPath
    let runBatch :: Domains Double
                 -> (Int, [MnistData Double])
                 -> IO (Domains Double)
        runBatch !domains0 (k, chunk) = do
          let f = trainWithLoss widthHidden widthHidden2
              res = fst $ sgd gamma f chunk domains0
              !trainScore = fcnnMnistTestS widthHidden widthHidden2
                                          chunk res
              !testScore = fcnnMnistTestS widthHidden widthHidden2
                                         testData res
              !lenChunk = length chunk
          hPutStrLn stderr $ printf "\n%s: (Batch %d with %d points)" prefix k lenChunk
          hPutStrLn stderr $ printf "%s: Training error:   %.2f%%" prefix ((1 - trainScore) * 100)
          hPutStrLn stderr $ printf "%s: Validation error: %.2f%%" prefix ((1 - testScore ) * 100)
          return res
    let runEpoch :: Int
                 -> Domains Double
                 -> IO (Domains Double)
        runEpoch n params2 | n > epochs = return params2
        runEpoch n params2 = do
          hPutStrLn stderr $ printf "\n%s: [Epoch %d]" prefix n
          let trainDataShuffled = shuffle (mkStdGen $ n + 5) trainData
              chunks = take maxBatches
                       $ zip [1 ..] $ chunksOf 5000 trainDataShuffled
          !res <- foldM runBatch params2 chunks
          runEpoch (succ n) res
    res <- runEpoch 1 parametersInit
    let testErrorFinal = 1 - fcnnMnistTestS widthHidden widthHidden2
                                            testData res
    testErrorFinal @?~ expected

dumbMnistTests :: TestTree
dumbMnistTests = testGroup "Dumb MNIST tests"
  [ testCase "1pretty-print in grey 3 2" $ do
      let (nParams0, lParams1, lParams2, _) = fcnnMnistLen2 4 3
          vParams1 = V.fromList lParams1
          vParams2 = V.fromList lParams2
          domains0 = V.replicate nParams0 (1 :: Float)
          domains1 = V.map (`V.replicate` 2) vParams1
          domains2 = V.map (LA.konst 3) vParams2
          domainsX = V.empty
          blackGlyph = V.replicate sizeMnistGlyphInt 4
          blackLabel = V.replicate sizeMnistLabelInt 5
          trainData = (blackGlyph, blackLabel)
          output = prettyPrintDf (fcnnMnistLoss2 trainData) Domains{..}
      -- printf "%s" output
      length output @?= 176576
  , testCase "2pretty-print in grey 3 2 fused" $ do
      let (nParams0, lParams1, lParams2, _) = fcnnMnistLen2 4 3
          vParams1 = V.fromList lParams1
          vParams2 = V.fromList lParams2
          domains0 = V.replicate nParams0 (1 :: Float)
          domains1 = V.map (`V.replicate` 2) vParams1
          domains2 = V.map (LA.konst 3) vParams2
          domainsX = V.empty
          blackGlyph = V.replicate sizeMnistGlyphInt 4
          blackLabel = V.replicate sizeMnistLabelInt 5
          trainData = (blackGlyph, blackLabel)
          output = prettyPrintDf (fcnnMnistLossFused2 trainData) Domains{..}
      --- printf "%s" output
      length output @?= 54268
  , testCase "3pretty-print on testset 3 2" $ do
      let (_, _, _, parameters0) = initializerFixed 44 0.5 (fcnnMnistLen2 4 3)
      testData <- loadMnistData testGlyphsPath testLabelsPath
      let trainDataItem = head testData
          output = prettyPrintDf (fcnnMnistLoss2 trainDataItem) parameters0
      -- printf "%s" output
      length output @?= 183127
  , testCase "fcnnMnistTest2LL on 0.1 params0 300 100 width 10k testset" $ do
      let (nParams0, lParams1, lParams2, _) = fcnnMnistLen2 300 100
          vParams1 = V.fromList lParams1
          vParams2 = V.fromList lParams2
          domains0 = V.replicate nParams0 (0.1 :: Float)
          domains1 = V.map (`V.replicate` 0.1) vParams1
          domains2 = V.map (LA.konst 0.1) vParams2
          domainsX = V.empty
      testData <- loadMnistData testGlyphsPath testLabelsPath
      (1 - fcnnMnistTest2 testData Domains{..})
        @?~ 0.902
  , testProperty "Compare two forward derivatives and gradient for Mnist1A" $
      \seed seedDs ->
      forAll (choose (1, 2000)) $ \widthHidden ->
      forAll (choose (1, 5000)) $ \widthHidden2 ->
      forAll (choose (0.01, 0.5)) $ \range ->  -- large nn, so NaNs fast
      forAll (choose (0.01, 10)) $ \rangeDs ->
        let createRandomVector n seedV = LA.randomVector seedV LA.Uniform n
            glyph = createRandomVector sizeMnistGlyphInt seed
            label = createRandomVector sizeMnistLabelInt seedDs
            mnistData :: MnistData Double
            mnistData = (glyph, label)
            paramShape = afcnnMnistLen1 widthHidden widthHidden2
            -- This is a very ugly and probably unavoidable boilerplate:
            -- we have to manually define a dummy value
            -- of type ADFcnnMnist1Parameters
            -- with the correct list lengths (vector lengths can be fake)
            -- to bootstrap the adaptor machinery. Such boilerplate can be
            -- avoided only with shapely typed tensors and scalars or when
            -- not using adaptors.
            valsInit = ( (replicate widthHidden V.empty, V.empty)
                       , (replicate widthHidden2 V.empty, V.empty)
                       , (replicate sizeMnistLabelInt V.empty, V.empty) )
            (_, _, _, parameters) = initializerFixed seed range paramShape
            (_, _, _, ds) = initializerFixed seedDs rangeDs paramShape
            (_, _, _, parametersPerturbation) =
              initializerFixed (seed + seedDs) 1e-7 paramShape
            f :: forall d r. (ADModeAndNum d r, r ~ Double)
              => ADInputs d r -> ADVal d r
            f adinputs =
              afcnnMnistLoss1 widthHidden widthHidden2 mnistData
                              (parseADInputs valsInit adinputs)
        in qcPropDom f parameters ds parametersPerturbation 1
  , testProperty "Compare two forward derivatives and gradient for Mnist2" $
      \seed ->
      forAll (choose (0, sizeMnistLabelInt - 1)) $ \seedDs ->
      forAll (choose (1, 5000)) $ \widthHidden ->
      forAll (choose (1, 1000)) $ \widthHidden2 ->
      forAll (choose (0.01, 1)) $ \range ->
      forAll (choose (0.01, 10)) $ \rangeDs ->
        let createRandomVector n seedV = LA.randomVector seedV LA.Uniform n
            glyph = createRandomVector sizeMnistGlyphInt seed
            label = createRandomVector sizeMnistLabelInt seedDs
            labelOneHot = LA.konst 0 sizeMnistLabelInt V.// [(seedDs, 1)]
            mnistData, mnistDataOneHot :: MnistData Double
            mnistData = (glyph, label)
            mnistDataOneHot = (glyph, labelOneHot)
            paramShape = fcnnMnistLen2 widthHidden widthHidden2
            (_, _, _, parameters) = initializerFixed seed range paramShape
            (_, _, _, ds) = initializerFixed seedDs rangeDs paramShape
            (_, _, _, parametersPerturbation) =
              initializerFixed (seed + seedDs) 1e-7 paramShape
            f, fOneHot, fFused
              :: forall d r. (ADModeAndNum d r, r ~ Double)
                 => ADInputs d r -> ADVal d r
            f = fcnnMnistLoss2 mnistData
            fOneHot = fcnnMnistLoss2 mnistDataOneHot
            fFused = fcnnMnistLossFused2 mnistDataOneHot
        in qcPropDom f parameters ds parametersPerturbation 1
           .&&. qcPropDom fOneHot parameters ds parametersPerturbation 1
           .&&. qcPropDom fFused parameters ds parametersPerturbation 1
           .&&. cmpTwoSimple fOneHot fFused parameters ds
  ]

vectorMnistTests :: TestTree
vectorMnistTests = testGroup "MNIST VV tests with a 2-hidden-layer nn"
  [ mnistTestCase2VA "VA 1 epoch, 1 batch, wider" 1 1
                     afcnnMnistLoss1 500 150 0.02
                     0.13959999999999995
  , mnistTestCase2VA "VA 2 epochs, but only 1 batch" 2 1
                     afcnnMnistLoss1 300 100 0.02
                     0.10019999999999996
  , mnistTestCase2VA "VA 1 epoch, all batches" 1 99
                     afcnnMnistLoss1 300 100 0.02
                     5.389999999999995e-2
  ]

matrixMnistTests :: TestTree
matrixMnistTests = testGroup "MNIST LL tests with a 2-hidden-layer nn"
  [ mnistTestCase2L "1 epoch, 1 batch, wider" 1 1 fcnnMnistLoss2 500 150 0.02
                    0.15039999999999998
  , mnistTestCase2L "2 epochs, but only 1 batch" 2 1 fcnnMnistLoss2 300 100 0.02
                    8.879999999999999e-2
  , mnistTestCase2L "1 epoch, all batches" 1 99 fcnnMnistLoss2 300 100 0.02
                    5.1100000000000034e-2
  , mnistTestCase2F False 1 False
                    "artificial FL 5 4 3 2 1" 5 4 fcnnMnistLoss2 3 2 1
                    0.8991
--  , mnistTestCase2T True False
--                    "2 epochs, all batches, TL, wider, to file"
--                    2 60000 fcnnMnistLoss2 500 150 0.02
--                    4.290000000000005e-2
--  , mnistTestCase2D True 1 False
--                    "2 epochs, all batches, DL, wider, to file"
--                    2 60000 fcnnMnistLoss2 500 150 0.02
--                    0.9079
--  , mnistTestCase2D True 64 False
--                    "2 epochs, all batches, DL, wider, to file"
--                    2 60000 fcnnMnistLoss2 500 150 0.02
--                    0.9261
--  , mnistTestCase2D True 64 True
--                    "2 epochs, all batches, DL, wider, to file"
--                    2 60000 fcnnMnistLoss2 500 150 0.02
--                    0.8993
--  , mnistTestCase2D True 64 True
--                    "2 epochs, all batches, DL, wider, to file"
--                    2 60000 fcnnMnistLoss2 500 150 2e-5
--                    0.9423
--  , mnistTestCase2D True 64 True
--                    "2 epochs, all batches, DL, wider, to file"
--                    2 60000 fcnnMnistLoss2 500 150 2e-4
--                    0.8714
--  , mnistTestCase2F True 64 True
--                    "2 epochs, all batches, FL, wider, to file"
--                    2 60000 fcnnMnistLoss2 500 150 2e-4
--                    0.8714
--  , mnistTestCase2D True 64 True
--                    "2 epochs, all batches, DL, wider, to file"
--                    2 60000 fcnnMnistLossFusedRelu2 1024 1024 2e-4
--                    0.902
--  , mnistTestCase2D False 64 True
--                    "2 epochs, all batches, 1024DL"
--                    2 60000 fcnnMnistLoss2 1024 1024 2e-4
--                    0.7465999999999999
--  , mnistTestCase2F False 64 True
--                    "2 epochs, all batches, 1024FL"
--                    2 60000 fcnnMnistLoss2 1024 1024 2e-4
--                    0.7465999999999999
  ]

longMnistTests :: TestTree
longMnistTests = testGroup "MNIST fused LL tests with a 2-hidden-layer nn"
  [ mnistTestCase2L "F 1 epoch, 1 batch, wider" 1 1
                    fcnnMnistLossFused2 500 150 0.02
                    0.15039999999999998
  , mnistTestCase2L "F 2 epochs, but only 1 batch" 2 1
                    fcnnMnistLossFused2 300 100 0.02
                    8.879999999999999e-2
  , mnistTestCase2L "F 1 epoch, all batches" 1 99
                    fcnnMnistLossFused2 300 100 0.02
                    5.1100000000000034e-2
  , mnistTestCase2S (MkSN @500) (MkSN @150)
                    "S 1 epoch, 1 batch, wider" 1 1 afcnnMnistLossFusedS 0.02
                    0.13829999999999998
  , mnistTestCase2S (MkSN @300) (MkSN @100)
                    "S 2 epochs, but only 1 batch" 2 1 afcnnMnistLossFusedS 0.02
                    9.519999999999995e-2
  , mnistTestCase2S (MkSN @300) (MkSN @100)
                    "S 1 epoch, all batches" 1 99 afcnnMnistLossFusedS 0.02
                    5.359999999999998e-2
  , mnistTestCase2S (MkSN @300) (MkSN @100)
                    "SR 1 epoch, 1 batch" 1 1 afcnnMnistLossFusedReluS 0.02
                    0.7862
  , mnistTestCase2S (MkSN @500) (MkSN @150)
                    "SR 1 epoch, 1 batch, wider" 1 1
                    afcnnMnistLossFusedReluS 0.02
                    0.8513
  , mnistTestCase2S (MkSN @300) (MkSN @100)
                    "SR 2 epochs, but 1 batch" 2 1 afcnnMnistLossFusedReluS 0.02
                    0.7442
  , mnistTestCase2S (MkSN @300) (MkSN @100)
                    "SR 1 epoch, all batches" 1 99 afcnnMnistLossFusedReluS 0.02
                    0.5462
  , mnistTestCase2O (MkSN @500) (MkSN @150)
                    "O 1 epoch, 1 batch, wider" 1 1 fcnnMnistLossFusedS 0.02
                    0.12470000000000003
  , mnistTestCase2O (MkSN @300) (MkSN @100)
                    "O 2 epochs, but only 1 batch" 2 1 fcnnMnistLossFusedS 0.02
                    9.630000000000005e-2
  , mnistTestCase2O (MkSN @300) (MkSN @100)
                    "O 1 epoch, all batches" 1 99 fcnnMnistLossFusedS 0.02
                    5.620000000000003e-2
  , mnistTestCase2O (MkSN @300) (MkSN @100)
                    "OR 1 epoch, 1 batch" 1 1 fcnnMnistLossFusedReluS 0.02
                    0.7068
  , mnistTestCase2O (MkSN @500) (MkSN @150)
                    "OR 1 epoch, 1 batch, wider" 1 1
                    fcnnMnistLossFusedReluS 0.02
                    0.8874
  , mnistTestCase2O (MkSN @300) (MkSN @100)
                    "OR 2 epochs, but 1 batch" 2 1 fcnnMnistLossFusedReluS 0.02
                    0.8352999999999999
  , mnistTestCase2O (MkSN @300) (MkSN @100)
                    "OR 1 epoch, all batches" 1 99 fcnnMnistLossFusedReluS 0.02
                    0.6415
  ]

shortCIMnistTests :: TestTree
shortCIMnistTests = testGroup "Short CI MNIST tests"
  [ mnistTestCase2VA "VA 1 epoch, 1 batch" 1 1 afcnnMnistLoss1 300 100 0.02
                     0.12960000000000005
  , mnistTestCase2VA "VA artificial 1 2 3 4 5" 1 2 afcnnMnistLoss1 3 4 5
                     0.8972
  , mnistTestCase2VA "VA artificial 5 4 3 2 1" 5 4 afcnnMnistLoss1 3 2 1
                     0.6585
  , mnistTestCase2L "LL 1 epoch, 1 batch" 1 1 fcnnMnistLoss2 300 100 0.02
                    0.12339999999999995
  , mnistTestCase2L "LL artificial 1 2 3 4 5" 1 2 fcnnMnistLoss2 3 4 5
                    0.8972
  , mnistTestCase2L "LL artificial 5 4 3 2 1" 5 4 fcnnMnistLoss2 3 2 1
                    0.8085
  , mnistTestCase2L "fused LL 1/1 batch" 1 1 fcnnMnistLossFused2 300 100 0.02
                    0.12339999999999995
  , mnistTestCase2L "fused LL artificial 1 2 3 4 5" 1 2
                    fcnnMnistLossFused2 3 4 5
                    0.8972
  , mnistTestCase2T False
                    "fused TL artificial 5 4 3 2 1" 5 4
                    fcnnMnistLossFused2 3 2 1
                    0.8865
  , mnistTestCase2D False 1 False
                    "fused DL artificial 5 4 3 2 1" 5 4
                    fcnnMnistLossFused2 3 2 1
                    0.8991
  , mnistTestCase2S (MkSN @3) (MkSN @2)
                    "SR artificial 5 4 3 2 1" 5 4 afcnnMnistLossFusedReluS 1
                    0.8972
  , mnistTestCase2S (MkSN @300) (MkSN @100)
                    "S 1 epoch, 1 batch" 1 1 afcnnMnistLossFusedS 0.02
                    0.137
  , mnistTestCase2S (MkSN @3) (MkSN @4)
                    "S artificial 1 2 3 4 5" 1 2 afcnnMnistLossFusedS 5
                    0.8972
  , mnistTestCase2S (MkSN @3) (MkSN @2)
                    "S artificial 5 4 3 2 1" 5 4 afcnnMnistLossFusedS 1
                    0.8093
  , mnistTestCase2S (MkSN @3) (MkSN @4)
                    "SR artificial 1 2 3 4 5" 1 2 afcnnMnistLossFusedReluS 5
                    0.8972
  , mnistTestCase2O (MkSN @3) (MkSN @2)
                    "OR artificial 5 4 3 2 1" 5 4 fcnnMnistLossFusedReluS 1
                    0.8991
  , mnistTestCase2O (MkSN @300) (MkSN @100)
                    "O 1 epoch, 1 batch" 1 1 fcnnMnistLossFusedS 0.02
                    0.1311
  , mnistTestCase2O (MkSN @3) (MkSN @4)
                    "O artificial 1 2 3 4 5" 1 2 fcnnMnistLossFusedS 5
                    0.8972
  , mnistTestCase2O (MkSN @3) (MkSN @2)
                    "O artificial 5 4 3 2 1" 5 4 fcnnMnistLossFusedS 1
                    0.8246
  , mnistTestCase2O (MkSN @3) (MkSN @4)
                    "OR artificial 1 2 3 4 5" 1 2 fcnnMnistLossFusedReluS 5
                    0.8972
  ]
