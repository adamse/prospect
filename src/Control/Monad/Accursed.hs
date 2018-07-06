{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}

module Control.Monad.Accursed
  ( -- * Core type
    Accursed (..)
  , unholyPact
  , UnholyPact (..)

  -- * Analyzing 'Accursed'
  , channel
  , analyze
  , runAccursed

  -- * Conversions from 'F.Free'
  , corrupt
  , improve

  -- * 'F.Free' compatible interface
  , retract
  , F.liftF
  , iter
  , iterA
  , iterM
  , hoistAccursed
  , foldAccursed
  ) where

import           Control.Applicative (Alternative (..))
import           Control.Exception (Exception, throw, catch)
import           Control.Monad.Codensity (lowerCodensity)
import qualified Control.Monad.Free as F
import           Control.Monad.Trans.Class (MonadTrans (..))
import           Control.Monad.Trans.Maybe (runMaybeT)
import           Control.Monad.Writer.Strict (runWriter, tell)
import           GHC.Generics
import           GHC.TypeLits
import           System.IO.Unsafe (unsafePerformIO)



------------------------------------------------------------------------------
-- | The 'Accursed' monad in which evaluation of 'unholyPact' will be
-- interpreted as 'empty' at the time it happens. Under very specific
-- circumstances, this allows some degree of static analysis over free monads.
-- The rest of the time it will lead to terror, madness and runtime crashes.
data Accursed f a
  = Pure a
  | Free (f (Accursed f a))
  | Empty
  deriving (Generic, Generic1)

