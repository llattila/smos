{-# OPTIONS_GHC -fno-warn-orphans #-}

module Smos.API.Password
  ( module Data.Password.Bcrypt,
  )
where

import Data.Password.Bcrypt
import Data.Password.Instances ()
import Data.Validity
import YamlParse.Applicative

instance Validity Password where
  validate = trivialValidation

instance YamlSchema Password where
  yamlSchema = mkPassword <$> yamlSchema
