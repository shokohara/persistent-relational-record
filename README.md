persistent-relational-record
============================

[![Travis](https://img.shields.io/travis/himura/persistent-relational-record/master.svg)](https://travis-ci.org/himura/persistent-relational-record)
[![Hackage-Deps](https://img.shields.io/hackage-deps/v/persistent-relational-record.svg)](http://packdeps.haskellers.com/feed?needle=persistent-relational-record)

## About ##

persistent-relational-record build a bridge between [Haskell Relational Record](https://hackage.haskell.org/package/relational-query)
and [Persistent](http://hackage.haskell.org/package/persistent).
It uses the persistent entities definition instead of obtaining schema from DB at compilation time.

## Getting Started ##

If you already define an entities in persistent's manner, then you are almost ready to use this module.
The entities definition in the style of persistent-relational-record are shown below:

Model.hs:

~~~~ {.haskell}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE FlexibleInstances #-}

import Data.Text (Text)
import Database.Persist.Relational (mkHrrInstances)
import Database.Persist.TH

share [mkPersist sqlSettings, mkMigrate "migrateAll", mkSave "db", mkHrrInstances] [persistLowerCase|
Image
    title      Text
    deriving Eq Show
Tag
    name       Text
    deriving Eq Show
ImageTag
    imageId    ImageId
    tagId      TagId
|]
~~~~

The main difference from the persistent version is that `mkSave "db"` and `mkHrrInstances` are added to the 1st argument of the `share` function.
`mkSave "db"` saves the definition of tables to "db" variable for later use.
`mkHrrInstances` generates various instances from the entities definition to cooperate with HRR.

Next, you should define HRR record types and their instances,
this package provides "defineTableFromPersistent" function to generate those types and auxiliary functnions.
To avoid the conflict of record field names, we recommend making one module per table.

Here is the content of "Image.hs":

~~~~ {.haskell}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Image where

import Data.Text (Text)
import Database.Persist.Relational
import Model hiding (Image) -- Both of HRR and persistent generates `Image` type, so you should hide Image type generated by persistent.
import qualified Model

defineTableFromPersistent ''Model.Image db
~~~~

You should create "Tag.hs" and "ImageTag.hs" in the same manner.

Now, you can build queries in manner of HRR:

~~~~ {.haskell}
module Query where

import Data.Text (Text)
import Database.Relational.Query

import Model
import qualified Image
import qualified ImageTag
import qualified Tag

imageIdFromTagNameList
    :: [Text] -- ^ list of tag name
    -> Relation () ImageId
imageIdFromTagNameList tagNames = aggregateRelation $ do
   imgtag <- query $ ImageTag.imageTag
   tag <- query $ Tag.tag
   on $ tag ! Tag.id' .=. imgtag ! ImageTag.tagId'
   wheres $ tag ! Tag.name' `in'` values tagNames
   g <- groupBy $ imgtag ! ImageTag.imageId'
   let c = count $ imgtag ! ImageTag.imageId'
   having $ c .=. value (length $ tagNames)
   return g

selectImageByTagNameList
    :: [Text] -- ^ list of tag name
    -> Relation () Image.Image
selectImageByTagNameList tagNames = relation $ do
    img <- query Image.image
    imgids <- query $ imageIdFromTagNameList tagNames
    on $ img ! Image.id' .=. imgids
    return img
~~~~

Finally, we can execute a query by runQuery:

~~~~ {.haskell}
{-# LANGUAGE OverloadedStrings #-}

import Control.Monad.Base
import Control.Monad.Logger
import Control.Monad.Trans.Resource
import Data.Conduit
import qualified Data.Conduit.List as CL
import Database.Persist.MySQL
import Database.Persist.Relational
import Database.Relational.Query

import Model
import Query

sample1 :: SqlPersistT (LoggingT IO) [ImageId]
sample1 = runResourceT $ runQuery (relationalQuery $ imageIdFromTagNameList ["tokyo", "haskell"]) () $$ CL.consume

sample2 :: SqlPersistT (LoggingT IO) [Entity Image]
sample2 = runResourceT $ runQuery (relationalQuery $ selectImageByTagNameList ["tokyo", "haskell"]) () $$ CL.consume

main :: IO ()
main = runStderrLoggingT $ withMySQLPool defaultConnectInfo 10 $ runSqlPool $ do
    mapM_ (liftBase . print) =<< sample1
    mapM_ (liftBase . print) =<< sample2
~~~~

`runQuery` run the HRR `Query` and gives the result as conduit `Source`.
In addition, it converts the result type to persistent's entity if the result type of `Query` is HRR record type.

For example, the expression `selectImageByTagNameList [...]` has type `Relation () Image.Image`,
but `runQuery (relationalQuery $ selectImageByTagNameList ["tokyo", "haskell"]) ()` has type `Source m (Entity Image)`.

For a full runnable example, see [examples](https://github.com/himura/persistent-relational-record/tree/master/examples/) directory.
