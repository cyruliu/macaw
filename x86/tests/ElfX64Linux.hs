{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DataKinds #-}
module ElfX64Linux (
  elfX64LinuxTests
  ) where

import           Control.Arrow ( first )
import Control.Lens ( (^.) )
import           Control.Monad ( unless )
import qualified Control.Monad.Catch as C
import qualified Data.ByteString as B
import qualified Data.Foldable as F
import qualified Data.Map as M
import Data.Maybe (fromJust)
import qualified Data.Set as S
import Data.Typeable ( Typeable )
import Data.Word ( Word64 )
import System.FilePath ( dropExtension, replaceExtension )
import qualified Test.Tasty as T
import qualified Test.Tasty.HUnit as T
import Text.Printf ( printf )
import Text.Read ( readMaybe )

import qualified Data.ElfEdit as E

import qualified Data.Parameterized.Some as PU
import qualified Data.Macaw.Memory as MM
import qualified Data.Macaw.Memory.ElfLoader as MM
import qualified Data.Macaw.Discovery as MD
import qualified Data.Macaw.X86 as RO

-- | This is an offset we use to change the load address of the text section of
-- the binary.
--
-- The current binaries are position independent.  This means that the load
-- address is around 0x100.  The problem is that there are constant offsets from
-- the stack that are in this range; the abstract interpretation in AbsState.hs
-- then interprets stack offsets as code pointers (since small integer values
-- look like code pointers when the code is mapped at these low addresses).
-- This throws off the abstract interpretation by hitting a "stack offset + code
-- pointer" case, which resolves to Top.
--
-- This offset forces macaw to load the binary at a higher address where this
-- accidental overlap is less likely.  We still need a more principled solution
-- to this problem.
loadOffset :: Word64
loadOffset = 0x400000

elfX64LinuxTests :: [FilePath] -> T.TestTree
elfX64LinuxTests = T.testGroup "ELF x64 Linux" . map mkTest

-- | The type of expected results for test cases
data ExpectedResult =
  R { funcs :: [(Word64, [(Word64, Integer)])]
    -- ^ The first element of the pair is the address of entry point
    -- of the function.  The list is a list of the addresses of the
    -- basic blocks in the function (including the first block).
    , ignoreBlocks :: [Word64]
    -- ^ This is a list of discovered blocks to ignore.  This is
    -- basically just the address of the instruction after the exit
    -- syscall, as macaw doesn't know that exit never returns and
    -- discovers a false block after exit.
    }
  deriving (Read, Show, Eq)

mkTest :: FilePath -> T.TestTree
mkTest fp = T.testCase fp $ withELF exeFilename (testDiscovery fp)
  where
    asmFilename = dropExtension fp
    exeFilename = replaceExtension asmFilename "exe"

-- | Run a test over a given expected result filename and the ELF file
-- associated with it
testDiscovery :: FilePath -> E.Elf 64 -> IO ()
testDiscovery expectedFilename elf =
  withMemory MM.Addr64 elf $ \mem -> do
    let Just entryPoint = MM.asSegmentOff mem (MM.absoluteAddr (MM.memWord (E.elfEntry elf + loadOffset)))
        di = MD.cfgFromAddrs RO.x86_64_linux_info mem M.empty [entryPoint] []
    expectedString <- readFile expectedFilename
    case readMaybe expectedString of
      Nothing -> T.assertFailure ("Invalid expected result: " ++ show expectedString)
      Just er -> do
        let fixBlockStart bs = bs + fromIntegral loadOffset
        let expectedEntries = M.fromList [ (fixBlockStart entry, S.fromList (fmap (first fixBlockStart) starts))
                                         | (entry, starts) <- funcs er
                                         ]
            ignoredBlocks = S.fromList (fmap fixBlockStart (ignoreBlocks er))
            absoluteFromSegOff = fromIntegral . fromJust . MM.asAbsoluteAddr . MM.relativeSegmentAddr
        T.assertEqual "Collection of discovered function starting points"
          (M.keysSet expectedEntries `S.difference` ignoredBlocks)
          (S.map absoluteFromSegOff (M.keysSet (di ^. MD.funInfo)))
        F.forM_ (M.elems (di ^. MD.funInfo)) $ \(PU.Some dfi) -> do
          F.forM_ (M.elems (dfi ^. MD.parsedBlocks)) $ \pb -> do
            let addr = absoluteFromSegOff (MD.pblockAddr pb)
            unless (S.member addr ignoredBlocks) $ do
              let term = blockTerminator pb
              T.assertBool ("Unclassified block at " ++ show (MD.pblockAddr pb)) (not (isClassifyFailure term))
              T.assertBool ("Translate error at " ++ show (MD.pblockAddr pb)) (not (isTranslateError term))
          let actualEntry = absoluteFromSegOff (MD.discoveredFunAddr dfi)
              -- actualEntry = fromIntegral (MM.addrValue (MD.discoveredFunAddr dfi))
              actualBlockStarts = S.fromList [ (addr, toInteger (MD.blockSize pbr))
                                             | pbr <- M.elems (dfi ^. MD.parsedBlocks)
                                             , let addr = absoluteFromSegOff (MD.pblockAddr pbr)
                                             , addr `S.notMember` ignoredBlocks
                                             ]
          case (S.member actualEntry ignoredBlocks, M.lookup actualEntry expectedEntries) of
            (True, _) -> return ()
            (_, Nothing) -> T.assertFailure (printf "Unexpected entry point: 0x%x" actualEntry)
            (_, Just expectedBlockStarts) ->
              T.assertEqual (printf "Block starts for 0x%x" actualEntry) expectedBlockStarts actualBlockStarts

withELF :: FilePath -> (E.Elf 64 -> IO ()) -> IO ()
withELF fp k = do
  bytes <- B.readFile fp
  case E.parseElf bytes of
    E.ElfHeaderError off msg ->
      error ("Error parsing ELF header at offset " ++ show off ++ ": " ++ msg)
    E.Elf32Res [] _e32 -> error "ELF32 is unsupported in the test suite"
    E.Elf64Res [] e64 -> k e64
    E.Elf32Res errs _ -> error ("Errors while parsing ELF file: " ++ show errs)
    E.Elf64Res errs _ -> error ("Errors while parsing ELF file: " ++ show errs)

withMemory :: forall w m a
            . (C.MonadThrow m, MM.MemWidth w, Integral (E.ElfWordType w))
           => MM.AddrWidthRepr w
           -> E.Elf w
           -> (MM.Memory w -> m a)
           -> m a
withMemory _relaWidth e k = do
  let opt = MM.LoadOptions { MM.loadRegionIndex = Just 0
                           , MM.loadRegionBaseOffset = fromIntegral loadOffset
                           , MM.loadStyleOverride = Just MM.LoadBySegment
                           , MM.includeBSS = False
                           }
  case MM.memoryForElf opt e of
    Left err -> C.throwM (MemoryLoadError err)
    Right (_sim, mem) -> k mem

data ElfException = MemoryLoadError String
  deriving (Typeable, Show)

instance C.Exception ElfException

blockTerminator :: MD.ParsedBlock arch ids -> MD.ParsedTermStmt arch ids
blockTerminator = MD.stmtsTerm . MD.blockStatementList

isClassifyFailure :: MD.ParsedTermStmt arch ids -> Bool
isClassifyFailure ts =
  case ts of
    MD.ClassifyFailure {} -> True
    _ -> False

isTranslateError :: MD.ParsedTermStmt arch ids -> Bool
isTranslateError ts =
  case ts of
    MD.ParsedTranslateError {} -> True
    _ -> False

