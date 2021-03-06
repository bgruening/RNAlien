{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}

-- | Unsupervized construction of RNA family models
--   For more information on RNA family models consult <http://>
--   Usage example: RNAlien -i /path/input.fa -c 5 -o /outdir/
--   Usage example offline mode: RNAlien -i /path/input.fa -b /backup/blast/nt_v5 -o /outdir/ -c 5 -t 1396 -j
module Main where

import System.Console.CmdArgs
import System.Directory
import Biobase.RNAlien.Types
import Biobase.RNAlien.Library
import Data.Maybe
import Data.Either.Unwrap
import Data.Time
import qualified System.FilePath as FP
import Paths_RNAlien (version)
import Data.Version (showVersion)
import qualified Biobase.StockholmAlignment.Import as BS
import qualified Control.Exception.Base as CE
import Control.Monad

data Options = Options
  { inputFastaFilePath :: String,
    inputAlignmentFilePath :: String,
    outputPath :: String,
    inputTaxId :: Maybe Int,
    inputnSCICutoff :: Maybe Double,
    inputEvalueCutoff :: Maybe Double,
    inputBlastDatabase :: Maybe String,
    lengthFilter :: Bool,
    coverageFilter :: Bool,
    singleHitperTax :: Bool,
    blastSoftmasking :: Bool,
    inputQuerySelectionMethod :: String,
    inputQueryNumber :: Int,
    threads :: Int,
    taxonomyRestriction :: Maybe String,
    sessionIdentificator :: Maybe String,
    performEvaluation :: Bool,
    checkSetup :: Bool,
    taxonomyDumpPath :: String,
    offlineMode :: Bool
  } deriving (Show,Data,Typeable)

options :: Options
options = Options
  { inputFastaFilePath = def &= name "i" &= help "Path to input fasta file",
    inputAlignmentFilePath = def &= name "p" &= help "Path to input alignment file",
    outputPath = def &= name "o" &= help "Path to output directory. Default: current working directory",
    inputTaxId = Nothing &= name "t" &= help "NCBI taxonomy ID number of input RNA organism",
    inputnSCICutoff = Just (1 :: Double) &= name "z" &= help "Only candidate sequences with a normalized structure conservation index (nSCI) higher than this value are accepted. Default: 1",
    inputEvalueCutoff = Just (0.001 :: Double) &= name "e" &= help "Evalue cutoff for cmsearch filtering. Default: 0.001",
    inputBlastDatabase = Just "nt" &= name "b" &= help "Specify name of blast database to use, in offline mode the filepath to the blast database (/home/user/nt_v5). Default: nt",
    lengthFilter = True &= name "l" &= help "Filter blast hits per genomic length. Default: True",
    coverageFilter = True &= name "a" &= help "Filter blast hits by coverage of at least 80%. Default: True",
    singleHitperTax = False &= name "s" &= help "Only the best blast hit per taxonomic entry is considered. Default: False",
    blastSoftmasking = False &= name "f" &= help "Toggles blast query softmasking, meaning masking of non-conserved regions on the query. Default: False",
    inputQuerySelectionMethod = "filtering" &= name "m" &= help "Method for selection of queries (filtering,clustering). Default: filtering",
    inputQueryNumber = (5 :: Int) &= name "n" &= help "Number of queries used for candidate search. Default: 5",
    threads = 1 &= name "c" &= help "Number of available cpu slots/cores. Default: 1",
    taxonomyRestriction = Nothing &= name "r" &= help "Restrict search space to taxonomic kingdom (bacteria,archea,eukaryia,cellularorganisms,viruses). Default: not set",
    sessionIdentificator = Nothing &= name "d" &= help "Optional session id that is used instead of automatically generated one.",
    performEvaluation = True &= name "x" &= help "Perform evaluation step. Default: True",
    checkSetup = False &= name "g" &= help "Just prints installed tool versions and performs connection check. Default: False",
    taxonomyDumpPath = def &= name "w" &= help "Path to NCBI taxonomy dump directory.",
    offlineMode = False &= name "j" &= help "Uses locally installed blast and databases. Default: False"
  } &= summary ("RNAlien " ++ alienVersion) &= help "Florian Eggenhofer, Ivo L. Hofacker, Christian Hoener zu Siederdissen - 2013 - 2020" &= verbosity

