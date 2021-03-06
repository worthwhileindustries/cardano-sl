{-# LANGUAGE TypeFamilies #-}

-- | Explorer's local Txp.

module Pos.Explorer.Txp.Local
       ( eTxProcessTransaction
       , eTxProcessTransactionNoLock
       , eTxNormalize
       ) where

import           Universum

import qualified Data.HashMap.Strict as HM

import           Pos.Core (BlockVersionData, EpochIndex, Timestamp)
import           Pos.Core.JsonLog (CanJsonLog (..))
import           Pos.Core.Txp (TxAux (..), TxId)
import           Pos.Crypto (ProtocolMagic)
import           Pos.Infra.Slotting (MonadSlots (getCurrentSlot), getSlotStart)
import           Pos.Infra.StateLock (Priority (..), StateLock,
                     StateLockMetrics, withStateLock)
import           Pos.Infra.Util.JsonLog.Events (MemPoolModifyReason (..))
import           Pos.Txp.Logic.Local (txNormalizeAbstract,
                     txProcessTransactionAbstract)
import           Pos.Txp.MemState (MempoolExt, TxpLocalWorkMode, getTxpExtra,
                     withTxpLocalData)
import           Pos.Txp.Toil (ToilVerFailure (..), Utxo)
import qualified Pos.Util.Modifier as MM
import           Pos.Util.Util (HasLens')

import           Pos.Explorer.Core (TxExtra (..))
import           Pos.Explorer.Txp.Common (buildExplorerExtraLookup)
import           Pos.Explorer.Txp.Toil (ELocalToilM, ExplorerExtraLookup (..),
                     ExplorerExtraModifier, eNormalizeToil, eProcessTx,
                     eemLocalTxsExtra)


type ETxpLocalWorkMode ctx m =
    ( TxpLocalWorkMode ctx m
    , MempoolExt m ~ ExplorerExtraModifier
    )

eTxProcessTransaction ::
       ( ETxpLocalWorkMode ctx m
       , HasLens' ctx StateLock
       , HasLens' ctx (StateLockMetrics MemPoolModifyReason)
       , CanJsonLog m
       )
    => ProtocolMagic
    -> (TxId, TxAux)
    -> m (Either ToilVerFailure ())
eTxProcessTransaction pm itw =
    withStateLock LowPriority ProcessTransaction $ \__tip -> eTxProcessTransactionNoLock pm itw

eTxProcessTransactionNoLock ::
       forall ctx m. (ETxpLocalWorkMode ctx m)
    => ProtocolMagic
    -> (TxId, TxAux)
    -> m (Either ToilVerFailure ())
eTxProcessTransactionNoLock pm itw = getCurrentSlot >>= \case
    Nothing   -> pure $ Left ToilSlotUnknown
    Just slot -> do
        -- First get the current @SlotId@ so we can calculate the time.
        -- Then get when that @SlotId@ started and use that as a time for @Tx@.
        mTxTimestamp <- getSlotStart slot
        txProcessTransactionAbstract buildContext (processTx' mTxTimestamp) itw
  where
    buildContext :: Utxo -> TxAux -> m ExplorerExtraLookup
    buildContext utxo = buildExplorerExtraLookup utxo . one

    processTx' ::
           Maybe Timestamp
        -> BlockVersionData
        -> EpochIndex
        -> (TxId, TxAux)
        -> ExceptT ToilVerFailure ELocalToilM ()
    processTx' mTxTimestamp bvd epoch tx =
        eProcessTx pm bvd epoch tx (TxExtra Nothing mTxTimestamp)

-- | 1. Recompute UtxoView by current MemPool
--   2. Remove invalid transactions from MemPool
--   3. Set new tip to txp local data
eTxNormalize
    :: forall ctx m . (ETxpLocalWorkMode ctx m) => ProtocolMagic -> m ()
eTxNormalize pm = do
    extras <- MM.insertionsMap . view eemLocalTxsExtra <$> withTxpLocalData getTxpExtra
    txNormalizeAbstract buildExplorerExtraLookup (normalizeToil' extras)
  where
    normalizeToil' ::
           HashMap TxId TxExtra
        -> BlockVersionData
        -> EpochIndex
        -> HashMap TxId TxAux
        -> ELocalToilM ()
    normalizeToil' extras bvd epoch txs =
        let toNormalize = HM.toList $ HM.intersectionWith (,) txs extras
        in eNormalizeToil pm bvd epoch toNormalize
