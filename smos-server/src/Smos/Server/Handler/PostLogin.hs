{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecordWildCards #-}

module Smos.Server.Handler.PostLogin where

import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Servant.Auth.Server
import Smos.Server.Handler.Import

servePostLogin ::
  Login ->
  ServerHandler (Headers '[Header "Set-Cookie" T.Text] NoContent)
servePostLogin Login {..} = do
  me <- runDB $ getBy $ UniqueUsername loginUsername
  case me of
    Nothing -> throwError err401
    Just (Entity _ user) ->
      let un = userName user
       in if development
            then setLoggedIn un
            else case checkPassword (mkPassword loginPassword) (userHashedPassword user) of
              PasswordCheckSuccess -> setLoggedIn un
              PasswordCheckFail -> throwError err401
  where
    setLoggedIn un = do
      let cookie = AuthCookie {authCookieUsername = un}
      ServerEnv {..} <- ask
      mCookie <- liftIO $ makeSessionCookieBS serverEnvCookieSettings serverEnvJWTSettings cookie
      case mCookie of
        Nothing -> throwError err401
        Just setCookie -> return $ addHeader (decodeUtf8 setCookie) NoContent