main :: IO ()
main = do
  Options{..} <- cmdArgs options
  verboseLevel <- getVerbosity
  --let tools = if inputQuerySelectionMethod == "clustering" then ["clustalo","mlocarna","RNAfold","RNAalifold","cmcalibrate","cmstat","cmbuild","RNAz","RNAcode"] else ["mlocarna","RNAfold","RNAalifold","cmcalibrate","cmstat","cmbuild","RNAz","RNAcode"]
  -- Generate SessionID
  sessionId <- createSessionID sessionIdentificator
  timestamp <- getCurrentTime
  currentWorkDirectory <- getCurrentDirectory
  let selectedOutputPath = if null outputPath then currentWorkDirectory else outputPath
  let temporaryDirectoryPath = FP.addTrailingPathSeparator selectedOutputPath ++ sessionId ++ "/"
  createDirectoryIfMissing False temporaryDirectoryPath
  setupCheckAlienWithLog inputQuerySelectionMethod temporaryDirectoryPath
  createDirectoryIfMissing False (temporaryDirectoryPath ++ "log")
  -- Create Log files
  writeFile (temporaryDirectoryPath ++ "Log") ("RNAlien " ++ alienVersion ++ "\n")
  writeFile (temporaryDirectoryPath ++ "log/warnings") ("")
  logMessage ("Timestamp: " ++ (show timestamp) ++ "\n") temporaryDirectoryPath
  logMessage ("Temporary Directory: " ++ temporaryDirectoryPath ++ "\n") temporaryDirectoryPath
  let iterationNumber = 0
  singleFasta <- isSingleFasta inputFastaFilePath
  if singleFasta
    then do
      fastaInput <- readFastaFile inputFastaFilePath
      when (null fastaInput) (error "Please provide input fasta sequences with the cmd line parameter -i")
      logToolVersions inputQuerySelectionMethod temporaryDirectoryPath
      let reformatedFastaInput = map reformatFasta fastaInput
      let inputSequence = head reformatedFastaInput
      initialTaxId <- setInitialTaxId offlineMode threads inputBlastDatabase temporaryDirectoryPath inputTaxId inputSequence
      let checkedTaxonomyRestriction = checkTaxonomyRestriction taxonomyRestriction
      let staticOptions = StaticOptions temporaryDirectoryPath sessionId (fromJust inputnSCICutoff) inputTaxId singleHitperTax inputQuerySelectionMethod inputQueryNumber lengthFilter coverageFilter blastSoftmasking threads inputBlastDatabase checkedTaxonomyRestriction (setVerbose verboseLevel) offlineMode [] taxonomyDumpPath
      when (setVerbose verboseLevel) (print staticOptions)
      let initialization = ModelConstruction iterationNumber reformatedFastaInput [] [] initialTaxId Nothing (fromJust inputEvalueCutoff) False [] [] [] Nothing
      logMessage (show initialization) temporaryDirectoryPath
      modelConstructionResults <- modelConstructer staticOptions initialization
      let resultTaxonomyRecordsCSVTable = constructTaxonomyRecordsCSVTable modelConstructionResults
      writeFile (temporaryDirectoryPath ++ "result.csv") resultTaxonomyRecordsCSVTable
      if performEvaluation
        then do
          resultEvaluation <- evaluateConstructionResult staticOptions modelConstructionResults
          appendFile (temporaryDirectoryPath ++ "Log") resultEvaluation
          resultSummary modelConstructionResults staticOptions
          writeFile (temporaryDirectoryPath ++ "done") ""
        else do
          resultSummary modelConstructionResults staticOptions
          writeFile (temporaryDirectoryPath ++ "done") ""
    else do
      --multi fasta or aln input
      alignmentFilePath <- if not (null inputFastaFilePath)
                           then do
                             let mlocarnaFilePath = temporaryDirectoryPath ++ "input.mlocarna"
                             let mlocarnaDirPath = temporaryDirectoryPath ++ "inputMLocarna"
                             let mlocarnaStkPath = mlocarnaDirPath ++ "/results/result.stk"
                             let alifoldPath = temporaryDirectoryPath ++ "input.alifold"
                             let stockholmPath = temporaryDirectoryPath ++ "input.stockholm"                      
                             alignSequences "mlocarna" ("--stockholm --consensus-structure alifold --tgtdir=" ++ mlocarnaDirPath ++ " --threads=" ++ show threads ++ " ") [inputFastaFilePath] [] [mlocarnaFilePath] []
                             _ <- systemRNAalifold "-r --cfactor 0.6 --nfactor 0.5" mlocarnaStkPath alifoldPath
                             _ <- replaceStockholmStructure mlocarnaStkPath alifoldPath stockholmPath
                             return stockholmPath
                           else return inputAlignmentFilePath
      alignmentInput <- BS.readExistingStockholm alignmentFilePath
      logToolVersions inputQuerySelectionMethod temporaryDirectoryPath
      when (isLeft alignmentInput) (error (fromLeft alignmentInput))
      let rightAlignment = head $ fromRight alignmentInput
      let reformatedFastaInput = stockholmAlignmentToFasta rightAlignment
      when (null reformatedFastaInput) (error "Please provide input fasta sequences with the cmd line parameter -i")
      let inputSequence = head reformatedFastaInput
      initialTaxId <- setInitialTaxId offlineMode threads inputBlastDatabase temporaryDirectoryPath inputTaxId inputSequence
      let checkedTaxonomyRestriction = checkTaxonomyRestriction taxonomyRestriction
      let staticOptions = StaticOptions temporaryDirectoryPath sessionId (fromJust inputnSCICutoff) inputTaxId singleHitperTax inputQuerySelectionMethod inputQueryNumber lengthFilter coverageFilter blastSoftmasking threads inputBlastDatabase checkedTaxonomyRestriction (setVerbose verboseLevel) offlineMode [] taxonomyDumpPath
      let initialization = ModelConstruction iterationNumber reformatedFastaInput [] [] initialTaxId Nothing (fromJust inputEvalueCutoff) False [] [] [] (Just rightAlignment)
      --let (upperTaxLimit,lowerTaxLimit) = setTaxonomicContextEntrez iterationNumber (taxonomicContext initialization) (upperTaxonomyLimit initialization)
      currentTaxonomicContext <- CE.catch (getTaxonomicContext (offline staticOptions) (ncbiTaxonomyDumpPath staticOptions) initialTaxId (taxonomicContext initialization))
             (\e -> do let err = show (e :: CE.IOException)
                       logWarning ("Warning: Retrieving taxonomic context failed:" ++ " " ++ err) (tempDirPath staticOptions)
                       return Nothing)
      let nextModelConstructionInput = constructNext iterationNumber initialization [] [] initialTaxId currentTaxonomicContext [] [] True
      --           let nextModelConstructionInput = constructNext currentIterationNumber modelConstruction alignmentResults similarMembers currentUpperTaxonomyLimit currentTaxonomicContext [] currentPotentialMembers True
      --constructModel nextModelConstructionInput staticOptions
      let outputDirectory = tempDirPath staticOptions ++ "0" ++ "/"
      createDirectory outputDirectory
      let fastaFilePath = outputDirectory ++ "model.fa"
      let stockholmFilepath = outputDirectory ++ "model" ++ ".stockholm"
      let cmFilepath = outputDirectory ++ "model" ++ ".cm"
      let cmCalibrateFilepath = outputDirectory ++ "model" ++ ".cmcalibrate"
      let cmBuildFilepath = outputDirectory ++ "model" ++ ".cmbuild"
      copyFile alignmentFilePath stockholmFilepath
      writeFastaFile fastaFilePath reformatedFastaInput
      let refinedAlignmentFilepath = outputDirectory ++ "modelrefined.stockholm"
      let cmBuildOptions ="--refine " ++ refinedAlignmentFilepath
      _ <- systemCMbuild cmBuildOptions stockholmFilepath cmFilepath cmBuildFilepath
      _ <- systemCMcalibrate "fast" (cpuThreads staticOptions) cmFilepath cmCalibrateFilepath
      writeFile (outputDirectory ++ "done") ""
      --select queries
      print "here1"
      let logDirectory = outputDirectory ++ "log"
      createDirectory logDirectory
      currentSelectedQueries <- selectQueries staticOptions initialization []
      --currentSelectedQueries <- selectQueries staticOptions initialization []
      let nextScanModelConstructionInputWithQueries = nextModelConstructionInput {selectedQueries = currentSelectedQueries}
      print "here 2"
      logMessage (iterationSummaryLog nextScanModelConstructionInputWithQueries) (tempDirPath staticOptions)
      modelConstructionResults <- modelConstructer staticOptions nextModelConstructionInput
      print "here 3"  
      let resultTaxonomyRecordsCSVTable = constructTaxonomyRecordsCSVTable modelConstructionResults
      writeFile (temporaryDirectoryPath ++ "result.csv") resultTaxonomyRecordsCSVTable
      if performEvaluation
        then do
          resultEvaluation <- evaluateConstructionResult staticOptions modelConstructionResults
          appendFile (temporaryDirectoryPath ++ "Log") resultEvaluation
          resultSummary modelConstructionResults staticOptions
          writeFile (temporaryDirectoryPath ++ "done") ""
        else do
          resultSummary modelConstructionResults staticOptions
          writeFile (temporaryDirectoryPath ++ "done") ""

isSingleFasta :: String -> IO Bool
isSingleFasta inputFastaFilePath = do
  if null inputFastaFilePath
    then return False
    else do
      fastaInput <- readFastaFile inputFastaFilePath
      when (null fastaInput) (error "Please provide input fasta sequences with the cmd line parameter -i")
      if (length fastaInput == (1 :: Int)) then return True else return False
                    
alienVersion :: String
alienVersion = showVersion version
