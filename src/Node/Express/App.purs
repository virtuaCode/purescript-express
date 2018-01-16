module Node.Express.App
    ( AppM()
    , App()
    , listenHttp, listenHttps, listenHostHttp, listenHostHttps
    , listenPipe, makeHttpServer, makeHttpsServer, apply
    , use, useExternal, useAt, useExternalAt, useOnParam, useOnError
    , getProp, setProp
    , http, get, post, put, delete, all
    ) where

import Prelude hiding (apply)
import Data.Foreign.Class (class Decode, decode)
import Data.Function.Uncurried (Fn2, Fn3, Fn4, runFn4, runFn3, runFn2)
import Data.Maybe (Maybe)
import Data.Foreign (Foreign, toForeign)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Eff.Exception (Error)
import Control.Monad.Except (runExcept)
import Node.HTTP (Server ())

import Node.Express.Types (class RoutePattern, EXPRESS, Application,
                           ExpressM, Response, Request, Event, Host,
                           Path, Port, Pipe, Method(..))
import Node.Express.Internal.Utils (eitherToMaybe)
import Node.Express.Handler (Handler, runHandlerM)

-- | Monad responsible for application related operations (initial setup mostly).
data AppM e a = AppM (Application -> Eff e a)
type App e = AppM (express :: EXPRESS | e) Unit

type HandlerFn e = Request -> Response -> Eff (express :: EXPRESS | e) Unit -> Eff (express :: EXPRESS | e) Unit

instance functorAppM :: Functor (AppM e) where
    map f (AppM h) = AppM \app -> liftM1 f $ h app

instance applyAppM :: Apply (AppM e) where
    apply (AppM f) (AppM h) = AppM \app -> do
        res <- h app
        trans <- f app
        pure $ trans res

instance applicativeAppM :: Applicative (AppM e) where
    pure x = AppM \_ -> pure x

instance bindAppM :: Bind (AppM e) where
    bind (AppM h) f = AppM \app -> do
        res <- h app
        case f res of
             AppM g -> g app

instance monadAppM :: Monad (AppM e)

instance monadEffAppM :: MonadEff eff (AppM eff) where
    liftEff act = AppM \_ -> act


-- | Create a Node.HTTP server from the Express application.
-- | HTTP version
makeHttpServer :: forall e1. App e1 -> ExpressM e1 Server
makeHttpServer (AppM act) = do
    app <- mkApplication
    act app
    _httpServer app

-- | Create a Node.HTTP server from the Express application.
-- | HTTPS version
makeHttpsServer :: forall e1. App e1 -> ExpressM e1 Server
makeHttpsServer (AppM act) = do
    app <- mkApplication
    act app
    _httpsServer app

-- | Run application on specified port and execute callback after launch.
-- | HTTP version
listenHttp :: forall e1 e2. App e1 -> Port -> (Event -> Eff e2 Unit) -> ExpressM e1 Server
listenHttp (AppM act) port cb = do
    app <- mkApplication
    act app
    _listenHttp app port cb

-- | Run application on specified port and execute callback after launch.
-- | HTTPS version
listenHttps :: forall e1 e2 opts.
    App e1 -> Port -> opts -> (Event -> Eff e2 Unit) -> ExpressM e1 Server
listenHttps (AppM act) port opts cb = do
    app <- mkApplication
    act app
    _listenHttps app port opts cb

-- | Run application on specified port & host and execute callback after launch.
-- | HTTP version
listenHostHttp :: forall e1 e2. App e1 -> Port -> Host -> (Event -> Eff e2 Unit) -> ExpressM e1 Server
listenHostHttp (AppM act) port host cb = do
    app <- mkApplication
    act app
    _listenHostHttp app port host cb

-- | Run application on specified port & host and execute callback after launch.
-- | HTTPS version
listenHostHttps :: forall e1 e2 opts.
    App e1 -> Port -> Host-> opts -> (Event -> Eff e2 Unit) -> ExpressM e1 Server
listenHostHttps (AppM act) port host opts cb = do
    app <- mkApplication
    act app
    _listenHostHttps app port host opts cb

-- | Run application on specified named pipe and execute callback after launch.
-- | HTTP version
listenPipe :: forall e1 e2. App e1 -> Pipe -> (Event -> Eff e2 Unit) -> ExpressM e1 Server
listenPipe (AppM act) pipe cb = do
    app <- mkApplication
    act app
    _listenPipe app pipe cb

-- | Apply App actions to existent Express.js application
apply :: forall e. App e -> Application -> ExpressM e Unit
apply (AppM act) app = act app

-- | Use specified middleware handler.
use :: forall e. Handler e -> App e
use middleware = AppM \app ->
    runFn2 _use app $ runHandlerM middleware

-- | Use any function as middleware.
-- | Introduced to ease usage of a bunch of external
-- | middleware written for express.js.
-- | See http://expressjs.com/4x/api.html#middleware
useExternal :: forall e. Fn3 Request Response (ExpressM e Unit) (ExpressM e Unit) -> App e
useExternal fn = AppM \app ->
    runFn2 _useExternal app fn

