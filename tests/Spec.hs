module Main (main) where

import CoreSpec
  ( testRec1OrchestratorGuardrails
  , testVaultAndChunker
  )
import PredictionsAndMemorySpec
  ( testRec4PredictionSubClausesAndScreening
  , testRec5ArcRollupsFinalMysteriesAndHallOfFame
  , testRec6LeadingEmphasisAndMarkdownFormatting
  )
import System.Environment (getArgs)
import VerificationSpec
  ( testRec2SandboxToolTelemetry
  , testRec3CallbackAndFactCheckAudits
  )

main :: IO ()
main = do
  args <- getArgs
  let mBin = case args of (b : _) -> Just b; [] -> Nothing
  testVaultAndChunker
  testRec1OrchestratorGuardrails mBin
  testRec2SandboxToolTelemetry
  testRec3CallbackAndFactCheckAudits
  testRec4PredictionSubClausesAndScreening
  testRec5ArcRollupsFinalMysteriesAndHallOfFame
  testRec6LeadingEmphasisAndMarkdownFormatting
  putStrLn "\nAll lets-read gatekeeper tests passed!"
