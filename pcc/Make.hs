-----------------------------------------------------------------------------
--
-- Module      :  Make
-- Copyright   :  (c) 2013-14 Phil Freeman, (c) 2014 Gary Burgess, and other contributors
-- License     :  MIT
--
-- Maintainer  :  Andy Arvanitis
-- Stability   :  experimental
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TemplateHaskell #-}

module Make
  ( Make(..)
  , runMake
  , buildMakeActions
  , CPP.OtherOptions(..)
  ) where

import Control.Monad
import Control.Monad.Reader

import Data.FileEmbed (embedFile)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock
import Data.Version (showVersion)
import qualified Data.Map as M
import qualified Data.ByteString.Lazy as B

import System.Directory (copyFile, doesDirectoryExist, doesFileExist, getModificationTime, createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory, addExtension, dropExtension)
import System.IO.Error (tryIOError)

import Language.PureScript.Errors
import Language.PureScript (Make, makeIO, readTextFile, runMake)

import qualified Language.PureScript as P
import qualified Language.PureScript.CodeGen.Cpp as CPP
import qualified Language.PureScript.CoreFn as CF
import qualified Paths_purescript as Paths

runModuleName' :: P.ModuleName -> String
runModuleName' = T.unpack . P.runModuleName

buildMakeActions :: FilePath
                 -> M.Map P.ModuleName (Either P.RebuildPolicy FilePath)
                 -> Bool
                 -> CPP.OtherOptions
                 -> P.MakeActions Make
