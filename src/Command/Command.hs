{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances, FunctionalDependencies,
   UndecidableInstances, MultiParamTypeClasses #-}
{-|
Module      : Command.Command
License     : BSD (see the LICENSE file)
Description : Everything commands :)

Amateur attempt at command abstraction and polyvariadic magic.

Inspired heavily but calamity-commands, which is provided by Ben Simms 2020
under the MIT license. 

Notable extensions used:

    * ScopedTypeVariables: For using the same type variables in `where'
    statements as function declarations
    * FlexibleInstances: To allow arbitrary nested types in instance
    declarations
    * MultiParamTypeClasses: For declaring CommandHandlerType that has 2 params
    * FunctionalDependencies: To write that @m@ can be determined from @h@.
    * UndecidableInstances: Risky, but I think I logically checked over it.
    [See more](https://www.reddit.com/r/haskell/comments/5zjwym/when_is_undecidableinstances_okay_to_use/)
-}
module Command.Command
    ( -- * The fundamentals
    -- | These offer the core functionality for Commands. The most imporatnt
    -- functions are 'command' and 'runCommand', which create a 'Command' and
    -- convert the 'Command' to a receiver, respectively.
    --
    -- There are several functions that can be composed onto 'command', such as
    -- 'help' (overwrite the help message), 'onError' (overwrite the error 
    -- handler), or 'requires' (add a requirement for the command).
    Command
    , command
    , runCommand
    , help
    , onError
    , defaultErrorHandler
    , requires
    -- * Parsing arguments
    -- | The 'ParsableArgument' is the core dataclass for command arguments that
    -- can be parsed. Some special types are added to create functionality
    -- that is unrepresentable in existing Haskell datatypes.
    --
    -- As an OwenDev, if you want to make your own datatype parsable, all you
    -- have to do is to add an instance declaration for it (and a parser) inside
    -- @Command/Parser.hs@. Parsec offers very very very useful functions that
    -- you can simply compose together to create parsers.
    , ParsableArgument
    , RemainingText(..)
    -- * The MonadDiscord type
    -- | MonadDiscord is the underlying Monad class for all interactions to the
    -- Discord REST API. The abstraction makes for great polymorphic receivers
    -- that are easier to test and run from various contexts.
    , module Discord.Monad
    ) where

import           Control.Applicative        ( Alternative )
import           Control.Exception.Safe     ( catch
                                            , throwM
                                            , MonadCatch
                                            , MonadThrow
                                            , Exception
                                            , SomeException
                                            )
import           Control.Monad.IO.Class     ( MonadIO )
import           Control.Monad              ( void
                                            , guard
                                            )
import qualified Data.Text as T
import           Text.Parsec.Error          ( errorMessages
                                            , showErrorMessages
                                            )
import           Text.Parsec.Combinator
import qualified Text.Parsec.Text as T
import           Text.Parsec                ( runParser
                                            , eof
                                            , ParseError
                                            , space
                                            , anyChar
                                            , char
                                            , (<|>)
                                            )
import           UnliftIO                   ( liftIO )

import           Discord.Monad
import           Discord.Types
import           Discord

import           Command.Error              ( CommandError(..) )
import           Command.Parser             ( ParsableArgument(..)
                                            , RemainingText(..)
                                            , manyTill1
                                            )
import           Owoifier                   ( owoify )


-- | A @Command@ is a datatype containing the metadata for a user-registered
-- command. 
--
-- @Command m h@ is a command that runs in the monad @m@, which when called
-- will trigger the polyvariadic handler function @h@. The handler @h@ *must*
-- be in the @m@ monad, else your type-checker will complain.
--
-- The contents of this abstract datatype are not exported from this module for
-- encapsulation. Use 'command' to instantiate one.
data Command m h = Command
    { commandName         :: T.Text
    -- ^ The name of the command.
    , commandHandler      :: h
    -- ^ The polyvariadic handler function for the command. All of its argument
    -- types must be of 'ParsableArgument'. Its return type after applying all
    -- the arguments must be @m ()@. These are enforced by the type-checker.
    , commandArgApplier   :: Message -> T.Text -> h -> m ()
    -- ^ The function used to apply the arguments into the @commandHandler@. It
    -- needs to take a 'Message' that triggered the command, the name of the
    -- command, the handler, and the return monad.
    , commandErrorHandler :: Message -> CommandError -> m ()
    -- ^ The function called when a 'CommandError' is raised during the handling
    -- of a command.
    , commandHelp         :: T.Text
    -- ^ The help for this command.
    , commandRequires     :: [Message -> Either T.Text ()]
    -- ^ A list of requirements that need to pass ('Right') for the command to
    -- be processed.
    }


-- | @command name handler@ creates a 'Command' named @name@, which upon
-- receiving a message will call @handler@. @name@ cannot contain any spaces,
-- as it breaks the parser. The @handler@ function can take an arbitrary amount
-- of arguments of arbitrary types (it is polyvariadic), as long as they are
-- instances of 'ParsableArgument'.
--
-- The Command that this function creates is polymorphic in the Monad it is run
-- in. This means you can call it from 'DiscordHandler' or 'IO', or any mock
-- monads in tests (as long as they are instances of 'MonadDiscord')
-- 
-- @
-- pong :: (MonadDiscord m) => Command m (Message -> m ())
-- pong = command "ping" $ \\msg -> respond msg "pong!"
-- @
-- 
-- @
-- lePong :: (MonadDiscord m) => Message -> m ()
-- lePong = runCommand $
--     command "ping" $ \\msg -> respond msg "pong!"
-- @
--
-- @
-- weather :: (MonadDiscord m) => Command m (Message -> T.Text -> m ())
-- weather = command "weather" $ \\msg location -> do
--     result <- liftIO $ getWeather location
--     respond msg $ "Weather at " <> location <> " is " <> result <> "!"
-- @
--
-- @
-- complex :: (MonadDiscord m) => Command m (Message -> Int -> ConfigKey -> m ())
-- complex = command "complexExample" $ \\msg i key -> do
--     ...
-- @
--
-- The type signature of the return type can become quite long depending on how
-- many arguments @handler@ takes (as seen above). Thanks to the
-- @FunctionalDependencies@ and @UndecidableInstances@ extensions that are used
-- in the Commands library (you don't have to worry about them), they can be
-- inferred most of the time. It may be kept for legibility. As an OwenDev,
-- there are no extensions you need to enable in the receiver modules.
--
-- (yeah, they're wicked extensions that *could* cause harm, but in this case
-- (I hope) I've used them appropriately and as intended.)
command
    :: (CommandHandlerType m h , MonadDiscord m)
    => T.Text
    -- ^ The name of the command.
    -> h
    -- ^ The handler for the command, that takes an arbitrary amount of
    -- 'ParsableArgument's and returns a @m ()@
    -> Command m h
command name handler = Command
    { commandName         = name
    , commandHandler      = handler
    , commandArgApplier   = applyArgs
    , commandErrorHandler = defaultErrorHandler
    , commandHelp         = "Help not available."
    , commandRequires     = []
    }

-- | @onError@ overwrites the default error handler of a command with a custom
-- implementation.
--
-- @
-- example
--     = onError (\\msg e -> respond msg (T.pack $ show e)
--     . command "example" $ do
--         ...
-- @
onError
    :: (Message -> CommandError -> m ())
    -- ^ Error handler that takes the original message that caused the error,
    -- and the error itself. It runs in the same monad as the command handlers.
    -> Command m h
    -> Command m h
onError errorHandler cmd = cmd
    { commandErrorHandler = errorHandler
    }

-- | @requires@ adds a requirement to the command. The requirement is a function
-- that takes a 'Message' and either returns @'Right' ()@ (no problem) or
-- @'Left' "explanation"@. 
--
-- Commands default to having no requirements.
--
-- TODO: maybe change from 'Either' to 'Maybe'?
requires :: (Message -> Either T.Text ()) -> Command m h -> Command m h
requires requirement cmd = cmd
    { commandRequires = requirement : commandRequires cmd
    }

-- | @help@ sets the help message for the command. The default is "Help not
-- available."
help :: T.Text -> Command m h -> Command m h
help newHelp cmd = cmd
    { commandHelp = newHelp
    }

-- | @runCommand command msg@ attempts to run the specified 'Command' with the
-- given message. It checks the command name, applies/parses the arguments, and
-- catches any errors.
--
-- @
-- runCommand pong :: (Message -> m ())
-- @
runCommand
    :: forall m h.
    (MonadDiscord m, Alternative m)
    => Command m h
    -- ^ The command to run against.
    -> Message
    -- ^ The message to run the command with.
    -> m ()
runCommand command msg =
    -- First check that the command name is right.
    case runParser (parseCommandName command) () "" (messageText msg) of
        Left e -> pure ()
        Right args -> do
            -- Apply the arguments one by one on the appropriate handler
            ((commandArgApplier command) msg args (commandHandler command))
                -- Asynchrnous errors are not caught as the `catch` comes from
                -- Control.Exception.Safe.
                `catch` basicErrorCatcher
                `catch` allErrorCatcher
  where
    -- | Catch CommandErrors and handle them with the handler
    basicErrorCatcher :: CommandError -> m ()
    basicErrorCatcher = (commandErrorHandler command) msg

    -- | Catch any and all errors, including ones thrown in basicErrorCatcher.
    allErrorCatcher :: SomeException -> m ()
    allErrorCatcher = ((commandErrorHandler command) msg) . HaskellError






-- | @defaultErrorHandler m e@ is the default error handler unless you override
-- it manually. This is exported and documented for reference only.
--
-- [On argument error] It calls 'respond' with the errors, owoified.
-- [On requirement error] It sends a DM to the invoking user with the errors.
-- [On a processing error] It calls 'respond' with the error.
-- [On a Discord error] If a Discord request failed, it's likely that the bot
-- would not be able to respond, so the error is put to stdout.
-- [On a Runtime/Haskell error] It calls 'respond' with the error, owoified.
defaultErrorHandler
    :: (MonadDiscord m)
    => Message
    -> CommandError
    -> m ()
defaultErrorHandler m e =
    case e of
        ArgumentParseError x ->
            respond m $ owoify $ T.pack $ showWithoutPos x
        RequirementError x -> do
            chan <- createDM (userId $ messageAuthor m)
            void $ createMessage (channelId chan) x
        ProcessingError x ->
            respond m x
        DiscordError x ->
            liftIO $ putStrLn $ "Discord responded with a " <> (show x)
        HaskellError x ->
            respond m (owoify $ T.pack $ show x)
  where
    -- The default 'Show' instance for ParseError contains the error position,
    -- which only adds clutter in a Discord message. This defines a much
    -- simpler string representation.
    showWithoutPos :: ParseError -> String
    showWithoutPos err = showErrorMessages "or" "unknown parse error"
        "expecting" "unexpected" "end of input" (errorMessages err)







-- @CommandHandlerType@ is a dataclass for all types of arguments that a
-- command handler may have. Its only function is @applyArgs@.
class (MonadThrow m) => CommandHandlerType m h | h -> m where
    applyArgs
        :: Message
        -- ^ The relevant message.
        -> T.Text
        -- ^ The arguments of the command, i.e. everything after the command
        -- name followed by one or more spaces. Is "" if empty.
        -> h
        -- ^ The handler. It must be in the same monad as @m@.
        -> m ()
        -- ^ The monad to run the handler in, and to throw parse errors in.

-- | For the case when all arguments have been applied. Base case.
instance (MonadThrow m) => CommandHandlerType m (m ()) where
    applyArgs msg input handler = 
        case runParser eof () "" input of
            Left e -> throwM $ ArgumentParseError e
            Right _ -> handler

-- | For the case where there are multiple arguments to apply. 
instance (MonadThrow m, ParsableArgument a, CommandHandlerType m b) => CommandHandlerType m (a -> b) where
    applyArgs msg input handler =
        case runParser (parserForArg msg) () "" input of
            Left e -> throwM $ ArgumentParseError e
            Right (x, remaining) -> applyArgs msg remaining (handler x) 

-- | For the case where there is only one argument to apply.
-- It overlaps the previous instance (it is more specific). With the OVERLAPPING
-- pragma, GHC prefers this one when both match.
--
-- This instance is necessary because otherwise @Message -> m ()@ will match
-- both @m ()@ (@(->) r@ is a monad) and @a -> b@ and since neither are more
-- specific, GHC cannot prefer one over the other, even with any pragmas.
instance {-# OVERLAPPING #-} (MonadThrow m, ParsableArgument a) => CommandHandlerType m (a -> m ()) where
    applyArgs msg input handler =
        case runParser (parserForArg msg) () "" input of
            Left e -> throwM $ ArgumentParseError e
            Right (x, remaining) -> applyArgs msg remaining (handler x)

-- | @parseCommandName@ returns a parser that tries to consume the prefix,
-- Command name, appropriate amount of spaces, and returns the arguments.
-- If there are no arguments, it will return the empty text, "".
parseCommandName :: Command m h -> T.Parser T.Text
parseCommandName cmd = do
    -- consume prefix
    char ':'
    -- consume at least 1 character until a space is encountered
    -- don't consume the space
    cmdName <- manyTill1 anyChar (void (lookAhead space) <|> eof)
    -- check it's the proper command
    guard (T.pack cmdName == commandName cmd)
    -- parse either an end of input, or spaces followed by arguments
    (eof >> pure "") <|> do
        -- consumes one or more isSpace characters
        many1 space
        -- consume everything until end of input
        args <- manyTill anyChar eof
        -- return the args
        pure (T.pack args)
