{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE CPP #-}
-- | Utilities for constructing and covnerting conduits. Please see
-- "Data.Conduit.Types.Conduit" for more information on the base types.
module Data.Conduit.Util.Conduit
    ( haveMore
    , conduitState
    , ConduitStateResult (..)
    , conduitIO
    , ConduitIOResult (..)
    , transConduit
    , conduitClose
      -- *** Sequencing
    , SequencedSink
    , sequenceSink
    , sequence
    , SequencedSinkResponse (..)
    ) where

import Prelude hiding (sequence)
import Control.Monad.Trans.Resource
import Data.Conduit.Types.Conduit
import Data.Conduit.Types.Sink
import Data.Conduit.Types.Source
import Data.Conduit.Util.Source
import Data.Conduit.Util.Sink
import Control.Monad (liftM)
import Data.Monoid (mempty)

-- | A helper function for returning a list of values from a @Conduit@.
--
-- Since 0.3.0
haveMore :: Conduit a m b -- ^ The next @Conduit@ to return after the list has been exhausted.
         -> m () -- ^ A close action for early termination.
         -> [b] -- ^ The values to send down the stream.
         -> Conduit a m b
haveMore res _ [] = res
haveMore res close (x:xs) = HaveOutput (haveMore res close xs) close x

-- | A helper type for @conduitState@, indicating the result of being pushed
-- to.  It can either indicate that processing is done, or to continue with the
-- updated state.
--
-- Since 0.3.0
data ConduitStateResult state input output =
    StateFinished (Maybe input) [output]
  | StateProducing state [output]

instance Functor (ConduitStateResult state input) where
    fmap f (StateFinished a b) = StateFinished a (map f b)
    fmap f (StateProducing a b) = StateProducing a (map f b)

-- | Construct a 'Conduit' with some stateful functions. This function addresses
-- threading the state value for you.
--
-- Since 0.3.0
conduitState
    :: Monad m
    => state -- ^ initial state
    -> (state -> input -> m (ConduitStateResult state input output)) -- ^ Push function.
    -> (state -> m [output]) -- ^ Close function. The state need not be returned, since it will not be used again.
    -> Conduit input m output
conduitState state0 push0 close0 =
    NeedInput (push state0) (close state0)
  where
    push state input = ConduitM (liftM goRes' $ state `seq` push0 state input) (return ())

    close state = SourceM (do
        os <- close0 state
        return $ fromList os) (return ())

    goRes' (StateFinished leftover output) = haveMore
        (Finished leftover)
        (return ())
        output
    goRes' (StateProducing state output) = haveMore
        (NeedInput (push state) (close state))
        (return ())
        output

-- | A helper type for @conduitIO@, indicating the result of being pushed to.
-- It can either indicate that processing is done, or to continue.
--
-- Since 0.3.0
data ConduitIOResult input output =
    IOFinished (Maybe input) [output]
  | IOProducing [output]

instance Functor (ConduitIOResult input) where
    fmap f (IOFinished a b) = IOFinished a (map f b)
    fmap f (IOProducing b) = IOProducing (map f b)

-- | Construct a 'Conduit'.
--
-- Since 0.3.0
conduitIO :: MonadResource m
           => IO state -- ^ resource and/or state allocation
           -> (state -> IO ()) -- ^ resource and/or state cleanup
           -> (state -> input -> m (ConduitIOResult input output)) -- ^ Push function. Note that this need not explicitly perform any cleanup.
           -> (state -> m [output]) -- ^ Close function. Note that this need not explicitly perform any cleanup.
           -> Conduit input m output
conduitIO alloc cleanup push0 close0 = NeedInput
    (\input -> flip ConduitM (return ()) $ do
        (key, state) <- allocate alloc cleanup
        push key state input)
    (SourceM (do
        (key, state) <- allocate alloc cleanup
        os <- close0 state
        release key
        return $ fromList os) (return ()))
  where
    push key state input = do
        res <- push0 state input
        case res of
            IOProducing output -> return $ haveMore
                (NeedInput (flip ConduitM (release key) . push key state) (close key state))
                (release key >> return ())
                output
            IOFinished leftover output -> do
                release key
                return $ haveMore
                    (Finished leftover)
                    (return ())
                    output

    close key state = SourceM (do
        output <- close0 state
        release key
        return $ fromList output) (release key)

fromList :: Monad m => [a] -> Source m a
fromList [] = Closed
fromList (x:xs) = Open (fromList xs) (return ()) x

-- | Transform the monad a 'Conduit' lives in.
--
-- See @transSource@ for more information.
--
-- Since 0.3.0
transConduit :: Monad m
             => (forall a. m a -> n a)
             -> Conduit input m output
             -> Conduit input n output
transConduit _ (Finished a) = Finished a
transConduit f (NeedInput push close) = NeedInput
    (transConduit f . push)
    (transSource f close)
transConduit f (HaveOutput pull close output) = HaveOutput
    (transConduit f pull)
    (f close)
    output
transConduit f (ConduitM mcon close) = ConduitM (f (liftM (transConduit f) mcon)) (f close)

-- | Return value from a 'SequencedSink'.
--
-- Since 0.3.0
data SequencedSinkResponse state input m output =
    Emit state [output] -- ^ Set a new state, and emit some new output.
  | Stop -- ^ End the conduit.
  | StartConduit (Conduit input m output) -- ^ Pass control to a new conduit.

-- | Helper type for constructing a @Conduit@ based on @Sink@s. This allows you
-- to write higher-level code that takes advantage of existing conduits and
-- sinks, and leverages a sink's monadic interface.
--
-- Since 0.3.0
type SequencedSink state input m output =
    state -> Sink input m (SequencedSinkResponse state input m output)

-- | Convert a 'SequencedSink' into a 'Conduit'.
--
-- Since 0.3.0
sequenceSink
    :: Monad m
    => state -- ^ initial state
    -> SequencedSink state input m output
    -> Conduit input m output
sequenceSink state0 fsink = NeedInput (scPush fsink $ fsink state0) mempty -- FIXME investigate if we can bypass getting input

scPush :: Monad m
       => SequencedSink state input m output
       -> Sink input m (SequencedSinkResponse state input m output)
       -> ConduitPush input m output
scPush fsink (Processing pushI _) input = scGoRes fsink $ pushI input
scPush fsink (Done Nothing res) input = scGoRes fsink (Done (Just input) res)
scPush _ (Done Just{} _) _ = error "Invariant violated: Sink returned leftover without input"
scPush fsink (SinkM msink) input = ConduitM (liftM (\sink -> scPush fsink sink input) msink) (msink >>= sinkClose)

scGoRes :: Monad m
        => SequencedSink state input m output
        -> Sink input m (SequencedSinkResponse state input m output)
        -> Conduit input m output
scGoRes fsink (Done (Just leftover) (Emit state os)) = haveMore
    (scPush fsink (fsink state) leftover)
    (return ())
    os
scGoRes fsink (Done Nothing (Emit state os)) = haveMore
    (NeedInput p c)
    (return ())
    os
  where
    NeedInput p c = sequenceSink state fsink -- FIXME
scGoRes fsink (Processing pushI closeI) = NeedInput
    (scPush fsink (Processing pushI closeI))
    (SourceM (closeI >>= goRes) (closeI >> return ()))
  where
    goRes (Emit _ os) = return $ fromList os
    goRes Stop = return Closed
    goRes (StartConduit (NeedInput _ closeC)) = return closeC
    goRes (StartConduit (Finished _)) = return Closed
    goRes (StartConduit (ConduitM mcon _)) = mcon >>= goRes . StartConduit
    goRes (StartConduit HaveOutput{}) = error "scGoRes:goRes: StartConduit HaveOutput not supported yet"
scGoRes _ (Done mleftover Stop) = Finished mleftover
scGoRes _ (Done Nothing (StartConduit c)) = c
scGoRes _ (Done (Just leftover) (StartConduit (Finished Nothing))) = Finished (Just leftover)
scGoRes _ (Done Just{} (StartConduit (Finished Just{}))) = error "Invariant violated: conduit returns leftover without push"
scGoRes _ (Done (Just leftover) (StartConduit (NeedInput p _))) = p leftover
scGoRes _ (Done Just{} (StartConduit HaveOutput{})) = error "scGoRes: StartConduit HaveOutput not supported yet"
scGoRes fsink (Done mleftover (StartConduit (ConduitM mcon close))) =
    ConduitM (liftM (scGoRes fsink . Done mleftover . StartConduit) mcon) close
scGoRes fsink (SinkM msink) = ConduitM (liftM (scGoRes fsink) msink) (msink >>= sinkClose)

-- | Specialised version of 'sequenceSink'
--
-- Note that this function will return an infinite stream if provided a
-- @SinkNoData@ constructor. In other words, you probably don\'t want to do
-- @sequence . return@.
--
-- Since 0.3.0
sequence :: Monad m => Sink input m output -> Conduit input m output
sequence (Processing spush0 sclose0) =
    NeedInput (push spush0) (close sclose0)
  where
    push spush input = goRes $ spush input

    goRes res =
        case res of
            Processing spush'' sclose'' ->
                NeedInput (push spush'') (close sclose'')
            Done Nothing output -> HaveOutput
                (NeedInput (push spush0) (close sclose0))
                (return ())
                output
            Done (Just input') output -> HaveOutput
                (goRes $ spush0 input')
                (return ())
                output
            SinkM msink -> ConduitM (liftM goRes msink) (msink >>= sinkClose)

    close sclose = SourceM (do
        output <- sclose
        return $ Open Closed (return ()) output) (return ())

sequence (Done Nothing output) = NeedInput
    (\_input ->
        let x = HaveOutput x (return ()) output
         in x)
    (   let src = Open src (return ()) output
         in src)
sequence (Done Just{} _) = error "Invariant violated: sink returns leftover without push"
sequence (SinkM msink) = ConduitM (liftM sequence msink) (msink >>= sinkClose)

-- | Close a @Conduit@ early, discarding any output.
--
-- Since 0.3.0
conduitClose :: Monad m => Conduit input m output -> m ()
conduitClose (NeedInput _ c) = sourceClose c
conduitClose Finished{} = return ()
conduitClose (HaveOutput _ c _) = c
conduitClose (ConduitM _ c) = c
