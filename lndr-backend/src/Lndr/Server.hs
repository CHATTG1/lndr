{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

module Lndr.Server
    ( ServerState
    , LndrAPI
    , lndrAPI
    , LndrHandler(..)
    , freshState
    , updateDbFromLndrLogs
    , app
    ) where

import           Control.Concurrent.STM
import           Control.Monad.Except
import           Control.Monad.Reader
import           Data.ByteString.Lazy (ByteString)
import           Data.Configurator
import           Data.Configurator.Types
import           Data.Either (either)
import qualified Data.HashMap.Strict as H (lookup)
import           Data.Maybe (fromMaybe)
import           Data.Pool (createPool, withResource)
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Text.Lazy.Encoding (encodeUtf8)
import qualified Data.Text.Lazy as LT
import qualified Database.PostgreSQL.Simple as DB
import qualified Lndr.Db as Db
import           Lndr.Docs
import           Lndr.EthereumInterface
import           Lndr.Handler
import           Lndr.Types
import           Network.Ethereum.Web3 hiding (convert)
import           Network.HTTP.Types
import           Network.Wai
import           Servant
import           Servant.Docs
import           System.FilePath

type LndrAPI =
        "transactions" :> QueryParam "user" Address :> Get '[JSON] [IssueCreditLog]
   :<|> "pending_settlements" :> Capture "user" Address :> Get '[JSON] ([CreditRecord], [IssueCreditLog])
   :<|> "verify_settlement" :> Capture "hash" Text :> QueryParam "txHash" Text :> PostNoContent '[JSON] NoContent
   :<|> "pending" :> Capture "user" Address :> Get '[JSON] [CreditRecord]
   :<|> "lend" :> ReqBody '[JSON] CreditRecord :> PostNoContent '[JSON] NoContent
   :<|> "borrow" :> ReqBody '[JSON] CreditRecord :> PostNoContent '[JSON] NoContent
   :<|> "reject" :> ReqBody '[JSON] RejectRecord :> PostNoContent '[JSON] NoContent
   :<|> "nonce" :> Capture "p1" Address :> Capture "p2" Address :> Get '[JSON] Nonce
   :<|> "nick" :> ReqBody '[JSON] NickRequest :> PostNoContent '[JSON] NoContent
   :<|> "nick" :> Capture "user" Address :> Get '[JSON] Text
   :<|> "search_nick" :> Capture "nick" Text :> Get '[JSON] [NickInfo]
   :<|> "taken_nick" :> Capture "nick" Text :> Get '[JSON] Bool
   :<|> "friends" :> Capture "user" Address :> Get '[JSON] [NickInfo]
   :<|> "add_friends" :> Capture "user" Address
                      :> ReqBody '[JSON] [Address]
                      :> PostNoContent '[JSON] NoContent
   :<|> "remove_friends" :> Capture "user" Address
                         :> ReqBody '[JSON] [Address]
                         :> PostNoContent '[JSON] NoContent
   :<|> "counterparties" :> Capture "user" Address :> Get '[JSON] [Address]
   :<|> "balance" :> Capture "user" Address :> Get '[JSON] Integer
   :<|> "balance" :> Capture "p1" Address :> Capture "p2" Address :> Get '[JSON] Integer
   :<|> "gas_price" :> Get '[JSON] Integer
   :<|> "gas_price" :> ReqBody '[JSON] Integer :> PutNoContent '[JSON] NoContent
   :<|> "unsubmitted" :> Get '[JSON] [IssueCreditLog]
   :<|> "resubmit" :> Capture "hash" Text :> PostNoContent '[JSON] NoContent
   :<|> "register_push" :> Capture "user" Address
                        :> ReqBody '[JSON] PushRequest
                        :> PostNoContent '[JSON] NoContent
   :<|> "config" :> Get '[JSON] ConfigResponse
   :<|> "docs" :> Raw


server :: ServerT LndrAPI LndrHandler
server = transactionsHandler
    :<|> pendingSettlementsHandler
    :<|> verifyHandler
    :<|> pendingHandler
    :<|> lendHandler
    :<|> borrowHandler
    :<|> rejectHandler
    :<|> nonceHandler
    :<|> nickHandler
    :<|> nickLookupHandler
    :<|> nickSearchHandler
    :<|> nickTakenHandler
    :<|> friendHandler
    :<|> addFriendsHandler
    :<|> removeFriendsHandler
    :<|> counterpartiesHandler
    :<|> balanceHandler
    :<|> twoPartyBalanceHandler
    :<|> gasPriceHandler
    :<|> setGasPriceHandler
    :<|> unsubmittedHandler
    :<|> resubmitHandler
    :<|> registerPushHandler
    :<|> configHandler
    :<|> Tagged serveDocs
    where serveDocs _ respond =
            respond $ responseLBS ok200 [plain] docsBS
          plain = ("Content-Type", "text/plain")


lndrAPI :: Proxy LndrAPI
lndrAPI = Proxy


docsBS :: ByteString
docsBS = encodeUtf8
       . LT.pack
       . markdown
       $ docsWithIntros [intro] lndrAPI
  where intro = DocIntro "LNDR Server" ["Web service API"]


-- Natural Transformation from 'LndrHandler' to 'Handler'. Servant expects all
-- routes to be of type 'ExceptT ServantErr IO a' ('Handler') so the endpoints
-- used in this application, of type 'ReaderT ServerState (ExceptT ServantErr IO)'
-- ('LndrHandler'), must be converted to the default 'Handler' type before they
-- can be served by the 'serve' function.
lndrHandlerToHandler :: ServerState -> LndrHandler :~> Handler
lndrHandlerToHandler state = NT (lndrHandlerToHandler' state)
    where lndrHandlerToHandler' :: forall a. ServerState -> LndrHandler a -> Handler a
          lndrHandlerToHandler' state r = do
                res <- liftIO . runExceptT $ runReaderT (runLndr r) state
                case res of
                  Left err -> throwError err
                  Right a  -> return a


readerServer :: ServerState -> Server LndrAPI
readerServer state = enter (lndrHandlerToHandler state) server


app :: ServerState -> Application
app state = serve lndrAPI (readerServer state)


-- | Scans blockchain for previously-submitted credit records and inserts them
-- into 'verified_credits' table if missing.
--
-- This function is called at startup to ensure database consistency with the
-- blockchain. All credit-related queries use database data so without these
-- consistency checks at startup, it's possible user's transaction history
-- would be inaccurately represented.
updateDbFromLndrLogs :: ServerState -> IO ()
updateDbFromLndrLogs (ServerState pool configMVar) = void $ do
    config <- atomically $ readTVar configMVar
    logs <- runWeb3 $ lndrLogs config Nothing Nothing
    withResource pool . Db.insertCredits $ either (const []) id logs


-- | Load required server configuration and create database connection pool.
-- Called at server startup.
freshState :: IO ServerState
freshState = do
    serverConfig <- loadConfig
    let dbConfig = DB.defaultConnectInfo { DB.connectUser = T.unpack $ dbUser serverConfig
                                         , DB.connectPassword = T.unpack $ dbUserPassword serverConfig
                                         , DB.connectDatabase = T.unpack $ dbName serverConfig
                                         }

    ServerState <$> createPool (DB.connect dbConfig) DB.close 1 10 95
                <*> newTVarIO serverConfig


loadConfig :: IO ServerConfig
loadConfig = do
    config <- getMap =<< load [Required $ "lndr-backend" </> "data" </> "lndr-server.config"]
    let loadEntry x = fromMaybe (error $ T.unpack x) $ convert =<< H.lookup x config
    return $ ServerConfig (loadEntry "lndrUcacAddr")
                          (loadEntry "creditProtocolAddress")
                          (loadEntry "issueCreditEvent")
                          (loadEntry "scanStartBlock")
                          (loadEntry "dbUser")
                          (loadEntry "dbUserPassword")
                          (loadEntry "dbName")
                          (loadEntry "executionAddress")
                          (loadEntry "gasPrice")
                          (loadEntry "maxGas")
                          (loadEntry "urbanAirshipKey")
                          (loadEntry "urbanAirshipSecret")
