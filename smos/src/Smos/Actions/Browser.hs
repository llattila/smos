{-# LANGUAGE OverloadedStrings #-}

module Smos.Actions.Browser where

import Cursor.Simple.DirForest
import Data.DirForest
import Path
import Smos.Actions.File
import Smos.Actions.Utils
import Smos.Data
import Smos.Report.Config
import Smos.Types

allPlainBrowserActions :: [Action]
allPlainBrowserActions =
  [ selectBrowser,
    browserSelectPrev,
    browserSelectNext,
    browserToggleCollapse,
    browserToggleCollapseRecursively
  ]

allBrowserUsingCharActions :: [ActionUsing Char]
allBrowserUsingCharActions = []

browserSelectPrev :: Action
browserSelectPrev =
  Action
    { actionName = "browserSelectPrev",
      actionFunc = modifyBrowserCursorM dirForestCursorSelectPrev,
      actionDescription = "Select the previous file or directory in the file browser."
    }

browserSelectNext :: Action
browserSelectNext =
  Action
    { actionName = "browserSelectNext",
      actionFunc = modifyBrowserCursorM dirForestCursorSelectNext,
      actionDescription = "Select the next file or directory in the file browser."
    }

browserToggleCollapse :: Action
browserToggleCollapse =
  Action
    { actionName = "browserToggleCollapse",
      actionFunc = modifyBrowserCursorM dirForestCursorToggle,
      actionDescription = "Select toggle collapsing the currently selected directory"
    }

browserToggleCollapseRecursively :: Action
browserToggleCollapseRecursively =
  Action
    { actionName = "browserToggleCollapseRecursively",
      actionFunc = modifyBrowserCursorM dirForestCursorToggleRecursively,
      actionDescription = "Select toggle collapsing the currently selected directory recursively"
    }

browserEnter :: Action
browserEnter =
  Action
    { actionName = "browserEnter",
      actionFunc = do
        ss <- get
        let ec = smosStateCursor ss
        case editorCursorSelection ec of
          BrowserSelected ->
            case editorCursorBrowserCursor ec of
              Nothing -> pure ()
              Just dfc -> case dirForestCursorSelected dfc of
                (_, FodDir _) -> modifyBrowserCursorM dirForestCursorToggleRecursively
                (rd, FodFile rf ()) -> do
                  saveCurrentSmosFile
                  src <- asks configReportConfig
                  wd <- liftIO $ resolveReportWorkflowDir src
                  let path = wd </> rd </> rf
                  maybeErrOrSmosFile <- liftIO $ readSmosFile path
                  case maybeErrOrSmosFile of
                    Nothing -> pure () -- Shouldn't happen
                    Just errOrSmosFile -> case errOrSmosFile of
                      Left _ -> pure () -- Nothing we can do about this
                      Right sf -> case makeSmosFileCursorEntirely sf of
                        Nothing -> pure () -- TODO: empty file, not sure what to do with this. We should switch to it, I guess
                        Just sfcUnprepared -> do
                          let sfc = smosFileCursorReadyForStartup sfcUnprepared
                          void $ switchToFile path sfc
          _ -> pure (),
      actionDescription = "Enter the file if a file is selected, toggle collapsing the directory if a directory is selected"
    }

selectBrowser :: Action
selectBrowser =
  Action
    { actionName = "selectBrowser",
      actionFunc = do
        src <- asks configReportConfig
        wd <- liftIO $ resolveReportWorkflowDir src
        ad <- liftIO $ resolveReportArchiveDir src
        let filePred fp = fileExtension fp == ".smos"
            dirPred fp = ad /= fp
        df <- readNonHiddenFiltered filePred dirPred wd (\_ -> pure ())
        let dfc = makeDirForestCursor df
        modifyEditorCursor $ \ec ->
          ec
            { editorCursorBrowserCursor = dfc,
              editorCursorSelection = BrowserSelected
            },
      actionDescription = "Save the current file and switch to the file browser."
    }