{-# Language OverloadedStrings #-}
{-# Language BangPatterns #-}
{-# Language ViewPatterns #-}

module Unison.Codebase.TranscriptParser (
  Stanza(..), FenceType, ExpectingError, HideOutput, Err, UcmCommand(..),
  run, parse, parseFile)
  where

-- import qualified Text.Megaparsec.Char as P
import Control.Concurrent.STM (atomically)
import Control.Exception (finally)
import Control.Monad.State (runStateT)
import Data.IORef
import Prelude hiding (readFile, writeFile)
import System.Exit (die)
import System.FilePath ((</>))
import System.IO.Error (catchIOError)
import Unison.Codebase (Codebase)
import Unison.Codebase.Editor.Input (Input (..), Event(UnisonFileChanged))
import Unison.CommandLine
import Unison.CommandLine.InputPattern (InputPattern (aliases, patternName))
import Unison.CommandLine.InputPatterns (validInputs)
import Unison.CommandLine.OutputMessages (notifyUser)
import Unison.Parser (Ann)
import Unison.Prelude
import Unison.PrettyTerminal
import Unison.Symbol (Symbol)
import Unison.CommandLine.Main (asciiartUnison)
import qualified Data.Char as Char
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Text.Megaparsec as P
import qualified Unison.Codebase as Codebase
import qualified Unison.Codebase.Editor.HandleCommand as HandleCommand
import qualified Unison.Codebase.Editor.HandleInput as HandleInput
import qualified Unison.Codebase.Path as Path
import qualified Unison.Codebase.Runtime as Runtime
import qualified Unison.CommandLine.InputPattern as IP
import qualified Unison.Runtime.Rt1IO as Rt1
import qualified Unison.Util.Pretty as P
import qualified Unison.Util.TQueue as Q

type ExpectingError = Bool
type HideOutput = Bool
type Err = String
type ScratchFileName = Text

type FenceType = Text

data UcmCommand = UcmCommand Path.Absolute Text deriving Show

data Stanza
  = Ucm HideOutput [UcmCommand]
  | Unison HideOutput (Maybe ScratchFileName) Text
  | UnprocessedFence FenceType Text
  | Unfenced Text
  deriving Show

parseFile :: FilePath -> IO (Either Err [Stanza])
parseFile filePath = do
  txt <- readUtf8 filePath
  pure $ parse filePath txt

parse :: String -> Text -> Either Err [Stanza]
parse srcName txt = case P.parse (stanzas <* P.eof) srcName txt of
  Right a -> Right a
  Left e -> Left (show e)

run :: FilePath -> [Stanza] -> Codebase IO Symbol Ann -> IO Text
run dir stanzas codebase = do
  let initialPath = Path.absoluteEmpty
  let startRuntime = pure Rt1.runtime
  putPrettyLn $ P.lines [
    asciiartUnison, "",
    "Running the provided transcript file...",
    ""
    ]
  root <- Codebase.getRootBranch codebase
  do
    runtime                  <- startRuntime
    pathRef                  <- newIORef initialPath
    numberedArgsRef          <- newIORef []
    inputQueue               <- Q.newIO
    cmdQueue                 <- Q.newIO
    out                      <- newIORef mempty
    hidden                   <- newIORef False
    (config, cancelConfig)   <-
      catchIOError (watchConfig $ dir </> ".unisonConfig") $ \_ ->
        die "Your .unisonConfig could not be loaded. Check that it's correct!"
    traverse_ (atomically . Q.enqueue inputQueue) stanzas
    let patternMap =
          Map.fromList
            $   validInputs
            >>= (\p -> (patternName p, p) : ((, p) <$> aliases p))
    let
      output :: String -> IO ()
      output msg = do
        hide <- readIORef hidden
        when (not hide) $ modifyIORef' out (\acc -> acc <> pure msg)

      awaitInput = do
        cmd <- atomically (Q.tryDequeue cmdQueue)
        case cmd of
          Just Nothing -> do
            output "</div>\n" -- this ends the ucm-output div
            writeIORef hidden False
            awaitInput
          Just (Just p@(UcmCommand path lineTxt)) -> do
            curPath <- readIORef pathRef
            if (curPath /= path) then do
              atomically $ Q.undequeue cmdQueue (Just p)
              pure $ Right (SwitchBranchI (Path.absoluteToPath' path))
            else case words (Text.unpack lineTxt) of
              [] -> awaitInput
              cmd:args -> case Map.lookup cmd patternMap of
                Nothing -> awaitInput
                Just pat -> case IP.parse pat args of
                  Left msg -> do
                    output $ P.toHTML "ucm-output" 65 msg
                    awaitInput
                  Right input -> pure $ Right input
          Nothing -> do
            stanza <- atomically (Q.tryDequeue inputQueue)
            case stanza of
              Nothing -> pure $ Right QuitI
              Just s -> case s of
                Unfenced _ -> do
                  output $ show s
                  awaitInput
                UnprocessedFence _ _ -> do
                  output $ show s
                  awaitInput
                Unison hide filename txt -> do
                  output $ show s
                  writeIORef hidden hide
                  pure $ Left (UnisonFileChanged (fromMaybe "<interactive>" filename) txt)
                Ucm hide cmds -> do
                  output $ show s
                  writeIORef hidden hide
                  output $ "<div class=\"ucm-output\">\n"
                  traverse_ (atomically . Q.enqueue cmdQueue . Just) cmds
                  atomically . Q.enqueue cmdQueue $ Nothing
                  awaitInput

      cleanup = do Runtime.terminate runtime; cancelConfig
      print o = do
        msg <- notifyUser dir o
        putPrettyNonempty msg
        let html = P.toHTML "ucm-output" 65 msg
        output html
        pure ()

      loop state = do
        writeIORef pathRef (HandleInput._currentPath state)
        let free = runStateT (runMaybeT HandleInput.loop) state
        (o, state') <- HandleCommand.commandLine config awaitInput
                                     (const $ pure ())
                                     runtime
                                     print
                                     codebase
                                     free
        case o of
          Nothing -> do
            texts <- readIORef out
            pure $ Text.concat (Text.pack <$> toList (texts :: Seq String))
          Just () -> do
            writeIORef numberedArgsRef (HandleInput._numberedArgs state')
            loop state'
    (`finally` cleanup)
      $ loop (HandleInput.loopState0 root initialPath)

type P = P.Parsec () Text

stanzas :: P [Stanza]
stanzas = P.many (fenced <|> unfenced)

ucmCommand :: P UcmCommand
ucmCommand = do
  P.lookAhead (word ".")
  path <- P.takeWhile1P Nothing (/= '>')
  void $ word ">"
  line <- P.takeWhileP Nothing (/= '\n') <* spaces
  path <- case Path.parsePath' (Text.unpack path) of
    Right (Path.unPath' -> Left abs) -> pure abs
    Right _ -> fail "expected absolute path"
    Left e -> fail e
  pure $ UcmCommand path line

fenced :: P Stanza
fenced = do
  fence
  fenceType <- word "ucm" <|> word "unison" <|> untilSpace1
  stanza <-
    if fenceType == "ucm" then do
      hideOutput <- hideOutput
      cmds <- many ucmCommand
      pure $ Ucm hideOutput cmds
    else if fenceType == "unison" then do
      hideOutput <- hideOutput
      fileName <- optional untilSpace1
      blob <- untilFence
      pure $ Unison hideOutput fileName blob
    else UnprocessedFence fenceType <$> untilFence
  fence
  pure stanza

-- Three backticks, consumes trailing spaces too
-- ```
fence :: P ()
fence = P.try $ do void (word "```"); spaces

-- Parses up until next fence
unfenced :: P Stanza
unfenced = Unfenced <$> untilFence

untilFence :: P Text
untilFence = do
  _ <- P.lookAhead (P.takeP Nothing 1)
  go mempty
  where
  go :: Seq Text -> P Text
  go !acc = do
    f <- P.lookAhead (P.optional fence)
    case f of
      Nothing -> do
        oneOrTwoBackticks <- optional (word' "``" <|> word' "`")
        let start = fromMaybe "" oneOrTwoBackticks
        txt <- P.takeWhileP (Just "unfenced") (/= '`')
        eof <- P.lookAhead (P.optional P.eof)
        case eof of
          Just _ -> pure $ foldMap id (acc <> pure txt)
          Nothing -> go (acc <> pure start <> pure txt)
      Just _ -> pure $ foldMap id acc

word' :: Text -> P Text
word' txt = P.try $ do
  chs <- P.takeP (Just $ show txt) (Text.length txt)
  guard (chs == txt)
  pure txt

word :: Text -> P Text
word txt = word' txt <* spaces

hideOutput :: P HideOutput
hideOutput = isJust <$> (optional (word ":hide") <* spaces)

untilSpace1 :: P Text
untilSpace1 = P.takeWhile1P Nothing (not . Char.isSpace)

spaces :: P ()
spaces = void $ P.takeWhileP (Just "spaces") Char.isSpace

-- single :: Char -> P Char
-- single t = P.satisfy (== t)
