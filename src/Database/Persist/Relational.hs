{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      :  Database.Persist.Relational
-- Copyright   :  (C) 2016 Takahiro Himura
-- License     :  BSD3
-- Maintainer  :  Takahiro Himura <taka@himura.jp>
-- Stability   :  experimental
-- Portability :  unknown
--
-- This module works as a bridge between <https://hackage.haskell.org/package/relational-query Haskell Relational Record>
-- and <http://hackage.haskell.org/package/persistent Persistent>.
-- It uses the persistent entities definition instead of obtaining schema from DB at compilation time.
module Database.Persist.Relational
       ( -- * Getting Started
         -- $GettingStarted
         runQuery
       , rawQuery
       , mkHrrInstances
       , defineTableFromPersistent
       , defineTableFromPersistentWithConfig
       , defineFromToSqlPersistValue
       , defaultConfig
       , ToPersistEntity (..)
       ) where

import Control.Monad.Reader (MonadReader)
import Control.Monad.Trans.Resource (MonadResource)
import Data.Conduit (Source, ($=))
import qualified Data.Conduit.List as CL
import qualified Data.Text as T
import Database.Persist
import Database.Persist.Relational.Instances ()
import Database.Persist.Relational.TH
import Database.Persist.Relational.ToPersistEntity
import Database.Persist.Sql (SqlBackend)
import qualified Database.Persist.Sql as PersistSql
import Database.Record (ToSql, recordToSql, runFromRecord, runToRecord)
import Database.Relational.Query

-- $GettingStarted
--
-- If you already define an entities in persistent's manner, then you are almost ready to use this module.
-- The entities definition in the style of persistent-relational-record are shown below:
--
-- Model.hs:
--
-- @
-- {-\# LANGUAGE GADTs \#-}
-- {-\# LANGUAGE GeneralizedNewtypeDeriving \#-}
-- {-\# LANGUAGE MultiParamTypeClasses \#-}
-- {-\# LANGUAGE TemplateHaskell \#-}
-- {-\# LANGUAGE TypeFamilies \#-}
-- {-\# LANGUAGE QuasiQuotes \#-}
-- {-\# LANGUAGE FlexibleInstances \#-}
--
-- import Data.Text (Text)
-- import Database.Persist.Relational (mkHrrInstances)
-- import Database.Persist.TH
--
-- share [mkPersist sqlSettings, mkMigrate "migrateAll", mkSave "db", mkHrrInstances] [persistLowerCase|
-- Image
--     title      Text
--     deriving Eq Show
-- Tag
--     name       Text
--     deriving Eq Show
-- ImageTag
--     imageId    ImageId
--     tagId      TagId
-- |]
-- @
--
-- The main difference is that @mkSave "db"@ and @mkHrrInstances@ has been added to the 1st argument of the @share@ function.
-- @mkSave "db"@ saves the definition of tables to "db" variable for later use.
-- @mkHrrInstances@ generates various instances from the entities definition to cooperate with HRR.
--
-- Next, you should define HRR record types and their instances,
-- this package provides "defineTableFromPersistent" function to generate those types and auxiliary functnions. To avoid the conflict of record field names, we recommend making one module per table.
--
-- Here is the content of "Image.hs":
--
-- @
-- {-\# LANGUAGE TemplateHaskell \#-}
-- {-\# LANGUAGE FlexibleInstances \#-}
-- {-\# LANGUAGE MultiParamTypeClasses \#-}
-- {-\# OPTIONS_GHC -fno-warn-orphans \#-}
--
-- module Image where
--
-- import Data.Text (Text)
-- import Database.Persist.Relational
-- import Model hiding (Image) -- Both of HRR and persistent generates `Image` type, so you should hide Image type generated by persistent.
-- import qualified Model
--
-- defineTableFromPersistent ''Model.Image db
-- @
--
-- You should create "Tag.hs" and "ImageTag.hs" in the same manner.
--
-- Now, you can build queries by HRR:
--
-- @
-- {-# LANGUAGE OverloadedStrings #-}
--
-- import Control.Monad.Base
-- import Control.Monad.Logger
-- import Control.Monad.Trans.Resource
-- import Data.Conduit
-- import qualified Data.Conduit.List as CL
-- import Database.Persist.MySQL
-- import Database.Persist.Relational
-- import Database.Relational.Query as HRR
--
-- import Model
-- import qualified Image
-- import qualified ImageTag
-- import qualified Tag
--
-- imageIdFromTagNameList
--     :: Bool -- ^ match any
--     -> [Text] -- ^ list of tag name
--     -> Relation () ImageId
-- imageIdFromTagNameList matchAny tagNames = aggregateRelation $
--    imgtag <- query $ ImageTag.imageTag
--    tag <- query $ Tag.tag
--    on $ tag ! Tag.id' .=. imgtag ! ImageTag.tagId'
--    wheres $ tag ! Tag.name' `in'` values tagNames
--    g <- groupBy $ imgtag ! ImageTag.imageId'
--    let c = HRR.count $ imgtag ! ImageTag.imageId'
--    having $
--        if matchAny
--            then c .>. value (0 :: Int)
--            else c .=. value (fromIntegral . length $ tagNames)
--    return g
--
-- run :: SqlPersistT (LoggingT IO) [Entity Image]
-- run = runResourceT $
--     runQuery (relationalQuery $ imageByTagNameList False ["tokyo", "haskell"]) () $$ CL.consume
-- @

-- | Execute a HRR 'Query' and return the stream of its results.
runQuery :: ( MonadResource m
            , MonadReader env m
#if MIN_VERSION_persistent(2, 5, 0)
            , HasPersistBackend env
            , BaseBackend env ~ SqlBackend
#else
            , HasPersistBackend env SqlBackend
#endif
            , ToSql PersistValue p
            , ToPersistEntity a b
            )
         => Query p a -- ^ Query to get record type a requires parameter p
         -> p         -- ^ Parameter type
         -> Source m b
runQuery q vals = rawQuery q vals $= CL.map (runToRecord recordFromSql')

rawQuery :: ( MonadResource m
            , MonadReader env m
#if MIN_VERSION_persistent(2, 5, 0)
            , HasPersistBackend env
            , BaseBackend env ~ SqlBackend
#else
            , HasPersistBackend env SqlBackend
#endif
            , ToSql PersistValue p
            )
         => Query p a
         -> p
         -> Source m [PersistValue]
rawQuery q vals = PersistSql.rawQuery queryTxt params
  where
    queryTxt = T.pack . untypeQuery $ q
    params = runFromRecord recordToSql vals