-- | Use specified middleware only on requests matching path.
useAt :: forall e. Path -> Handler e -> App e
useAt route middleware = AppM \app ->
    runFn3 _useAt app route $ runHandlerM middleware

-- | Use any function as middleware only on requests matching path.
-- | Introduced to ease usage of a bunch of external
-- | middleware written for express.js.
-- | See http://expressjs.com/4x/api.html#middleware
useExternalAt :: forall e. Path -> Fn3 Request Response (ExpressM e Unit) (ExpressM e Unit) -> App e
useExternalAt route fn = AppM \app ->
    runFn3 _useExternalAt app route fn

-- | Process route param with specified handler.
useOnParam :: forall e. String -> (String -> Handler e) -> App e
useOnParam param handler = AppM \app ->
    runFn3 _useOnParam app param (runHandlerM <<< handler)

-- | Use error handler. Probably this should be the last middleware to attach.
useOnError :: forall e. (Error -> Handler e) -> App e
useOnError handler = AppM \app ->
    runFn2 _useOnError app (runHandlerM <<< handler)


-- | Get application property.
-- | See http://expressjs.com/4x/api.html#app-settings
getProp :: forall e a. (Decode a) => String -> AppM (express :: EXPRESS | e) (Maybe a)
getProp name = AppM \app ->
    liftEff $ liftM1 (eitherToMaybe <<< runExcept <<< decode) (runFn2 _getProp app name)

-- | Set application property.
-- | See http://expressjs.com/4x/api.html#app-settings
setProp :: forall e a. (Decode a) => String -> a -> App e
setProp name val = AppM \app ->
    runFn3 _setProp app name val


-- | Bind specified handler to handle request matching route and method.
http :: forall e r. (RoutePattern r) => Method -> r -> Handler e -> App e
http method route handler = AppM \app ->
    runFn4 _http app (show method) (toForeign route) $ runHandlerM handler

-- | Shortcut for `http GET`.
get :: forall e r. (RoutePattern r) => r -> Handler e -> App e
get = http GET

-- | Shortcut for `http POST`.
post :: forall e r. (RoutePattern r) => r -> Handler e -> App e
post = http POST

-- | Shortcut for `http PUT`.
put :: forall e r. (RoutePattern r) => r -> Handler e -> App e
put = http PUT

-- | Shortcut for `http DELETE`.
delete :: forall e r. (RoutePattern r) => r -> Handler e -> App e
delete = http DELETE

-- | Shortcut for `http ALL` (match on any http method).
all :: forall e r. (RoutePattern r) => r -> Handler e -> App e
all = http ALL

foreign import mkApplication :: forall e. ExpressM e Application

foreign import _getProp :: forall e. Fn2 Application String (ExpressM e Foreign)

foreign import _setProp :: forall e a. Fn3 Application String a (ExpressM e Unit)

foreign import _http :: forall e. Fn4 Application String Foreign (HandlerFn e) (Eff (express :: EXPRESS | e) Unit)

foreign import _httpServer :: forall e1. Application -> ExpressM e1 Server

foreign import _httpsServer :: forall e1. Application -> ExpressM e1 Server

foreign import _listenHttp :: forall e1 e2. Application -> Int -> (Event -> Eff e1 Unit) -> ExpressM e2 Server

foreign import _listenHttps :: forall opts e1 e2. Application -> Int -> opts -> (Event -> Eff e1 Unit) -> ExpressM e2 Server

foreign import _listenHostHttp :: forall e1 e2. Application -> Int -> String -> (Event -> Eff e1 Unit) -> ExpressM e2 Server

foreign import _listenHostHttps :: forall opts e1 e2. Application -> Int -> String -> opts -> (Event -> Eff e1 Unit) -> ExpressM e2 Server

foreign import _listenPipe :: forall e1 e2. Application -> String -> (Event -> Eff e1 Unit) -> ExpressM e2 Server

foreign import _use :: forall e. Fn2 Application (HandlerFn e) (Eff (express :: EXPRESS | e) Unit)

foreign import _useExternal :: forall e. Fn2 Application (Fn3 Request Response (ExpressM e Unit) (ExpressM e Unit)) (ExpressM e Unit)

foreign import _useAt :: forall e. Fn3 Application String (HandlerFn e) (Eff (express :: EXPRESS | e) Unit)

foreign import _useExternalAt :: forall e. Fn3 Application String (Fn3 Request Response (ExpressM e Unit) (ExpressM e Unit)) (ExpressM e Unit)

foreign import _useOnParam :: forall e. Fn3 Application String (String -> HandlerFn e) (Eff (express :: EXPRESS | e) Unit)

foreign import _useOnError :: forall e. Fn2 Application (Error -> HandlerFn e) (Eff (express :: EXPRESS | e) Unit)
