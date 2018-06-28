{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeOperators     #-}
{-# OPTIONS_GHC -Wall #-}

module Main where

import           Control.Lens
import           Data.Aeson (eitherDecode)
import           Data.ByteString.Lazy as BSL
import           Network.Wai.Handler.Warp (run)
import           Servant
import           System.Environment (getArgs)
import           System.Remote.Monitoring (forkServer, serverMetricStore)
import           System.Remote.Monitoring.Statsd (forkStatsd)
import           System.Wlog (LoggerName (..), launchFromFile)
-- import           Cardano.Wallet.API.V1.Types (PaymentSource (..), WalletId(..), AccountIndex)
import           Pos.Util.CompileInfo (retrieveCompileTimeInfo, withCompileInfo)
-- import Pos.Update.Configuration (withUpdateConfiguration)

import           Cardano.Faucet
import           Cardano.Faucet.Swagger

-- type API = FaucetDoc :<|> FaucetAPI

-- api :: Proxy API
-- api = Proxy


main :: IO ()
main = withCompileInfo $(retrieveCompileTimeInfo)  $ do
  ekg <- forkServer "localhost" 8001
  args <- getArgs
  config <- case args of
    [ "--config", cfgFile ] -> do
      ecfg <- eitherDecode <$> BSL.readFile cfgFile
      either (error . ("Error decoding: " ++)) return ecfg
    _ -> error "Need a --config argument pointing to a json file"
  fEnv <- runInitLogger config $ initEnv config (serverMetricStore ekg)
  let server = faucetHandler fEnv
  _statsd <- forkStatsd (config ^. fcStatsdOpts . _Wrapped') (fEnv ^. feStore)
  run (config ^. fcPort) (serve faucetDocAPI server)
  where
      runInitLogger c = launchFromFile (c ^. fcLoggerConfigFile) (LoggerName "faucet")