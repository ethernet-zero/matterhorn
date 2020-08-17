{-# LANGUAGE TypeFamilies #-}
module Matterhorn.State.Setup
  ( setupState
  )
where

import           Prelude ()
import           Matterhorn.Prelude

import           Brick.BChan ( newBChan )
import           Brick.Themes ( themeToAttrMap, loadCustomizations )
import qualified Control.Concurrent.STM as STM
import           Data.Maybe ( fromJust )
import qualified Data.Sequence as Seq
import qualified Data.Text as T
import           Data.Time.Clock ( getCurrentTime )
import qualified Graphics.Vty as Vty
import           Lens.Micro.Platform ( (.~) )
import           System.Exit ( exitFailure, exitSuccess )
import           System.FilePath ( (</>), isRelative, dropFileName )

import           Network.Mattermost.Endpoints
import           Network.Mattermost.Types

import           Matterhorn.Config
import           Matterhorn.InputHistory
import           Matterhorn.LastRunState
import           Matterhorn.Login
import           Matterhorn.State.Flagging
import           Matterhorn.State.Messages ( fetchVisibleIfNeeded )
import           Matterhorn.State.Setup.Threads
import           Matterhorn.TeamSelect
import           Matterhorn.Themes
import           Matterhorn.TimeUtils ( lookupLocalTimeZone )
import           Matterhorn.Types
import           Matterhorn.Types.Common
import           Matterhorn.Emoji
import           Matterhorn.FilePaths ( userEmojiJsonPath, bundledEmojiJsonPath )
import qualified Matterhorn.Zipper as Z


incompleteCredentials :: Config -> ConnectionInfo
incompleteCredentials config = ConnectionInfo
  { _ciHostname = fromMaybe "" (configHost config)
  , _ciPort     = configPort config
  , _ciUrlPath  = fromMaybe "" (configUrlPath config)
  , _ciUsername = fromMaybe "" (configUser config)
  , _ciPassword = case configPass config of
                    Just (PasswordString s) -> s
                    _                       -> ""
  , _ciAccessToken = case configToken config of
                       Just (TokenString s) -> s
                       _                    -> ""
  , _ciType     = configConnectionType config
  }

apiLogEventToLogMessage :: LogEvent -> IO LogMessage
apiLogEventToLogMessage ev = do
    now <- getCurrentTime
    let msg = T.pack $ "Function: " <> logFunction ev <>
                       ", event: " <> show (logEventType ev)
    return $ LogMessage { logMessageCategory = LogAPI
                        , logMessageText = msg
                        , logMessageContext = Nothing
                        , logMessageTimestamp = now
                        }

setupState :: IO Vty.Vty -> Maybe FilePath -> Config -> IO (ChatState, Vty.Vty)
setupState mkVty mLogLocation config = do
  initialVty <- mkVty

  eventChan <- newBChan 2500
  logMgr <- newLogManager eventChan (configLogMaxBufferSize config)

  -- If we got an initial log location, start logging there.
  case mLogLocation of
      Nothing -> return ()
      Just loc -> startLoggingToFile logMgr loc

  let logApiEvent ev = apiLogEventToLogMessage ev >>= sendLogMessage logMgr
      setLogger cd = cd `withLogger` logApiEvent

  (mLastAttempt, loginVty) <- interactiveGetLoginSession initialVty mkVty
                                                         setLogger
                                                         logMgr
                                                         (incompleteCredentials config)

  let shutdown vty = do
          Vty.shutdown vty
          exitSuccess

  (session, me, cd, mbTeam) <- case mLastAttempt of
      Nothing ->
          -- The user never attempted a connection and just chose to
          -- quit.
          shutdown loginVty
      Just (AttemptFailed {}) ->
          -- The user attempted a connection and failed, and then chose
          -- to quit.
          shutdown loginVty
      Just (AttemptSucceeded _ cd sess user mbTeam) ->
          -- The user attempted a connection and succeeded so continue
          -- with setup.
          return (sess, user, cd, mbTeam)

  teams <- mmGetUsersTeams UserMe session
  when (Seq.null teams) $ do
      putStrLn "Error: your account is not a member of any teams"
      exitFailure

  (myTeam, teamSelVty) <- do
      let foundTeam = do
             tName <- mbTeam <|> configTeam config
             let matchingTeam = listToMaybe $ filter matches $ toList teams
                 matches t = (sanitizeUserText $ teamName t) == tName
             matchingTeam

      case foundTeam of
          Just t -> return (t, loginVty)
          Nothing -> do
              (mTeam, vty) <- interactiveTeamSelection loginVty mkVty $ toList teams
              case mTeam of
                  Nothing -> shutdown vty
                  Just team -> return (team, vty)

  userStatusChan <- STM.newTChanIO
  slc <- STM.newTChanIO
  wac <- STM.newTChanIO

  prefs <- mmGetUsersPreferences UserMe session
  let userPrefs = setUserPreferences prefs defaultUserPreferences
      themeName = case configTheme config of
          Nothing -> internalThemeName defaultTheme
          Just t -> t
      baseTheme = internalTheme $ fromMaybe defaultTheme (lookupTheme themeName)

  -- Did the configuration specify a theme customization file? If so,
  -- load it and customize the theme.
  custTheme <- case configThemeCustomizationFile config of
      Nothing -> return baseTheme
      Just path ->
          -- If we have no configuration path (i.e. we used the default
          -- config) then ignore theme customization.
          let pathStr = T.unpack path
          in if isRelative pathStr && isNothing (configAbsPath config)
             then return baseTheme
             else do
                 let absPath = if isRelative pathStr
                               then (dropFileName $ fromJust $ configAbsPath config) </> pathStr
                               else pathStr
                 result <- loadCustomizations absPath baseTheme
                 case result of
                     Left e -> do
                         Vty.shutdown teamSelVty
                         putStrLn $ "Error loading theme customization from " <> show absPath <> ": " <> e
                         exitFailure
                     Right t -> return t

  requestChan <- STM.atomically STM.newTChan

  emoji <- either (const emptyEmojiCollection) id <$> do
      result1 <- loadEmoji =<< userEmojiJsonPath
      case result1 of
          Right e -> return $ Right e
          Left _ -> loadEmoji =<< bundledEmojiJsonPath

  let cr = ChatResources { _crSession             = session
                         , _crWebsocketThreadId   = Nothing
                         , _crConn                = cd
                         , _crRequestQueue        = requestChan
                         , _crEventQueue          = eventChan
                         , _crSubprocessLog       = slc
                         , _crWebsocketActionChan = wac
                         , _crTheme               = themeToAttrMap custTheme
                         , _crStatusUpdateChan    = userStatusChan
                         , _crConfiguration       = config
                         , _crFlaggedPosts        = mempty
                         , _crUserPreferences     = userPrefs
                         , _crSyntaxMap           = mempty
                         , _crLogManager          = logMgr
                         , _crEmoji               = emoji
                         }

  st <- initializeState cr myTeam me

  return (st, teamSelVty)

initializeState :: ChatResources -> Team -> User -> IO ChatState
initializeState cr myTeam me = do
  let session = getResourceSession cr
      requestChan = cr^.crRequestQueue
      myTId = getId myTeam

  -- Create a predicate to find the last selected channel by reading the
  -- run state file. If unable to read or decode or validate the file, this
  -- predicate is just `isTownSquare`.
  isLastSelectedChannel <- do
    result <- readLastRunState $ teamId myTeam
    case result of
      Right lrs | isValidLastRunState cr me lrs -> return $ \c ->
           channelId c == lrs^.lrsSelectedChannelId
      _ -> return isTownSquare

  -- Get all channels, but filter down to just the one we want to start
  -- in. We get all, rather than requesting by name or ID, because
  -- we don't know whether the server will give us a last-viewed preference.
  -- We first try to find a channel matching with the last selected channel ID,
  -- failing which we look for the Town Square channel by name.
  userChans <- mmGetChannelsForUser UserMe myTId session
  let lastSelectedChans = Seq.filter isLastSelectedChannel userChans
      chans = if Seq.null lastSelectedChans
                then Seq.filter isTownSquare userChans
                else lastSelectedChans

  -- Since the only channel we are dealing with is by construction the
  -- last channel, we don't have to consider other cases here:
  chanPairs <- forM (toList chans) $ \c -> do
      cChannel <- makeClientChannel (userId me) c
      return (getId c, cChannel)

  tz <- lookupLocalTimeZone
  hist <- do
      result <- readHistory
      case result of
          Left _ -> return newHistory
          Right h -> return h

  --------------------------------------------------------------------
  -- Start background worker threads:
  --
  -- * Syntax definition loader
  startSyntaxMapLoaderThread (cr^.crConfiguration) (cr^.crEventQueue)

  -- * Main async queue worker thread
  startAsyncWorkerThread (cr^.crConfiguration) (cr^.crRequestQueue) (cr^.crEventQueue)

  -- * User status thread
  startUserStatusUpdateThread (cr^.crStatusUpdateChan) session requestChan

  -- * Refresher for users who are typing currently
  when (configShowTypingIndicator (cr^.crConfiguration)) $
    startTypingUsersRefreshThread requestChan

  -- * Timezone change monitor
  startTimezoneMonitorThread tz requestChan

  -- * Subprocess logger
  startSubprocessLoggerThread (cr^.crSubprocessLog) requestChan

  -- * Spell checker and spell check timer, if configured
  spResult <- maybeStartSpellChecker (cr^.crConfiguration) (cr^.crEventQueue)

  -- End thread startup ----------------------------------------------

  now <- getCurrentTime
  let chanIds = mkChannelZipperList now (cr^.crConfiguration) Nothing (cr^.crUserPreferences) clientChans noUsers
      chanZip = Z.fromList chanIds
      clientChans = foldr (uncurry addChannel) noChannels chanPairs
      startupState =
          StartupStateInfo { startupStateResources      = cr
                           , startupStateChannelZipper  = chanZip
                           , startupStateConnectedUser  = me
                           , startupStateTeam           = myTeam
                           , startupStateTimeZone       = tz
                           , startupStateInitialHistory = hist
                           , startupStateSpellChecker   = spResult
                           }

  initialState <- newState startupState
  let st = initialState & csChannels .~ clientChans

  loadFlaggedMessages (cr^.crUserPreferences.userPrefFlaggedPostList) st

  -- Trigger an initial websocket refresh
  writeBChan (cr^.crEventQueue) RefreshWebsocketEvent

  -- Refresh initial channel(s)
  writeBChan (cr^.crEventQueue) $ RespEvent $ do
      fetchVisibleIfNeeded

  return st