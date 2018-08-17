{-# LANGUAGE TypeApplications #-}

module Smos.Cursor.HeaderSpec where

import Test.Hspec
import Test.Validity

import Smos.Data.Gen ()

import Smos.Cursor.Header
import Smos.Cursor.Header.Gen ()

spec :: Spec
spec = do
    eqSpec @HeaderCursor
    genValidSpec @HeaderCursor
    describe "makeHeaderCursor" $
        it "produces valid cursors" $ producesValidsOnValids makeHeaderCursor
    describe "rebuildHeaderCursor" $ do
        it "produces valid cursors" $ producesValidsOnValids rebuildHeaderCursor
        it "is the inverse of makeHeaderCursor" $
            inverseFunctionsOnValid makeHeaderCursor rebuildHeaderCursor
    describe "headerCursorInsert" $
        it "produces valid cursors" $ producesValidsOnValids2 headerCursorInsert
    describe "headerCursorAppend" $
        it "produces valid cursors" $ producesValidsOnValids2 headerCursorAppend
    describe "headerCursorRemove" $
        it "produces valid cursors" $ producesValidsOnValids headerCursorRemove
    describe "headerCursorDelete" $
        it "produces valid cursors" $ producesValidsOnValids headerCursorDelete
