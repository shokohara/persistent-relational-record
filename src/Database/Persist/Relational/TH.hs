{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Database.Persist.Relational.TH
       where

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative
#endif

import Data.Int
import Data.List
import qualified Data.Map as M
import Data.Maybe
import qualified Data.Text as T
import Database.Persist
import Database.Persist.Quasi
import Database.Persist.Relational.ToPersistEntity
import qualified Database.Persist.Sql as PersistSql
import Database.Record (PersistableWidth (..))
import Database.Record.FromSql
import Database.Record.TH (deriveNotNullType, recordType)
import Database.Record.ToSql
import Database.Relational.Query hiding ((!))
import Database.Relational.Query.TH (defineTable, defineScalarDegree)
import Language.Haskell.TH

ftToType :: FieldType -> TypeQ
ftToType (FTTypeCon Nothing t) = conT $ mkName $ T.unpack t
-- This type is generated from the Quasi-Quoter.
-- Adding this special case avoids users needing to import Data.Int
ftToType (FTTypeCon (Just "Data.Int") "Int64") = conT ''Int64
ftToType (FTTypeCon (Just m) t) = conT $ mkName $ T.unpack $ T.concat [m, ".", t]
ftToType (FTApp x y) = ftToType x `appT` ftToType y
ftToType (FTList x) = listT `appT` ftToType x

makeColumns :: EntityDef
            -> [(String, TypeQ)]
makeColumns t =
    mkCol (entityId t) : map mkCol (entityFields t)
  where
    mkCol fd = (toS $ fieldDB fd, mkFieldType fd)
    toS = T.unpack . unDBName

-- | Generate all templates about table from persistent table definition.
defineTableFromPersistentWithConfig
    :: Config                   -- ^ Configration for haskell relational record
    -> String                   -- ^ Database schema name
    -> Name                     -- ^ Name of the persistent record type corresponds to the table
    -> [EntityDef]              -- ^ @EntityDef@ which is generated by persistent
    -> Q [Dec]
defineTableFromPersistentWithConfig config schema persistentRecordName entities =
    case filter ((== nameBase persistentRecordName) . T.unpack . unHaskellName . entityHaskell) entities of
        (t:_) -> do
            let columns = makeColumns t
                tableName = T.unpack . unDBName . entityDB $ t
            tblD <- defineTable
                        config
                        schema
                        tableName
                        columns
                        (map (mkName . T.unpack) . entityDerives $ t)
                        [0]
                        (Just 0)
            entI <- makeToPersistEntityInstance config schema tableName persistentRecordName columns
            return $ tblD ++ entI
        _ -> error $ "makeColumns: Table related to " ++ show persistentRecordName ++ " not found"

-- | Generate all templates about table from persistent table definition using default naming rule.
defineTableFromPersistent
    :: Name                     -- ^ Name of the persistent record type corresponds to the table
    -> [EntityDef]              -- ^ @EntityDef@ which is generated by persistent
    -> Q [Dec]
defineTableFromPersistent =
    defineTableFromPersistentWithConfig
        defaultConfig { schemaNameMode = SchemaNotQualified }
        (error "[bug] Database.Persist.Relational.TH.defineTableFromPersistent: schema name must not be used")

makeToPersistEntityInstance :: Config -> String -> String -> Name -> [(String, TypeQ)] -> Q [Dec]
makeToPersistEntityInstance config schema tableName persistentRecordName columns = do
    (typName, dataConName) <- recType <$> reify persistentRecordName
    deriveToPersistEntityForRecord hrrRecordType (conT typName, conE dataConName) columns
  where
#if MIN_VERSION_template_haskell(2, 11, 0)
    recType (TyConI (DataD _ tName [] _ [RecC dcName _] _)) = (tName, dcName)
#else
    recType (TyConI (DataD _ tName [] [RecC dcName _] _)) = (tName, dcName)
#endif
    recType info = error $ "makeToPersistEntityInstance: unexpected record info " ++ show info

    hrrRecordType = recordType (recordConfig . nameConfig $ config) schema tableName

-- | Generate instances for haskell-relational-record.
mkHrrInstances :: [EntityDef] -> Q [Dec]
mkHrrInstances entities =
    concat `fmap` mapM mkHrrInstancesEachEntityDef entities

mkHrrInstancesEachEntityDef :: EntityDef -> Q [Dec]
mkHrrInstancesEachEntityDef = mkPersistablePrimaryKey . entityId

mkPersistablePrimaryKey :: FieldDef -> Q [Dec]
mkPersistablePrimaryKey fd = do
    notNullD <- deriveNotNullType typ
    persistableD <- defineFromToSqlPersistValue typ
    scalarDegD <- defineScalarDegree typ
    showCTermSQLD <- mkShowConstantTermsSQL typ
    toPersistEntityD <- deriveTrivialToPersistEntity typ
    return $ notNullD ++ persistableD ++ scalarDegD ++ showCTermSQLD ++ toPersistEntityD
  where
    typ = mkFieldType fd

mkShowConstantTermsSQL :: TypeQ -> Q [Dec]
mkShowConstantTermsSQL typ =
    [d|instance ShowConstantTermsSQL $typ where
           showConstantTermsSQL' = showConstantTermsSQL' . PersistSql.fromSqlKey|]

mkFieldType :: FieldDef -> TypeQ
mkFieldType fd =
    case nullable . fieldAttrs $ fd of
        Nullable ByMaybeAttr -> conT ''Maybe `appT` typ
        _ -> typ
  where
    typ = ftToType . fieldType $ fd

-- | Generate 'FromSql' 'PersistValue' and 'ToSql' 'PersistValue' instances for 'PersistField' types.
defineFromToSqlPersistValue :: TypeQ -> Q [Dec]
defineFromToSqlPersistValue typ = do
    fromSqlI <-
        [d| instance FromSql PersistValue $typ where
                recordFromSql = valueRecordFromSql unsafePersistValueFromSql |]
    toSqlI <-
        [d| instance ToSql PersistValue $typ where
                recordToSql = valueRecordToSql toPersistValue |]
    return $ fromSqlI ++ toSqlI

deriveTrivialToPersistEntity :: TypeQ -> Q [Dec]
deriveTrivialToPersistEntity typ =
    [d| instance ToPersistEntity $typ $typ where
            recordFromSql' = recordFromSql |]

deriveToPersistEntityForRecord :: TypeQ -> (TypeQ, ExpQ) -> [(String, TypeQ)] -> Q [Dec]
deriveToPersistEntityForRecord hrrTyp (pTyp, pCon) ((_, pKeyTyp):columns) =
    [d| instance ToPersistEntity $hrrTyp (Entity $pTyp) where
            recordFromSql' = Entity <$> (recordFromSql :: RecordFromSql PersistValue $pKeyTyp) <*> $rfsql |]
  where
    fields = map (\(_, typ) -> [| recordFromSql :: RecordFromSql PersistValue $typ |]) columns
    rfsql = foldl' (\s a -> [| $s <*> $a |]) [| pure $pCon |] fields
deriveToPersistEntityForRecord _ _ [] = fail "deriveToPersistEntityForRecord: missing columns"

unsafePersistValueFromSql :: PersistField a => PersistValue -> a
unsafePersistValueFromSql v =
    case fromPersistValue v of
        Left err -> error $ T.unpack err
        Right a -> a

persistValueTypesFromPersistFieldInstances
    :: [String] -- ^ blacklist types
    -> Q (M.Map Name TypeQ)
persistValueTypesFromPersistFieldInstances blacklist = do
    pf <- reify ''PersistField
    pfT <- [t|PersistField|]
    case pf of
       ClassI _ instances -> return . M.fromList $ mapMaybe (go pfT) instances
       unknown -> fail $ "persistValueTypesFromPersistFieldInstances: unknown declaration: " ++ show unknown
  where
#if MIN_VERSION_template_haskell(2, 11, 0)
    go pfT (InstanceD _ [] (AppT insT t@(ConT n)) [])
#else
    go pfT (InstanceD [] (AppT insT t@(ConT n)) [])
#endif
           | insT == pfT
          && nameBase n `notElem` blacklist = Just (n, return t)
    go _ _ = Nothing

persistableWidthTypes :: Q (M.Map Name TypeQ)
persistableWidthTypes =
    reify ''PersistableWidth >>= goI
  where
    unknownDecl decl = fail $ "persistableWidthTypes: Unknown declaration: " ++ show decl
    goI (ClassI _ instances) = return . M.fromList . mapMaybe goD $ instances
    goI unknown = unknownDecl unknown
#if MIN_VERSION_template_haskell(2, 11, 0)
    goD (InstanceD _ _cxt (AppT _insT a@(ConT n)) _defs) = Just (n, return a)
#else
    goD (InstanceD _cxt (AppT _insT a@(ConT n)) _defs) = Just (n, return a)
#endif
    goD _ = Nothing

derivePersistableInstancesFromPersistFieldInstances
    :: [String] -- ^ blacklist types
    -> Q [Dec]
derivePersistableInstancesFromPersistFieldInstances blacklist = do
    types <- persistValueTypesFromPersistFieldInstances blacklist
    pwts <- persistableWidthTypes
    ftsql <- concatMapTypes defineFromToSqlPersistValue types
    toER <- concatMapTypes deriveTrivialToPersistEntity types
    ws <- concatMapTypes deriveNotNullType $ types `M.difference` pwts
    return $ ftsql ++ toER ++ ws
  where
    concatMapTypes :: (Q Type -> Q [Dec]) -> M.Map Name TypeQ -> Q [Dec]
    concatMapTypes f = fmap concat . mapM f . M.elems
