{-# LANGUAGE CPP #-}

module Main where

#if __GLASGOW_HASKELL__ < 709
import Data.Traversable (traverse)
#endif

import Control.Monad (when)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import System.Directory (getCurrentDirectory)
import System.Environment (getProgName)
import System.IO (hPutStrLn, stderr)
import System.FilePath ((</>), isAbsolute, takeDirectory)

import Cabal (findCabalFile)
import Client (getServerStatus, serverCommand, stopServer)
import CommandArgs
import Daemonize (daemonize)
import Server (startServer, createListenSocket)
import Stack (findStackYaml)
import Types (Command(..), CommandExtra(..), emptyCommandExtra)

absoluteFilePath :: FilePath -> IO FilePath
absoluteFilePath p = if isAbsolute p then return p else do
    dir <- getCurrentDirectory
    return $ dir </> p


defaultSocketFile :: FilePath
defaultSocketFile = ".hdevtools.sock"


fileArg :: HDevTools -> Maybe String
fileArg (Admin {})      = Nothing
fileArg (ModuleFile {}) = Nothing
fileArg args@(Check {}) = Just $ file args
fileArg args@(Info  {}) = Just $ file args
fileArg args@(Type  {}) = Just $ file args
fileArg (FindSymbol {}) = Nothing

pathArg' :: HDevTools -> Maybe String
pathArg' (Admin {})      = Nothing
pathArg' (ModuleFile {}) = Nothing
pathArg' args@(Check {}) = path args
pathArg' args@(Info  {}) = path args
pathArg' args@(Type  {}) = path args
pathArg' (FindSymbol {}) = Nothing

pathArg :: HDevTools -> Maybe String
pathArg args = case pathArg' args of
                Just x  -> Just x
                Nothing -> fileArg args

main :: IO ()
main = do
    args <- loadHDevTools
    let argPath = pathArg args
    dir  <- maybe getCurrentDirectory (return . takeDirectory) argPath
    mCabalFile <-
        if no_configure args
           then return Nothing
           else findCabalFile dir >>= traverse absoluteFilePath
    when (debug args) .
      putStrLn $ "Cabal file: " <> show mCabalFile
    mStackYaml <- findStackYaml dir
    when (debug args) .
      putStrLn $ "Stack file: " <> show mStackYaml
    let extra = emptyCommandExtra
                    { cePath = argPath
                    , ceGhcOptions  = ghcOpts args
                    , ceCabalFilePath = mCabalFile
                    , ceCabalOptions = cabalOpts args
                    , ceStackYamlPath = mStackYaml
                    }
    let defaultSocketPath = maybe "" takeDirectory mCabalFile </> defaultSocketFile
    let sock = fromMaybe defaultSocketPath $ socket args
    when (debug args) .
      putStrLn $ "Socket file: " <> show sock
    case args of
        Admin {} -> doAdmin sock args extra
        Check {} -> doCheck sock args extra
        ModuleFile {} -> doModuleFile sock args extra
        Info {} -> doInfo sock args extra
        Type {} -> doType sock args extra
        FindSymbol {} -> doFindSymbol sock args extra

doAdmin :: FilePath -> HDevTools -> CommandExtra -> IO ()
doAdmin sock args cmdExtra
    | start_server args =
        if noDaemon args then startServer sock Nothing cmdExtra
            else do
                s <- createListenSocket sock
                daemonize True $ startServer sock (Just s) cmdExtra
    | status args = getServerStatus sock
    | stop_server args = stopServer sock
    | otherwise = do
        progName <- getProgName
        hPutStrLn stderr "You must provide a command. See:"
        hPutStrLn stderr $ progName ++ " --help"

doModuleFile :: FilePath -> HDevTools -> CommandExtra -> IO ()
doModuleFile sock args extra =
    serverCommand sock (CmdModuleFile (module_ args)) extra

doFileCommand :: String -> (HDevTools -> Command) -> FilePath -> HDevTools -> CommandExtra -> IO ()
doFileCommand cmdName cmd sock args extra
    | null (file args) = do
        progName <- getProgName
        hPutStrLn stderr "You must provide a haskell source file. See:"
        hPutStrLn stderr $ progName ++ " " ++ cmdName ++ " --help"
    | otherwise = do
        absFile <- absoluteFilePath $ file args
        let args' = args { file = absFile }
            extra' = extra { ceTemplateHaskell = not (noTH args) }
        serverCommand sock (cmd args') extra'

doCheck :: FilePath -> HDevTools -> CommandExtra -> IO ()
doCheck = doFileCommand "check" $
    \args -> CmdCheck (file args)

doInfo :: FilePath -> HDevTools -> CommandExtra -> IO ()
doInfo = doFileCommand "info" $
    \args -> CmdInfo (file args) (identifier args)

doType :: FilePath -> HDevTools -> CommandExtra -> IO ()
doType = doFileCommand "type" $
    \args -> CmdType (file args) (line args, col args)

doFindSymbol :: FilePath -> HDevTools -> CommandExtra -> IO ()
doFindSymbol sock args extra =
    serverCommand sock (CmdFindSymbol (symbol args) (files args)) extra
