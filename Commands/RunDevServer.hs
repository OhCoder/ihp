{-# LANGUAGE NamedFieldPuns #-}

module Main where
import ClassyPrelude hiding (threadDelay)
import qualified System.Process as Process
import Twitch
import qualified Twitch
import System.Exit
import System.Posix.Signals
import qualified Control.Exception as Exception
import qualified GHC.IO.Handle as Handle
import System.Process.Internals
import Data.String.Conversions (cs)
import Control.Concurrent (threadDelay)
import qualified System.FSNotify as FS
import System.Directory (getCurrentDirectory, withCurrentDirectory)
import qualified System.Directory as Directory
import Data.Default (def)
import Data.Maybe (fromJust)
import qualified Control.Concurrent.Lock as Lock
import qualified Foundation.DevelopmentSupport.LiveReloadNotificationServer as LiveReloadNotificationServer

data DevServerState = DevServerState {
        postgresProcess :: IORef (Handle, Process.ProcessHandle),
        serverProcess :: IORef (Handle, Process.ProcessHandle),
        modelCompilerProcess :: IORef (Handle, Process.ProcessHandle),
        urlGeneratorCompilerProcess :: IORef (Handle, Process.ProcessHandle),
        rebuildServerLock :: Lock.Lock,
        liveReloadNotificationServerProcess :: IORef (Handle, Process.ProcessHandle)
    }

initDevServerState = do
    postgresProcess <- startPostgres >>= newIORef
    serverProcess <- startPlainGhci >>= initServer >>= newIORef
    modelCompilerProcess <- startCompileGhci >>= newIORef
    urlGeneratorCompilerProcess <- startCompileGhci >>= newIORef
    rebuildServerLock <- Lock.new
    liveReloadNotificationServerProcess <- startLiveReloadNotificationServer >>= newIORef
    return $ DevServerState {
            postgresProcess = postgresProcess,
            serverProcess = serverProcess,
            modelCompilerProcess = modelCompilerProcess,
            urlGeneratorCompilerProcess = urlGeneratorCompilerProcess,
            rebuildServerLock = rebuildServerLock,
            liveReloadNotificationServerProcess = liveReloadNotificationServerProcess
        }

registerExitHandler handler = do
    threadId <- myThreadId
    installHandler keyboardSignal (Catch (do { handler; Exception.throwTo threadId ExitSuccess })) Nothing

main = do
    state <- initDevServerState
    registerExitHandler (cleanup state)
    manager <- withCurrentDirectory "./src" $ do
        currentDir <- getCurrentDirectory
        dirs <- findAllDirectories
        let config = def { logger = print, dirs = ".":dirs }
        Twitch.runWithConfig currentDir config (watch state)
    forever (threadDelay maxBound) `finally` (do FS.stopManager manager; cleanup state)

cleanup :: DevServerState -> IO ()
cleanup state = do
    putStrLn "cleanup"
    let DevServerState { serverProcess, postgresProcess, modelCompilerProcess, urlGeneratorCompilerProcess, liveReloadNotificationServerProcess } = state
    let processes = [serverProcess, postgresProcess, modelCompilerProcess, urlGeneratorCompilerProcess]
    let stopProcess process = do (_, p') <- readIORef serverProcess; Process.terminateProcess p'
    stopServer
    forM_ processes stopProcess
    _ <- Process.system "lsof -i :8002|awk '{print $2}'|tail -n1|xargs kill -9"
    return ()

startPlainGhci = do
    let process = (Process.proc "ghci" ["-threaded", "-isrc", "-fexternal-interpreter", "-fomit-interface-pragmas", "-j4", "-fomit-interface-pragmas", "-prof", "+RTS", "-A512m", "-n2m"]) { Process.std_in = Process.CreatePipe }
    (Just input, _, _, handle) <- Process.createProcess process
    return (input, handle)

startCompileGhci = do
    let process = (Process.proc "ghci" ["-threaded", "-isrc", "-w", "-j2", "-fomit-interface-pragmas", "+RTS", "-A128m"]) { Process.std_in = Process.CreatePipe }
    (Just input, _, _, handle) <- Process.createProcess process
    return (input, handle)

startLiveReloadNotificationServer = do
    let process = (Process.proc "bin/RunLiveReloadNotificationServer" []) { Process.std_in = Process.CreatePipe }
    (Just input, _, _, handle) <- Process.createProcess process
    return (input, handle)


initServer ghci = do
    sendGhciCommand ghci (":script src/Foundation/startDevServerGhciScript")
    return ghci

watch state@(DevServerState {serverProcess, rebuildServerLock}) = do
    "Model/Schema.hs" |> const (rebuildModels state)
    "Routes.hs" |> const (rebuildUrlGenerator state)
    "*/*/Routes.hs" |> const (rebuildUrlGenerator state)
    "View/*/*.hs" |> const (rebuild serverProcess rebuildServerLock)
    "Model/Generated/*.hs" |> const (rebuild serverProcess rebuildServerLock)
    "UrlGenerator.hs" |> const (rebuild serverProcess rebuildServerLock)
    "**.hs" |> const (rebuild serverProcess rebuildServerLock)
    "*.hs" |> const (rebuild serverProcess rebuildServerLock)
    "*/*.hs" |> const (rebuild serverProcess rebuildServerLock)
    "*/*/*.hs" |> const (rebuild serverProcess rebuildServerLock)
    "*/*/*/*.hs" |> const (rebuild serverProcess rebuildServerLock)
    "*/*/*/*/*.hs" |> const (rebuild serverProcess rebuildServerLock)


rebuildModels (DevServerState {modelCompilerProcess}) = do
    putStrLn "rebuildModels"
    ghci@(input, process) <- readIORef modelCompilerProcess
    sendGhciCommand ghci ":!clear"
    sendGhciCommand ghci ":l src/Foundation/SchemaCompiler.hs"
    sendGhciCommand ghci "c"
    putStrLn "rebuildModels => Finished"

rebuildUrlGenerator (DevServerState {urlGeneratorCompilerProcess}) = do
    putStrLn "rebuildUrlGenerator"
    ghci@(input, process) <- readIORef urlGeneratorCompilerProcess
    sendGhciCommand ghci ":l src/Foundation/UrlGeneratorCompiler.hs"
    sendGhciCommand ghci "c"
    putStrLn "rebuildUrlGenerator => Finished"

sendGhciInterrupt ghci@(input, process) = do
    pid <- getPid process
    case pid of
        Just pid -> signalProcess sigINT pid
        Nothing -> putStrLn "sendGhciInterrupt: failed, pid not found"

rebuild serverProcess rebuildServerLock = do
    _ <- Lock.tryWith rebuildServerLock $ do
        putStrLn "Rebuilding server"
        ghci <- readIORef serverProcess
        _ <- Process.system "lsof -i :8000|grep ghc-iserv | awk '{print $2}'|head -n1|xargs kill -SIGINT"
        threadDelay 1000000
        sendGhciCommand ghci ":script src/Foundation/startDevServerGhciScriptRec"
    return ()

sendGhciCommand ghciProcess command = do
    let (input, process) = ghciProcess
    putStrLn $ "Sending to ghci: " <> cs command
    Handle.hPutStr input (command <> "\n")
    Handle.hFlush input

stopServer = do
    putStrLn "stopServer called"
    _ <- Process.system "(lsof -i :8000|grep ghc-iserv | awk '{print $2}'|head -n1|xargs kill -9) || true"
    return ()

stopPostgres = do
    _ <- Process.system "(lsof -i tcp:8001 | grep postgres | awk 'NR!=1 {print $2}' | xargs kill) || true"
    return ()

startPostgres = do
    let process = (Process.proc "postgres" ["-D", "db/state", "-p", "8001"]) { Process.std_in = Process.CreatePipe }
    (Just input, _, _, handle) <- Process.createProcess process

    return (input, handle)

getPid ph = withProcessHandle ph go
    where
        go ph_ = case ph_ of
            OpenHandle x   -> return $ Just x
            ClosedHandle _ -> return Nothing

findAllDirectories :: IO [FilePath]
findAllDirectories = do
    let findDirs base = do
        all' <- Directory.listDirectory base
        let all = map (base </>) $ filter (\file -> (unsafeHead file /= '.') && (file /= "node_modules") ) all'
        filterM (Directory.doesDirectoryExist) all
    dirs <- findDirs "."
    let doRecurse dirs = do
        result <- forM dirs $ \directory -> do
            dirs <- findDirs directory
            inner <- doRecurse dirs
            return $ concat [(directory:dirs), inner]
        return $ join result

    allDirectories <- doRecurse dirs
    return $ map (fromJust . stripPrefix "./") allDirectories
