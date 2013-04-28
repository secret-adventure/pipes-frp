{-# LANGUAGE PolymorphicComponents #-}

module Control.Proxy.FRP (
   Event(..)
   ) where

import Control.Applicative
import Control.Concurrent.Async
import Control.Proxy
import Control.Proxy.Concurrent
import Control.Proxy.Trans.State

data Event a = Event
    { runEvent :: forall p . (Proxy p) => () -> Producer p a IO () }

instance Functor Event where
    fmap f (Event p) = Event (p >-> mapD f)

instance Applicative Event where
    pure a = Event $ \() -> respond a

    (Event fp) <*> (Event xp)
        = Event $ \() -> runIdentityP $ do
            (input, output) <- lift $ spawn Unbounded
            lift $ do
                a1 <- async $ runProxy $
                    fp >-> mapD Left  >-> sendD input
                a2 <- async $ runProxy $
                    xp >-> mapD Right >-> sendD input
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
