
{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, DeriveGeneric,
             TypeOperators, BangPatterns, FlexibleContexts #-}


-- {{{ Imports

import Control.Concurrent (forkIO, threadDelay)
import Control.Lens hiding ((.=), op)
import Control.Monad (forever, join, unless, void, when)

import Data.Aeson
import Data.Aeson.Types (Options(..))
import Data.Char (toLower, toUpper)
import Data.IORef
import Data.List (isPrefixOf)
import qualified Data.HashMap as HM
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe (catMaybes)
import Data.String (IsString(..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.ByteString.Lazy.Char8 as BL

import GHC.Generics (Generic(..))
import GHC.IO.Encoding (setLocaleEncoding, utf8)

import Network.WebSockets
import Network.Wreq hiding (get)
import Network.Wreq.Types

import System.IO.Unsafe (unsafePerformIO)
import System.Random (randomRIO)

import Wuss (runSecureClient)

-- }}}


-- {{{ Data

type f $ a = f a

data Identify = Identify { identifyToken :: Text
                         , identifyProperties :: Map Text Text
                         , identifyCompress :: Bool
                         , identifyLarge_threshold :: Int
                         , identifyShard :: [Int]
                         }
                         deriving (Generic, Show)

instance ToJSON Identify where
    toEncoding = lowerToEncoding 8
    toJSON = lowerToJSON 8

data Dispatch a = Dispatch { dispatchOP :: Int
                           , dispatchD :: a
                           , dispatchS :: Maybe Int
                           , dispatchT :: Maybe Text
                           }
                           deriving (Generic, Show)

instance ToJSON a => ToJSON (Dispatch a) where
    toJSON (Dispatch op d ms mt) = object list
      where
        consMay attr = maybe id ((:) . (attr .=))
        conss = consMay "s" ms . consMay "t" mt
        list = conss ["op" .= op, ("d", toJSON d) ]

--instance ToJSON a => ToJSON (Dispatch a) where
--    toEncoding = genericToEncoding $ defaultOptions { omitNothingFields = True }

instance FromJSON a => FromJSON (Dispatch a) where
    parseJSON = lowerFromJSON 8

data MessageCreate = MessageCreate { messagecTTS :: Bool
                                   , messagecTimestamp :: Text
                                   , messagecPinned :: Bool
                                   , messagecNonce :: Maybe Text
                                   , messagecMentions :: [Text]
                                   , messagecMention_roles :: [Text]
                                   , messagecMention_everyone :: Bool
                                   , messagecId :: Text
                                   , messagecEmbeds :: [Text]
                                   , messagecEdited_timestamp :: Maybe Text
                                   , messagecContent :: Text
                                   , messagecChannel_id :: String
                                   , messagecAuthor :: Map Text Text
                                   , messagecAttachments :: [Text]
                                   }
                                   deriving (Generic, Show)

instance ToJSON MessageCreate where
    toEncoding = lowerToEncoding 8
instance FromJSON MessageCreate where
    parseJSON = lowerFromJSON 8

data User = User { userVerified :: Bool
                 , userUsername :: Text
                 , userId :: Text
                 , userEmail :: Maybe Text
                 , userDiscriminator :: Text
                 , userBot :: Maybe Bool
                 , userAvatar :: Maybe Text
                 }
                 deriving (Generic, Show)

instance ToJSON User where
    toEncoding = lowerToEncoding 4
instance FromJSON User where
    parseJSON = lowerFromJSON 4

data Guild = Guild { guildUnavailable :: Bool
                   , guildId :: Text
                   }
                   deriving (Generic, Show)

instance ToJSON Guild where
    toEncoding = lowerToEncoding 5
instance FromJSON Guild where
    parseJSON = lowerFromJSON 5

data Hello = Hello { heartbeat_interval :: Int, _trace :: [Text] }
    deriving (Generic, Show)

instance ToJSON Hello

data Ready = Ready { readyV :: Int
                   , readyUser :: User
                   , readyShard :: [Int]
                   , readySession_id :: Text
                   , readyRelationships :: [Text] -- TODO
                   , readyPrivate_channels :: [Text] -- TODO
                   , readyPresences :: [Text] -- TODO
                   , readyHeartbeat_interval :: Int
                   , readyGuilds :: [Guild]
                   , ready_trace :: [Text]
                   }
                   deriving (Generic, Show)

instance ToJSON Ready where
    toEncoding = lowerToEncoding 5
instance FromJSON Ready where
    parseJSON = lowerFromJSON 5

data GuildCreate = GuildCreate { guildcVoice_states :: [Text] -- TODO
                               , guildcVerification_level :: Int
                               , guildcUnavailable :: Bool
                               , guildcRoles :: [Text] -- TODO
                               , guildcRegion :: Text
                               , guildcPresences :: [Text] -- TODO
                               , guildcOwner_id :: Text
                               , guildcName :: Text
                               , guildcMfa_level :: Int
                               , guildcMembers :: [Text] -- TODO
                               , guildcMember_count :: Int
                               , guildcLarge :: Bool
                               , guildcJoined_at :: Text
                               , guildcId :: Text
                               , guildcIcon :: Text
                               , guildcFeatures :: [Text] -- TODO
                               , guildcEmojis :: [Text] -- TODO
                               , guildcDefault_message_notifications :: Int
                               , guildcChannels :: [Text] -- TODO
                               , guildcAFK_timeout :: Int
                               , guildcAFK_channel_id :: Maybe Text
                               }
                               deriving (Generic, Show)

instance ToJSON GuildCreate where
    toEncoding = lowerToEncoding 6
instance FromJSON GuildCreate where
    parseJSON = lowerFromJSON 6

data TypingStart = TypingStart { typingsUser_id :: Text
                               , typingsTimestamp :: Text
                               , typingsChannel_id :: Text
                               }
                               deriving (Generic, Show)

instance ToJSON TypingStart where
    toEncoding = lowerToEncoding 7
instance FromJSON TypingStart where
    parseJSON = lowerFromJSON 7


lowerFromJSON n = genericParseJSON opts
  where
    opts = defaultOptions { fieldLabelModifier = map toLower . drop n }

lowerToJSON n = genericToJSON opts
  where
    opts = defaultOptions { fieldLabelModifier = map toLower . drop n }

lowerToEncoding n = genericToEncoding opts
  where
    opts = defaultOptions { fieldLabelModifier = map toLower . drop n }

-- }}}


appId = "181425182257315840"
appSecret = "P0sOHDhBgcDnRv6uy9PQ8h7nEmWi_d0K"

botId = "181494632721547266"
botToken = "MTgxNDk0NjMyNzIxNTQ3MjY2.ChpljA.WmukAGg2GV9Q8csv5rbgAARtZ5w"

apiURL :: String
apiURL = "https://discordapp.com/api"
gatewayURL = apiURL ++ "/gateway"
messageURL channelId = "/channels/" ++ channelId ++ "/messages"

wsURL = "gateway.discord.gg"

userAgent = "DiscordBot (https://github.com/Shou, v1.0)"

opts = defaults & header "User-Agent" .~ [userAgent]
                & header "Authorization" .~ [fromString botToken]
                & header "Content-Type" .~ ["application/json"]

props = M.fromList [ ("$os", "linux")
                   , ("$browser", "Tombot")
                   , ("$device", "Tombot")
                   , ("$referrer", "")
                   , ("$referring_domain", "")
                   ]


stateSeq = unsafePerformIO $ newIORef 0


sendJSON obj conn = do
    let json = encode obj
    BL.putStrLn json
    sendTextData conn json

sendHTTP path obj = do
    r <- postWith opts (apiURL ++ path) obj
    let responseText = r ^. responseBody
    print responseText

identify :: ToJSON a => a -> Connection -> IO ()
identify obj = sendJSON $ Dispatch 2 obj Nothing Nothing

onReady :: Connection -> Dispatch Ready -> IO ()
onReady conn dsptch@(Dispatch op d s t) = do
    print dsptch
    tid <- forkIO $ forever $ do
        let ms = readyHeartbeat_interval d * 900
        print ms
        threadDelay ms
        seq <- readIORef stateSeq
        let obj = Dispatch 1 seq Nothing Nothing
        sendJSON obj conn
    print tid

onGuildCreate :: Connection -> Dispatch GuildCreate -> IO ()
onGuildCreate conn dsptch = do
    print dsptch

onMessage :: Connection -> Dispatch MessageCreate -> IO ()
onMessage conn dsptch@(Dispatch op d s t) = do
    print dsptch
    atomicWriteIORef stateSeq $ maybe 0 id s
    when (T.isInfixOf "POO" $ messagecContent d) $ do
        n <- randomRIO (0, length messages - 1)
        let msgText = messages !! n
            msgObj :: Map Text Text
            msgObj = M.singleton "content" msgText
            channelId = messagecChannel_id d
        sendHTTP (messageURL channelId) $ encode msgObj
  where
    messages = [ "HHAHAAH FARTY"
               , "\\*POOPS\\*"
               , "POOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO"
               , "MOMMY"
               , "HAHAHAHAHAHAHAHAHA"
               , "STINKY!!!!!!!!!!!!!!!"
               , "POO POO POO POO POO POO POO POO"
               ]

websockLoop conn = do
    identify (Identify (fromString botToken) props False 50 [0, 1]) conn
    forever $ do
        msg <- receiveData conn
        BL.putStrLn msg
        let ready = decode msg :: Maybe $ Dispatch Ready
        let guildCreate = decode msg :: Maybe $ Dispatch GuildCreate
        let message = decode msg :: Maybe $ Dispatch MessageCreate
        maybe (return ()) (onMessage conn) message
        maybe (return ()) (onReady conn) ready
        maybe (return ()) (onGuildCreate conn) guildCreate

websockInit = do
    runSecureClient wsURL 443 "/" websockLoop


main :: IO ()
main = do
    setLocaleEncoding utf8
    websockInit

    --r <- getWith opts gatewayURL
    --let responseText = r ^. responseBody
    --    murl = join $ M.lookup "url" <$> (decode responseText :: Maybe (Map String String))

    --maybe (return()) websockInit murl