buildMakeActions outputDir filePathMap usePrefix otherOpts =
  P.MakeActions getInputTimestamp getOutputTimestamp readExterns codegen progress
  where

  getInputFile :: P.ModuleName -> FilePath
  getInputFile mn =
    let path = fromMaybe (error "Module has no filename in 'make'") $ M.lookup mn filePathMap in
    case path of
      Right path' -> path'
      Left _ -> error  "Module has no filename in 'make'"

  getInputTimestamp :: P.ModuleName -> Make (Either P.RebuildPolicy (Maybe UTCTime))
  getInputTimestamp mn = do
    let path = fromMaybe (error "Module has no filename in 'make'") $ M.lookup mn filePathMap
    let filePath = either (const []) takeDirectory path
        fileBase = filePath </> (last . words . dotsTo ' ' $ runModuleName' mn)
        ffis = addExtension fileBase <$> [sourceExt, headerExt] ++ otherExts
    e1 <- traverse getTimestamp path
    ffimax <- foldl1 max <$> mapM getTimestamp ffis
    return $ max ffimax <$> e1

  getOutputTimestamp :: P.ModuleName -> Make (Maybe UTCTime)
  getOutputTimestamp mn = do
    let filePath = runModuleName' mn
        fileBase = outputDir </> filePath </> (last . words . dotsTo ' ' $ runModuleName' mn)
        sourceFile = addExtension fileBase sourceExt
        headerFile = addExtension fileBase headerExt
        externsFile = outputDir </> filePath </> "externs.json"
    foldl min <$> getTimestamp externsFile <*> mapM getTimestamp [sourceFile, headerFile]

  readExterns :: P.ModuleName -> Make (FilePath, P.Externs)
  readExterns mn = do
    let path = outputDir </> (runModuleName' mn) </> "externs.json"
    (path, ) <$> readTextFile path

  codegen :: CF.Module CF.Ann -> P.Environment -> P.Externs -> P.SupplyT Make ()
  codegen m env exts = do
    let mn = CF.moduleName m
    let filePath = runModuleName' mn
        fileBase = outputDir </> filePath </> (last . words . dotsTo ' ' $ runModuleName' mn)
        sourceFile = addExtension fileBase sourceExt
        headerFile = addExtension fileBase headerExt
        externsFile = outputDir </> filePath </> "externs.json"
        prefix = ["Generated by pcc version " <> T.pack (showVersion Paths.version) | usePrefix]
    cpps <- CPP.moduleToCpp otherOpts env m
    let (hdrs,srcs) = span (/= CPP.CppEndOfHeader) cpps
    psrcs <- CPP.prettyPrintCpp <$> pure srcs
    phdrs <- CPP.prettyPrintCpp <$> pure hdrs
    let src = T.unlines $ map ("// " <>) prefix ++ [psrcs]
        hdr = T.unlines $ map ("// " <>) prefix ++ [phdrs]

    lift $ do
      writeTextFile' sourceFile src
      writeTextFile' headerFile hdr
      writeTextFile externsFile exts

      let supportDir = outputDir </> "PureScript"
      supportFilesExist <- dirExists supportDir
      when (not supportFilesExist) $ do
        writeTextFile (supportDir </> "PureScript.hh") $ B.fromStrict $(embedFile "pcc/runtime/purescript.hh")
        writeTextFile (supportDir </> "PureScript.cc") $ B.fromStrict  $(embedFile "pcc/runtime/purescript.cc")
        writeTextFile (supportDir </> "purescript_memory.hh") $ B.fromStrict $(embedFile "pcc/runtime/purescript_memory.hh")

      let inputPath = dropExtension $ getInputFile mn
          hfile = addExtension inputPath headerExt
          sfile = addExtension inputPath sourceExt
      hfileExists <- textFileExists hfile
      when (hfileExists || requiresForeign m) $ do
        let dstFile = addExtension (fileBase ++ ffiMangle) headerExt
        if hfileExists
          then copyTextFile dstFile hfile
          else writeTextFile dstFile ""
      sfileExists <- textFileExists sfile
      when (sfileExists) $ do
        copyTextFile (addExtension (fileBase ++ ffiMangle) sourceExt) sfile
      mapM (copyTextFileWithExt fileBase inputPath) otherExts
      return ()

  requiresForeign :: CF.Module a -> Bool
  requiresForeign = not . null . CF.moduleForeign

  dirExists :: FilePath -> Make Bool
  dirExists path = makeIO (const (ErrorMessage [] $ CannotReadFile path)) $ do
    doesDirectoryExist path

  textFileExists :: FilePath -> Make Bool
  textFileExists path = makeIO (const (ErrorMessage [] $ CannotReadFile path)) $ do
    doesFileExist path

  getTimestamp :: FilePath -> Make (Maybe UTCTime)
  getTimestamp path = makeIO (const (ErrorMessage [] $ CannotGetFileInfo path)) $ do
    exists <- doesFileExist path
    traverse (const $ getModificationTime path) $ guard exists

  copyTextFile :: FilePath -> FilePath -> Make ()
  copyTextFile to from = makeIO (const (ErrorMessage [] $ CannotWriteFile to)) $ do
    createDirectoryIfMissing True (takeDirectory to)
    copyFile from to

  copyTextFileWithExt :: FilePath -> FilePath -> String -> Make ()
  copyTextFileWithExt to from ext = makeIO (const (ErrorMessage [] $ CannotWriteFile to)) $ do
    createDirectoryIfMissing True (takeDirectory to)
    _ <- tryIOError $ copyFile (addExtension from ext) (addExtension to ext)
    return ()

  writeTextFile :: FilePath -> B.ByteString -> Make ()
  writeTextFile path text = makeIO (const (ErrorMessage [] $ CannotWriteFile path)) $ do
    mkdirp path
    _ <- tryIOError $ B.writeFile path text -- TODO: intended to ignore "file busy", fix properly asap
    return ()
    where
    mkdirp :: FilePath -> IO ()
    mkdirp = createDirectoryIfMissing True . takeDirectory

  writeTextFile' path = writeTextFile path . B.fromStrict . TE.encodeUtf8

  -- | Render a progress message
  renderProgressMessage :: P.ProgressMessage -> String
  renderProgressMessage (P.CompilingModule mn) = "Compiling " ++ runModuleName' mn

  progress :: P.ProgressMessage -> Make ()
  progress = liftIO . putStrLn . renderProgressMessage

dotsTo :: Char -> String -> String
dotsTo chr = map (\c -> if c == '.' then chr else c)

headerExt :: String
headerExt = "hh"

sourceExt :: String
sourceExt = "cc"

otherExts :: [String]
otherExts = ["h", "inl"]

ffiMangle :: String
ffiMangle = "_ffi"
