{-# LANGUAGE PolymorphicComponents #-}

module Control.Proxy.FRP (
   Event(..),
   Behavior(..),
   behave,
   filter,
   mapMaybe,
   runIO,
   fromIO
   ) where

import           Prelude                   hiding (filter)

import           Control.Applicative
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Proxy
import           Control.Proxy.Concurrent
import           Control.Proxy.Trans.State

import           Data.Functor.Compose
import           Data.Maybe                (fromJust, isJust)

newtype Event a = Event
    { runEvent :: forall p . (Proxy p) => () -> Producer p a IO () }

instance Functor Event where
    fmap f (Event p) = Event (p >-> mapD f)

instance Applicative Event where
    pure a    = Event $ \() -> respond a
    fe <*> xe = Event $ \() -> runIdentityP $ do
        (input, output) <- lift $ spawn Unbounded
        lift $ do
            a1 <- async $ runProxy $
                runEvent fe >-> mapD Left  >-> sendD input
            a2 <- async $ runProxy $
                runEvent xe >-> mapD Right >-> sendD input
            link2 a1 a2
            link a1
        (recvS output >-> handler) ()
      where
        handler () = evalStateP (Nothing, Nothing) $ forever $ do
            e <- request ()
            (mf, mx) <- get
            case e of
                Left  f -> do
                    let mf' = Just f
                    put (mf', mx)
                    case (mf' <*> mx) of
                        Nothing -> return ()
                        Just fx -> respond fx
                Right x -> do
                    let mx' = Just x
                    put (mf, mx')
                    case (mf <*> mx') of
                        Nothing -> return ()
                        Just fx -> respond fx

instance Alternative Event where
    empty     = Event $ \() -> runIdentityP $ return ()
    e1 <|> e2 = Event $ \() -> runIdentityP $ do
        (input, output) <- lift $ spawn Unbounded
        lift $ do
            a1 <- async $ runProxy $ runEvent e1 >-> sendD input
            a2 <- async $ runProxy $ runEvent e2 >-> sendD input
            link2 a1 a2
            link  a1
        recvS output ()

-- TODO: Does this function make any sense to include? I honestly
--       don't know.
-- | Runs each IO action from the event.
runIO :: (Event (IO ())) -> IO ()
runIO (Event proxy) = runProxy $ proxy >-> \ () -> request () >>= lift

-- | Create a stream of events by repeating a given IO a action.
fromIO :: IO a -> Event a
fromIO action = Event $ \ () -> runIdentityP . forever $ lift action >>= respond

-- TODO: Should this be called something like filterE? We could 
-- also just expect people to import this library qualified.
-- JF.  I vote for qualified approach
-- | Supresses events that do not match the given predicate.
filter :: (a -> Bool) -> Event a -> Event a
filter predicate (Event producer) = Event $ producer >-> filterD predicate

-- | Map an event, throwing out any values mapped to Nothing.
mapMaybe :: (a -> Maybe b) -> Event a -> Event b
mapMaybe fn = fmap fromJust . filter isJust . fmap fn

newtype Behavior a = Behavior { runBehavior :: IO (STM a) }

instance Functor Behavior where
    fmap f = Behavior . getCompose . fmap f . Compose . runBehavior

instance Applicative Behavior where
    pure = Behavior . getCompose . pure
    fb <*> xb = Behavior . getCompose $
        Compose (runBehavior fb) <*> Compose (runBehavior xb)

behave :: a -> Event a -> Behavior a
behave start e = Behavior $ do
    tvar <- newTVarIO start
    let toTVar () = runIdentityP $ forever $ do
            x <- request ()
            lift $ atomically $ writeTVar tvar x
    a <- async $ runProxy $ runEvent e >-> toTVar
    link a
    return (readTVar tvar)
