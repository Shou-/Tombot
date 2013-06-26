
-- This file is part of Tombot, licensed under the GNU GPL 2 license.
-- See the file "LICENSE" for more information.
-- Copyright Shou, 2013

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Main where


-- {{{ Imports
import Config
import Tombot.Bot
import Tombot.IRC
import Tombot.Types
import Tombot.Utils

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad.State

import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.IO as T

import System.IO
-- }}}

-- XXX
-- - We are going to rename the bot?
--      - A name without `bot' in it.
-- - Store data as pure Haskell code in files, specifically for the Funcs.
--      - This means we don't need to make parsers and whatnot, we already have
--        GHC for that through Language.Haskell.Interpreter.
--      - There are no drawbacks other than requiring GHC to be installed, I
--        think?
--      - We can store functions there as well, which is great.
-- - Look for patterns and repetitions and make generic functions.
-- - Keeping file descriptors/handles/sockets
--      - Ok, the basic approach is that fork() (the C call) doesn't close file
--        descriptors. If you turn all the Handles into System.Posix.Types.Fd
--        then you can fork a new instance of your program (using new code),
--        exec the new binary of your program, open up a unix socket in the old
--        parent and in the newly exec'ed binary, write all the values of the
--        Fd's to the socket, and then convert the Fd's back into Handles in
--        your new.
--        I'm not sure whether it'd be easier to do this in Haskell or a mix of
--        C and Haskell, but it should be possible like that.
--        Lots of old school MUDs (Multi User Dungeon, basically text-based
--        multiplayer RPGS) had "hot copy-over" where they'd run an updated
--        version of their server by using tricks like these to prevent the
--        connection from dropping googling for mud and "copy-over" should find
--        some relevant results.

-- TODO
-- - Functions
--      - About
--      - .r or .reload for reloading modules.
-- - Rejoin on Handle error
--      - Search for hPutStr and the likes
--      - Close Handles on reconnection.
--          - Make sure no Handle errors/reconnects are mistaken, such as the
--            reconnect loop one because two Eithers were joined.
-- - Add quit and part messages to config data
-- - Personality/mood
-- - Run anything the bot writes through the parser. Or at least user commands.
--      - This means changes are made when the bot does something, such as NICK
--      - We've already set the bot up to be able to do this! `respond'!
-- - Message spam limit.
--      - Make a function that can only write 480 bytes of text to a Handle.
--      - Only n messages per m seconds.
--          - 5 messages per 3 seconds, drop everything after.
-- - Save lines to a file.
--      - This will allow users to do something like:
--        :on /abc(d)/ :load file -> ra
--          - This also means we have to replace the matches (\1, \2, ...)
--            AFTER, not before, we've compiled the kawaiilang.
--      - How to delete?
-- - Deprecate the Config import, instead opting for plaintext and/or command
--   line arguments and shape Config from that.
-- - Kanji lookup function
-- - Channel white/blacklisting
-- - Counter function.
--      - Timeout between uses.
--      - `counter <string>` ups the counter
-- - Nick and hostname must match for privileges to be gained.
--      - Use WHOIS for people in the UserStat file and check against their
--        host.
-- - WolframAlpha
-- - wwwjdic
-- - Monoids!!!!
--      - mFromLeft, mFromRight, mFromJust, ...

-- FIXME
-- - handle Handle errors and rejoin.
-- - Add/modify channels on join
--      - Default Channel funcs.
--          - We don't want her to be completely useless in a channel, but no
--            dangerous funcs either; specifically network ones.
-- - Load UserStat from file.
--      - Now we just need to be able to set it somewhere.
-- - Make a function `adapt' that takes a nick and a channel and does its magic
--      - Just be careful not to use the wrong adapt somewhere, like on KICK or
--        QUIT
-- - Taken NICK isn't working properly.
-- - Empty channel name might be inserted on NICK or QUIT.
-- - User status will be Online if the User PARTs from all channels the bot is
--   in and then quitting.
-- - Reverse pipe is not working because of bug in `compile'.
--      - Rewrite it and use StateT
-- - Case insensitive name matching.
--      - Specifically on tells and reminders.

-- REVIEW
-- - Keep track of UserStat
-- - Logging
-- - Privilege system
--      - Review the functions


main :: IO ()
main = do
    configt <- newTMVarIO $ toStConf config
    forM_ servers $ \server -> forkIO $ initialise configt server
    userInput configt

-- | Direct input
userInput :: TMVar StConfig -> IO ()
userInput ct = loop $ do
    line <- liftIO T.getLine
    let (server, rest) = bisect (== ' ') line
        (chan, mesg) = bisect (== ' ') rest
    servs <- fmap stConfServs . liftIO . atomically $ readTMVar ct
    let mserv = M.lookup (T.unpack server) servs
    when (mserv /= Nothing) $ put mserv
    let message = maybe rest (const mesg) mserv
        channel = maybe server (const chan) mserv
    ms <- get
    flip (maybe $ return ()) ms $ \st -> void . liftIO . flip runStateT st $ do
        let irc = Privmsg "Tombot" "" "" channel message
        adaptPriv irc
        let user = User "Tombot" "Tombot" "botnet.fbi.gov" Root M.empty
        sets $ \c -> c { currUser = user }
        runLang irc
  where
    loop :: StateT (Maybe (TMVar Current)) IO () -> IO ()
    loop m = void . flip runStateT Nothing $ forever $ m