instance Functor f => Functor (Accursed f) where
  fmap f (Pure a)  = unsafePerformIO $
    catch
      (let !_ = a
        in pure $ Pure $ f a)
      (\(_ :: UnholyPact) -> pure Empty)
  fmap f (Free fa) = Free (fmap f <$> fa)
  fmap _ Empty     = Empty
  {-# INLINE fmap #-}

instance Functor f => Applicative (Accursed f) where
  pure = Pure
  {-# INLINE pure #-}
  Empty  <*> _ = Empty
  Pure a <*> Pure b = unsafePerformIO $
    catch
      (let !_ = a
           !_ = b
        in pure $ Pure $ a b)
      (\(_ :: UnholyPact) -> pure Empty)
  Pure a <*> Free mb = unsafePerformIO $
    catch
      (let !_ = a
           !_ = mb
        in pure $ Free $ fmap a <$> mb)
      (\(_ :: UnholyPact) -> pure Empty)
  Free ma <*> b = unsafePerformIO $
    catch
      (let !_ = ma
           !_ = b
        in pure $ Free $ (<*> b) <$> ma)
      (\(_ :: UnholyPact) -> pure Empty)
  _ <*> Empty = Empty
  {-# INLINE (<*>) #-}

instance Functor f => Monad (Accursed f) where
  return = pure
  {-# INLINE return #-}
  Pure a >>= f = f a
  Free m >>= f = unsafePerformIO $
    catch
      (let !_ = m
        in pure $ Free ((>>= f) <$> m))
      (\(_ :: UnholyPact) -> pure Empty)
  Empty >>= _ = Empty
  {-# INLINE (>>=) #-}

instance Functor f => Alternative (Accursed f) where
  empty = Empty
  Empty <|> a = a
  a     <|> _ = a

instance MonadTrans Accursed where
  lift f = Free $ fmap pure f

instance Functor f => F.MonadFree f (Accursed f) where
  wrap = Free


------------------------------------------------------------------------------
-- | Improve the asymptotics of building an 'Accursed'.
improve
    :: Functor f
    => (forall m. (F.MonadFree f m, Alternative m) => m a)
    -> Accursed f a
improve = lowerCodensity


------------------------------------------------------------------------------
-- | Lift a natural transformation from 'f' to 'g' over 'Accursed'.
hoistAccursed
    :: Functor g
    => (forall x. f x -> g x)
    -> Accursed f a
    -> Accursed g a
hoistAccursed _ (Pure a) = Pure a
hoistAccursed n (Free f) = Free $ fmap (hoistAccursed n) $ n f
hoistAccursed _ Empty    = Empty


------------------------------------------------------------------------------
-- | Perform a best-effort analysis of a free monad.
analyze
    :: Functor f
    => (forall b. f (Accursed f b) -> Accursed f b)
       -- ^ The following function. Consider using 'channel' to get an
       -- automatic implementation for this.
    -> Accursed f a
    -> (Maybe a, [f ()])
analyze c = runWriter . runMaybeT . go
  where
    go Empty = empty
    go (Pure a) = unsafePerformIO $
      catch
        (let !_ = a
          in pure $ pure a)
        (\(_ :: UnholyPact) -> pure empty)
    go (Free f) = do
      tell . pure $ () <$ f
      unsafePerformIO $
        catch
          ( let !z = c f
             in pure $ go z)
          (\(_ :: UnholyPact) -> pure empty)
    {-# INLINE go #-}


------------------------------------------------------------------------------
-- | Tear down an 'Accursed' by way of 'channel'.
runAccursed
    :: (Functor f, Generic1 f, GChannel f (Rep1 f))
    => Accursed f a
    -> (Maybe a, [f ()])
runAccursed = analyze channel


------------------------------------------------------------------------------
-- |
-- 'retract' is the left inverse of 'lift' and 'liftF'
--
-- @
-- 'retract' . 'lift' = 'id'
-- 'retract' . 'liftF' = 'id'
-- @
retract :: (Monad f, Alternative f) => Accursed f a -> f a
retract (Pure a)  = return a
retract (Free as) = as >>= retract
retract Empty     = empty


--------------------------------------------------------------------------------
-- | Tear down an 'Accursed' using iteration.
iter :: Functor f => (f (Maybe a) -> Maybe a) -> Accursed f a -> Maybe a
iter phi = go
  where
    go (Pure a) = Just a
    go (Free m) = phi (go <$> m)
    go Empty    = Nothing


--------------------------------------------------------------------------------
-- | Like 'iter' for applicative values.
iterA
    :: (Applicative p, Alternative p, Functor f)
    => (f (p a) -> p a)
    -> Accursed f a
    -> p a
iterA _   (Pure x) = pure x
iterA phi (Free f) = phi (iterA phi <$> f)
iterA _ Empty      = empty


--------------------------------------------------------------------------------
-- | Like 'iter' for monadic values.
iterM :: (Monad m, Alternative m, Functor f)
      => (f (m a) -> m a)
      -> Accursed f a
      -> m a
iterM _   (Pure x) = return x
iterM phi (Free f) = phi (iterM phi <$> f)
iterM _ Empty      = empty


------------------------------------------------------------------------------
-- | A 'Monad' homomorphism over 'Accursed'.
foldAccursed
    :: (Monad m, Alternative m)
    => (forall x . f x -> m x)
    -> Accursed f a
    -> m a
foldAccursed _ (Pure a)  = return a
foldAccursed f (Free as) = f as >>= foldAccursed f
foldAccursed _ Empty     = empty


------------------------------------------------------------------------------
-- | The underlying machinery of 'unholyPact'.
data UnholyPact = UnholyPact
  deriving (Show, Eq)
instance Exception UnholyPact


------------------------------------------------------------------------------
-- | An 'unholyPact' is tretchery whose evaluation can be caught in the
-- 'Accursed' monad. It can be used to follow continuations in a free monad
-- until it branches.
unholyPact :: Functor f => Accursed f a
unholyPact = pure $ throw UnholyPact


------------------------------------------------------------------------------
-- | Convert a 'F.Free' monad into an 'Accursed' monad.
corrupt
    :: Functor f
    => F.Free f a
    -> Accursed f a
corrupt (F.Pure a) = Pure a
corrupt (F.Free f) = Free $ fmap corrupt f


------------------------------------------------------------------------------
-- | Helper class to derive 'channel' generically.
class GChannel p f where
  gchannel :: f (Accursed p b) -> Accursed p b

instance TypeError
    (  'Text "Missing continuation parameter when attempting to derive 'channel'"
 ':$$: 'Text "Expected a type variable, but got "
 ':<>: 'ShowType a
    )
      => GChannel p (K1 _1 a) where
  gchannel = undefined
  {-# INLINE gchannel #-}

instance {-# OVERLAPPING #-} TypeError
    (  'Text "Missing continuation parameter when attempting to derive 'channel'"
 ':$$: 'Text "Expected a type variable, but the constructor '"
 ':<>: 'Text tyConName
 ':<>: 'Text "' has none"
    )
      => GChannel p (C1 ('MetaCons tyConName _b _c) U1) where
  gchannel = undefined
  {-# INLINE gchannel #-}

instance GChannel p V1 where
  gchannel _ = undefined
  {-# INLINE gchannel #-}

instance Functor p => GChannel p (Rec1 ((->) a)) where
  gchannel (Rec1 z) = do
    c <- unholyPact
    z c
  {-# INLINE gchannel #-}

instance GChannel p Par1 where
  gchannel (Par1 z) = z
  {-# INLINE gchannel #-}

instance GChannel p g => GChannel p (f :*: g) where
  gchannel (_ :*: b) = gchannel b
  {-# INLINE gchannel #-}

instance (GChannel p f, GChannel p g) => GChannel p (f :+: g) where
  gchannel (L1 f) = gchannel f
  gchannel (R1 g) = gchannel g
  {-# INLINE gchannel #-}

instance GChannel p f => GChannel p (M1 _1 _2 f) where
  gchannel (M1 f) = gchannel f
  {-# INLINE gchannel #-}


------------------------------------------------------------------------------
-- | Generically derived continuation follower; intended to be used as the
-- first parameter for 'analyze'.
channel
    :: (Generic1 f, GChannel f (Rep1 f))
    => f (Accursed f a)
    -> Accursed f a
channel = gchannel . from1
{-# INLINE channel #-}


