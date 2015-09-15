{-# LANGUAGE OverloadedStrings,ScopedTypeVariables,DeriveGeneric,DeriveAnyClass #-}

module Stabalize.Herbie
    where

import Control.Applicative
import Control.Exception
import Control.DeepSeq
import Data.List
import Data.String
import qualified Data.Text as T
import Database.SQLite.Simple
import Database.SQLite.Simple.FromRow
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.ToField
import GHC.Generics hiding (modName)
import System.Directory
import System.Process

import Stabalize.MathInfo
import Stabalize.MathExpr

import Prelude

-- | Given a MathExpr, return a numerically stable version.
stabilizeMathExpr :: DbgInfo -> MathExpr -> IO (StabilizerResult MathExpr)
stabilizeMathExpr dbgInfo cmdin = do
    let (cmdinLisp,varmap) = getCanonicalLispCmd cmdin
    res <- stabilizeLisp dbgInfo cmdinLisp
    let res' = res
            { cmdin  = cmdin
            , cmdout = herbieOpsToHaskellOps $ fromCanonicalLispCmd (cmdout res,varmap)
            }
--     putStrLn $ "stabilizeLisp:  "++cmdout res
--     putStrLn $ "stabilizeLisp:  "++mathExpr2lisp (cmdout res')
--     putStrLn $ "stabilizeLisp': "++mathExpr2lisp (fromCanonicalLispCmd (cmdout res,varmap))
    return res'

-- | Given a Lisp command, return a numerically stable version.
-- It first checks if the command is in the global database;
-- if it's not, then it runs "execHerbie".
stabilizeLisp :: DbgInfo -> String -> IO (StabilizerResult String)
stabilizeLisp dbgInfo cmdin = do
    dbResult <- lookupDatabase cmdin
    ret <- case dbResult of
        Just x -> do
            return x
        Nothing -> do
            putStrLn "  Not found in database.  Running Herbie..."
            res <- execHerbie cmdin
            insertDatabase res
            return res
    insertDatabaseDbgInfo dbgInfo ret
    return ret
--     if not $ "(if " `isInfixOf` cmdout ret
--         then return ret
--         else do
--             putStrLn "WARNING: Herbie's output contains if statements, which aren't yet supported"
--             putStrLn "WARNING: Using original numerically unstable equation."
--             return $ ret
--                 { errout = errin ret
--                 , cmdout = cmdin
--                 }
--     return $ ret { cmdout = "(+ herbie0 herbie1)" }
--     return $ ret { cmdout = "(if (> herbie0 herbie1) herbie0 herbie1)" }

-- | Run the `herbie` command and return the result
execHerbie :: String -> IO (StabilizerResult String)
execHerbie lisp = do

    -- build the command string we will pass to Herbie
    let varstr = "("++(intercalate " " $ lisp2vars lisp)++")"
        stdin = "(herbie-test "++varstr++" \"cmd\" "++lisp++") \n"

    -- launch Herbie with a fixed seed to ensure reproducible builds
    (_,stdout,stderr) <- readProcessWithExitCode
        "herbie-exec"
        [ "-r", "#(1461197085 2376054483 1553562171 1611329376 2497620867 2308122621)" ]
        stdin

    -- try to parse Herbie's output;
    -- if we can't parse it, that means Herbie had an error and we should abort gracefully
    ret <- try $ do
        let (line1:line2:line3:_) = lines stdout
        let ret = StabilizerResult
                { errin
                    = read
                    $ drop 1
                    $ dropWhile (/=':')
                    $ line1
                , errout
                    = read
                    $ drop 1
                    $ dropWhile (/=':')
                    $ line2
                , cmdin
                    = lisp
                , cmdout
                    = (!!2)
                    $ groupByParens
                    $ init
                    $ tail
                    $ line3
                }
        deepseq ret $ return ret

    case ret of
        Left (SomeException e) -> do
            putStrLn $ "WARNING in execHerbie: "++show e
            putStrLn $ "WARNING in execHerbie: stdin="++stdin
            putStrLn $ "WARNING in execHerbie: stdout="++stdout
            return $ StabilizerResult
                { errin  = 0/0
                , errout = 0/0
                , cmdin  = lisp
                , cmdout = lisp
                }
        Right x -> return x

-- | The result of running Herbie
data StabilizerResult a = StabilizerResult
    { cmdin  :: !a
    , cmdout :: !a
    , errin  :: !Double
    , errout :: !Double
    }
    deriving (Show,Generic,NFData)

instance FromField a => FromRow (StabilizerResult a) where
    fromRow = StabilizerResult <$> field <*> field <*> field <*> field

instance ToField a => ToRow (StabilizerResult a) where
    toRow (StabilizerResult cmdin cmdout errin errout) = toRow (cmdin, cmdout, errin, errout)

-- | Check the database to see if we already know the answer for running Herbie
lookupDatabase :: String -> IO (Maybe (StabilizerResult String))
lookupDatabase cmdin = do
    ret <- try $ do
        dirname <- getAppUserDataDirectory "Stabalizer"
        createDirectoryIfMissing True dirname
        conn <- open $ dirname++"/Stabalizer.db"
        res <- queryNamed
            conn
            "SELECT cmdin,cmdout,errin,errout from StabilizerResults where cmdin = :cmdin"
            [":cmdin" := cmdin]
            :: IO [StabilizerResult String]
        close conn
        return $ case res of
            [x] -> Just x
            []  -> Nothing
    case ret of
        Left (SomeException e) -> do
            putStrLn $ "WARNING in lookupDatabase: "++show e
            return Nothing
        Right x -> return x

-- | Inserts a "StabilizerResult" into the global database of commands
insertDatabase :: StabilizerResult String -> IO ()
insertDatabase res = do
    ret <- try $ do
        dirname <- getAppUserDataDirectory "Stabalizer"
        createDirectoryIfMissing True dirname
        conn <- open $ dirname++"/Stabalizer.db"
        execute_ conn $ fromString $
            "CREATE TABLE IF NOT EXISTS StabilizerResults "
            ++"( id INTEGER PRIMARY KEY"
            ++", cmdin  TEXT UNIQUE NOT NULL"
            ++", cmdout TEXT        NOT NULL"
            ++", errin  DOUBLE      NOT NULL"
            ++", errout DOUBLE      NOT NULL"
            ++")"
        execute_ conn "CREATE INDEX IF NOT EXISTS StabilizerResultsIndex ON StabilizerResults(cmdin)"
        execute conn "INSERT INTO StabilizerResults (cmdin,cmdout,errin,errout) VALUES (?,?,?,?)" res
        close conn
    case ret of
        Left (SomeException e) -> putStrLn $ "WARNING in insertDatabase: "++show e
        Right _ -> return ()
    return ()


-- | This information gets stored in a separate db table for debugging purposes
data DbgInfo = DbgInfo
    { dbgComments   :: String
    , modName       :: String
    , functionName  :: String
    , functionType  :: String
    }

insertDatabaseDbgInfo :: DbgInfo -> StabilizerResult String -> IO ()
insertDatabaseDbgInfo dbgInfo res = do
    ret <- try $ do
        dirname <- getAppUserDataDirectory "Stabalizer"
        createDirectoryIfMissing True dirname
        conn <- open $ dirname++"/Stabalizer.db"
        execute_ conn $ fromString $
            "CREATE TABLE IF NOT EXISTS DbgInfo "
            ++"( id INTEGER PRIMARY KEY"
            ++", resid INTEGER NOT NULL"
            ++", dbgComments TEXT"
            ++", modName TEXT"
            ++", functionName TEXT"
            ++", functionType TEXT"
            ++")"
        res <- queryNamed
            conn
            "SELECT id,cmdout from StabilizerResults where cmdin = :cmdin"
            [":cmdin" := (cmdin res)]
            :: IO [(Int,String)]
        execute conn "INSERT INTO DbgInfo (resid,dbgComments,modName,functionName,functionType) VALUES (?,?,?,?,?)" (fst $ head res,dbgComments dbgInfo,modName dbgInfo,functionName dbgInfo,functionType dbgInfo)
        close conn
    case ret of
        Left (SomeException e) -> putStrLn $ "WARNING in insertDatabaseDbgInfo: "++show e
        Right _ -> return ()
    return ()
