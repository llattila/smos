{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Smos.Query.OptParse
  ( module Smos.Query.OptParse,
    module Smos.Query.OptParse.Types,
  )
where

import Control.Arrow
import Data.Foldable
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as M
import Data.Maybe
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Time hiding (parseTime)
import Data.Version
import qualified Env
import Options.Applicative as OptParse
import Paths_smos_query
import Smos.Query.Config
import Smos.Query.OptParse.Types
import Smos.Report.Filter
import qualified Smos.Report.OptParse as Report
import Smos.Report.Period
import Smos.Report.Projection
import Smos.Report.Sorter
import Smos.Report.Time
import Smos.Report.TimeBlock
import qualified System.Environment as System

getInstructions :: SmosQueryConfig -> IO Instructions
getInstructions sqc = do
  Arguments c flags <- getArguments
  env <- getEnvironment
  config <- getConfiguration flags env
  combineToInstructions sqc c (Report.flagWithRestFlags flags) (Report.envWithRestEnv env) config

combineToInstructions ::
  SmosQueryConfig -> Command -> Flags -> Environment -> Maybe Configuration -> IO Instructions
combineToInstructions sqc@SmosQueryConfig {..} c Flags {..} Environment {..} mc =
  Instructions <$> getDispatch <*> getSettings
  where
    hideArchiveWithDefault def mflag =
      fromMaybe def $ mflag <|> envHideArchive <|> (mc >>= confHideArchive)
    waitingThresholdWith = fromMaybe 7
    stuckThresholdWith = fromMaybe 21
    getDispatch =
      case c of
        CommandEntry EntryFlags {..} ->
          pure $
            DispatchEntry
              EntrySettings
                { entrySetFilter = entryFlagFilter,
                  entrySetProjection = fromMaybe defaultProjection entryFlagProjection,
                  entrySetSorter = entryFlagSorter,
                  entrySetHideArchive = hideArchiveWithDefault HideArchive entryFlagHideArchive
                }
        CommandReport ReportFlags {..} -> do
          let mprc func = mc >>= confPreparedReportConfiguration >>= func
          pure $
            DispatchReport
              ReportSettings
                { reportSetReportName = reportFlagReportName,
                  reportSetAvailableReports = fromMaybe M.empty $ mprc preparedReportConfAvailableReports
                }
        CommandWaiting WaitingFlags {..} -> do
          let mwc func = mc >>= confWaitingConfiguration >>= func
          pure $
            DispatchWaiting
              WaitingSettings
                { waitingSetFilter = waitingFlagFilter,
                  waitingSetHideArchive = hideArchiveWithDefault HideArchive waitingFlagHideArchive,
                  waitingSetThreshold =
                    waitingThresholdWith $ waitingFlagThreshold <|> mwc waitingConfThreshold
                }
        CommandNext NextFlags {..} ->
          pure $
            DispatchNext
              NextSettings
                { nextSetFilter = nextFlagFilter,
                  nextSetHideArchive = hideArchiveWithDefault HideArchive nextFlagHideArchive
                }
        CommandClock ClockFlags {..} ->
          pure $
            DispatchClock
              ClockSettings
                { clockSetFilter = clockFlagFilter,
                  clockSetPeriod = fromMaybe AllTime clockFlagPeriodFlags,
                  clockSetBlock = fromMaybe DayBlock clockFlagBlockFlags,
                  clockSetOutputFormat = fromMaybe OutputPretty clockFlagOutputFormat,
                  clockSetClockFormat = case clockFlagClockFormat of
                    Nothing -> ClockFormatTemporal TemporalMinutesResolution
                    Just cffs ->
                      case cffs of
                        ClockFormatTemporalFlag res ->
                          ClockFormatTemporal $ fromMaybe TemporalMinutesResolution res
                        ClockFormatDecimalFlag res ->
                          ClockFormatDecimal $ fromMaybe (DecimalResolution 2) res,
                  clockSetReportStyle = fromMaybe ClockForest clockFlagReportStyle,
                  clockSetHideArchive = hideArchiveWithDefault Don'tHideArchive clockFlagHideArchive
                }
        CommandAgenda AgendaFlags {..} -> do
          let period =
                -- Note [Agenda command defaults]
                -- The default here is 'AllTime' for good reason.
                --
                -- You may think that 'Today' is a better default because smos-calendar-import fills up
                -- your agenda too much for it to be useful.
                --
                -- However, as a beginner you want to be able to run smos-query agenda to see your
                -- SCHEDULED and DEADLINE timestamps in the near future.
                -- By the time users figure out how to use smos-calendar-import, they will probably
                -- either already use "smos-query work" or have an alias for 'smos-query agenda --today'
                -- if they need it.
                fromMaybe AllTime agendaFlagPeriod
          let block =
                -- See Note [Agenda command defaults]
                let defaultBlock = case period of
                      AllTime -> OneBlock
                      LastYear -> MonthBlock
                      ThisYear -> MonthBlock
                      NextYear -> MonthBlock
                      LastMonth -> WeekBlock
                      ThisMonth -> WeekBlock
                      NextMonth -> WeekBlock
                      LastWeek -> DayBlock
                      ThisWeek -> DayBlock
                      NextWeek -> DayBlock
                      _ -> OneBlock
                 in fromMaybe defaultBlock agendaFlagBlock
          pure $
            DispatchAgenda
              AgendaSettings
                { agendaSetFilter = agendaFlagFilter,
                  agendaSetHistoricity = fromMaybe HistoricalAgenda agendaFlagHistoricity,
                  agendaSetBlock = block,
                  agendaSetHideArchive = hideArchiveWithDefault HideArchive agendaFlagHideArchive,
                  agendaSetPeriod = period
                }
        CommandWork WorkFlags {..} -> do
          let wc func = func <$> (mc >>= confWorkConfiguration)
              mwc func = mc >>= confWorkConfiguration >>= func
              combineMaybe :: (a -> a -> a) -> Maybe a -> Maybe a -> Maybe a
              combineMaybe f m1 m2 =
                case (m1, m2) of
                  (Nothing, Nothing) -> Nothing
                  (Just a, Nothing) -> Just a
                  (Nothing, Just a) -> Just a
                  (Just a1, Just a2) -> Just $ f a1 a2
          pure $
            DispatchWork
              WorkSettings
                { workSetContext = workFlagContext,
                  workSetTimeProperty = mwc workConfTimeFilterProperty,
                  workSetTime = workFlagTime,
                  workSetFilter = workFlagFilter,
                  workSetChecks = fromMaybe S.empty $ wc workConfChecks,
                  workSetProjection =
                    fromMaybe defaultProjection $
                      combineMaybe (<>) (mwc workConfProjection) workFlagProjection,
                  workSetSorter = mwc workConfSorter <|> workFlagSorter,
                  workSetHideArchive = hideArchiveWithDefault HideArchive workFlagHideArchive,
                  workSetWaitingThreshold = waitingThresholdWith $ workFlagWaitingThreshold <|> (mc >>= confWaitingConfiguration >>= waitingConfThreshold),
                  workSetStuckThreshold = stuckThresholdWith $ workFlagStuckThreshold <|> (mc >>= confStuckConfiguration >>= stuckConfThreshold)
                }
        CommandProjects ProjectsFlags {..} ->
          pure $ DispatchProjects ProjectsSettings {projectsSetFilter = projectsFlagFilter}
        CommandStuck StuckFlags {..} -> do
          let msc func = mc >>= confStuckConfiguration >>= func
          pure $
            DispatchStuck
              StuckSettings
                { stuckSetFilter = stuckFlagFilter,
                  stuckSetThreshold =
                    stuckThresholdWith $ stuckFlagThreshold <|> msc stuckConfThreshold
                }
        CommandLog LogFlags {..} ->
          pure $
            DispatchLog
              LogSettings
                { logSetFilter = logFlagFilter,
                  logSetPeriod = fromMaybe Today logFlagPeriodFlags,
                  logSetBlock = fromMaybe DayBlock logFlagBlockFlags,
                  logSetHideArchive = hideArchiveWithDefault Don'tHideArchive logFlagHideArchive
                }
        CommandTags TagsFlags {..} ->
          pure $ DispatchTags TagsSettings {tagsSetFilter = tagsFlagFilter}
        CommandStats StatsFlags {..} ->
          pure $
            DispatchStats StatsSettings {statsSetPeriod = fromMaybe AllTime statsFlagPeriodFlags}
    getSettings = do
      src <-
        Report.combineToConfig
          smosQueryConfigReportConfig
          flagReportFlags
          envReportEnvironment
          (confReportConf <$> mc)
      pure $
        sqc
          { smosQueryConfigReportConfig = src
          }

getEnvironment :: IO (Report.EnvWithConfigFile Environment)
getEnvironment = Env.parse (Env.header "Environment") prefixedEnvironmentParser

prefixedEnvironmentParser :: Env.Parser Env.Error (Report.EnvWithConfigFile Environment)
prefixedEnvironmentParser = Env.prefixed "SMOS_" environmentParser

environmentParser :: Env.Parser Env.Error (Report.EnvWithConfigFile Environment)
environmentParser =
  Report.envWithConfigFileParser $
    Environment
      <$> Report.environmentParser
      <*> Env.var (fmap Just . ignoreArchiveReader) "IGNORE_ARCHIVE" (mE <> Env.help "whether to ignore the archive")
  where
    ignoreArchiveReader = \case
      "True" -> Right HideArchive
      "False" -> Right Don'tHideArchive
      _ -> Left $ Env.UnreadError "Must be 'True' or 'False' if set"
    mE = Env.def Nothing <> Env.keep

getConfiguration :: Report.FlagsWithConfigFile Flags -> Report.EnvWithConfigFile Environment -> IO (Maybe Configuration)
getConfiguration = Report.getConfiguration

getArguments :: IO Arguments
getArguments = do
  args <- System.getArgs
  let result = runArgumentsParser args
  handleParseResult result

runArgumentsParser :: [String] -> ParserResult Arguments
runArgumentsParser = execParserPure prefs_ argParser
  where
    prefs_ =
      defaultPrefs
        { prefShowHelpOnError = True,
          prefShowHelpOnEmpty = True
        }

argParser :: ParserInfo Arguments
argParser = info (helper <*> parseArgs) help_
  where
    help_ = fullDesc <> progDesc description
    description = "Smos Query Tool version " <> showVersion version

parseArgs :: Parser Arguments
parseArgs = Arguments <$> parseCommand <*> Report.parseFlagsWithConfigFile parseFlags

parseCommand :: Parser Command
parseCommand =
  hsubparser $
    mconcat
      [ command "entry" parseCommandEntry,
        command "report" parseCommandReport,
        command "work" parseCommandWork,
        command "waiting" parseCommandWaiting,
        command "next" parseCommandNext,
        command "clock" parseCommandClock,
        command "agenda" parseCommandAgenda,
        command "projects" parseCommandProjects,
        command "stuck" parseCommandStuck,
        command "log" parseCommandLog,
        command "stats" parseCommandStats,
        command "tags" parseCommandTags
      ]

parseCommandEntry :: ParserInfo Command
parseCommandEntry = info parser modifier
  where
    modifier = fullDesc <> progDesc "Select entries based on a given filter"
    parser =
      CommandEntry
        <$> ( EntryFlags <$> parseFilterArgsRel <*> parseProjectionArgs <*> parseSorterArgs
                <*> parseHideArchiveFlag
            )

parseCommandReport :: ParserInfo Command
parseCommandReport = info parser modifier
  where
    modifier = fullDesc <> progDesc "Run preconfigured reports"
    parser =
      CommandReport
        <$> ( ReportFlags
                <$> argument
                  (Just <$> str)
                  (mconcat [value Nothing, metavar "REPORT", help "The preconfigured report to run"])
            )

parseCommandWork :: ParserInfo Command
parseCommandWork = info parser modifier
  where
    modifier = fullDesc <> progDesc "Show the work overview"
    parser =
      CommandWork
        <$> ( WorkFlags
                <$> parseContextNameArg
                <*> parseTimeFilterArg
                <*> parseFilterOptionsRel
                <*> parseProjectionArgs
                <*> parseSorterArgs
                <*> parseHideArchiveFlag
                <*> parseWorkWaitingThresholdFlag
                <*> parseWorkStuckThresholdFlag
            )

parseWorkWaitingThresholdFlag :: Parser (Maybe Word)
parseWorkWaitingThresholdFlag =
  option
    (Just <$> auto)
    (mconcat [long "waiting-threshold", value Nothing, help "The threshold at which to color waiting entries red"])

parseWorkStuckThresholdFlag :: Parser (Maybe Word)
parseWorkStuckThresholdFlag =
  option
    (Just <$> auto)
    (mconcat [long "stuck-threshold", value Nothing, help "The threshold at which to color stuck projects red"])

parseCommandWaiting :: ParserInfo Command
parseCommandWaiting = info parser modifier
  where
    modifier = fullDesc <> progDesc "Print the \"WAITING\" tasks"
    parser =
      CommandWaiting
        <$> (WaitingFlags <$> parseFilterArgsRel <*> parseHideArchiveFlag <*> parseWaitingThresholdFlag)

parseWaitingThresholdFlag :: Parser (Maybe Word)
parseWaitingThresholdFlag =
  option
    (Just <$> auto)
    (mconcat [long "threshold", value Nothing, help "The threshold at which to color waiting entries red"])

parseCommandNext :: ParserInfo Command
parseCommandNext = info parser modifier
  where
    modifier = fullDesc <> progDesc "Print the next actions"
    parser = CommandNext <$> (NextFlags <$> parseFilterArgsRel <*> parseHideArchiveFlag)

parseCommandClock :: ParserInfo Command
parseCommandClock = info parser modifier
  where
    modifier = fullDesc <> progDesc "Print the clock table"
    parser =
      CommandClock
        <$> ( ClockFlags <$> parseFilterArgsRel <*> parsePeriod <*> parseTimeBlock <*> parseOutputFormat
                <*> parseClockFormatFlags
                <*> parseClockReportStyle
                <*> parseHideArchiveFlag
            )

parseClockFormatFlags :: Parser (Maybe ClockFormatFlags)
parseClockFormatFlags =
  optional
    ( flag' ClockFormatTemporalFlag (long "temporal-resolution") <*> parseTemporalClockResolution
        <|> flag' ClockFormatDecimalFlag (long "decimal-resolution") <*> parseDecimalClockResolution
    )

parseTemporalClockResolution :: Parser (Maybe TemporalClockResolution)
parseTemporalClockResolution =
  optional
    ( flag' TemporalSecondsResolution (long "seconds-resolution")
        <|> flag' TemporalMinutesResolution (long "minutes-resolution")
        <|> flag' TemporalHoursResolution (long "hours-resolution")
    )

parseDecimalClockResolution :: Parser (Maybe DecimalClockResolution)
parseDecimalClockResolution =
  optional
    ( flag' DecimalQuarterResolution (long "quarters-resolution")
        <|> (flag' DecimalResolution (long "resolution") <*> argument auto (help "significant digits"))
        <|> flag' DecimalHoursResolution (long "hours-resolution")
    )

parseClockReportStyle :: Parser (Maybe ClockReportStyle)
parseClockReportStyle =
  optional (flag' ClockForest (long "forest") <|> flag' ClockFlat (long "flat"))

parseCommandAgenda :: ParserInfo Command
parseCommandAgenda = info parser modifier
  where
    modifier = fullDesc <> progDesc "Print the agenda"
    parser =
      CommandAgenda
        <$> ( AgendaFlags <$> parseFilterArgsRel <*> parseHistoricityFlag <*> parseTimeBlock
                <*> parseHideArchiveFlag
                <*> parsePeriod
            )

parseCommandProjects :: ParserInfo Command
parseCommandProjects = info parser modifier
  where
    modifier = fullDesc <> progDesc "Print the projects overview"
    parser = CommandProjects <$> (ProjectsFlags <$> parseProjectFilterArgs)

parseCommandStuck :: ParserInfo Command
parseCommandStuck = info parser modifier
  where
    modifier = fullDesc <> progDesc "Print the stuck projects overview"
    parser = CommandStuck <$> (StuckFlags <$> parseProjectFilterArgs <*> parseStuckThresholdFlag)

parseStuckThresholdFlag :: Parser (Maybe Word)
parseStuckThresholdFlag =
  option
    (Just <$> auto)
    (mconcat [long "threshold", value Nothing, help "The threshold at which to color stuck projects red"])

parseCommandLog :: ParserInfo Command
parseCommandLog = info parser modifier
  where
    modifier = fullDesc <> progDesc "Print a log of what has happened."
    parser =
      CommandLog
        <$> (LogFlags <$> parseFilterArgsRel <*> parsePeriod <*> parseTimeBlock <*> parseHideArchiveFlag)

parseCommandStats :: ParserInfo Command
parseCommandStats = info parser modifier
  where
    modifier = fullDesc <> progDesc "Print the stats actions and warn if a file does not have one."
    parser = CommandStats <$> (StatsFlags <$> parsePeriod)

parseCommandTags :: ParserInfo Command
parseCommandTags = info parser modifier
  where
    modifier = fullDesc <> progDesc "Print all the tags that are in use"
    parser = CommandTags <$> (TagsFlags <$> parseFilterArgsRel)

parseFlags :: Parser Flags
parseFlags = Flags <$> Report.parseFlags

parseHistoricityFlag :: Parser (Maybe AgendaHistoricity)
parseHistoricityFlag =
  optional (flag' HistoricalAgenda (long "historical") <|> flag' FutureAgenda (long "future"))

parseHideArchiveFlag :: Parser (Maybe HideArchive)
parseHideArchiveFlag =
  optional
    ( flag' HideArchive (mconcat [long "hide-archived", help "ignore archived files."])
        <|> flag'
          Don'tHideArchive
          (mconcat [short 'a', long "show-archived", help "Don't ignore archived files."])
    )

parseContextNameArg :: Parser (Maybe ContextName)
parseContextNameArg =
  optional $ argument (ContextName <$> str) (mconcat [metavar "CONTEXT", help "The context that you are in"])

parseTimeFilterArg :: Parser (Maybe Time)
parseTimeFilterArg =
  optional $
    argument
      (eitherReader (parseTime . T.pack))
      (mconcat [metavar "TIME_FILTER", help "A filter to filter by time"])

parseFilterOptionsRel :: Parser (Maybe EntryFilterRel)
parseFilterOptionsRel =
  fmap foldFilterAnd . NE.nonEmpty
    <$> many
      ( option
          (eitherReader (left (T.unpack . prettyFilterParseError) . parseEntryFilterRel . T.pack))
          (mconcat [short 'f', long "filter", metavar "FILTER", help "A filter to filter entries by"])
      )

parseFilterArgsRel :: Parser (Maybe EntryFilterRel)
parseFilterArgsRel =
  fmap foldFilterAnd . NE.nonEmpty
    <$> many
      ( argument
          (eitherReader (left (T.unpack . prettyFilterParseError) . parseEntryFilterRel . T.pack))
          (mconcat [metavar "FILTER", help "A filter to filter entries by"])
      )

parseProjectFilterArgs :: Parser (Maybe ProjectFilter)
parseProjectFilterArgs =
  fmap foldFilterAnd . NE.nonEmpty
    <$> many
      ( argument
          (eitherReader (left (T.unpack . prettyFilterParseError) . parseProjectFilter . T.pack))
          (mconcat [metavar "FILTER", help "A filter to filter projects by"])
      )

parseProjectionArgs :: Parser (Maybe (NonEmpty Projection))
parseProjectionArgs =
  NE.nonEmpty . catMaybes
    <$> many
      ( option
          (Just <$> maybeReader (parseProjection . T.pack))
          ( mconcat
              [ long "add-column",
                long "project",
                metavar "PROJECTION",
                help "A projection to project entries onto fields"
              ]
          )
      )

parseSorterArgs :: Parser (Maybe Sorter)
parseSorterArgs =
  fmap (foldl1 AndThen) . NE.nonEmpty . catMaybes
    <$> many
      ( option
          (Just <$> maybeReader (parseSorter . T.pack))
          (mconcat [long "sort", metavar "SORTER", help "A sorter to sort entries by"])
      )

parseTimeBlock :: Parser (Maybe TimeBlock)
parseTimeBlock =
  optional
    ( choices
        [ flag' DayBlock $ mconcat [long "day-block", help "blocks of one day"],
          flag' WeekBlock $ mconcat [long "week-block", help "blocks of one week"],
          flag' MonthBlock $ mconcat [long "month-block", help "blocks of one month"],
          flag' YearBlock $ mconcat [long "year-block", help "blocks of one year"],
          flag' OneBlock $ mconcat [long "one-block", help "a single block"]
        ]
    )

parsePeriod :: Parser (Maybe Period)
parsePeriod =
  parseBeginEnd
    <|> optional
      ( choices
          [ flag' Yesterday (mconcat [long "yesterday", help "yesterday"]),
            flag' Today (mconcat [long "today", help "today"]),
            flag' Tomorrow (mconcat [long "tomorrow", help "tomorrow"]),
            flag' LastWeek (mconcat [long "last-week", help "last week"]),
            flag' ThisWeek (mconcat [long "this-week", help "this week"]),
            flag' NextWeek (mconcat [long "next-week", help "next week"]),
            flag' LastMonth (mconcat [long "last-month", help "last month"]),
            flag' ThisMonth (mconcat [long "this-month", help "this month"]),
            flag' NextMonth (mconcat [long "next-month", help "next month"]),
            flag' LastYear (mconcat [long "last-year", help "last year"]),
            flag' ThisYear (mconcat [long "this-year", help "this year"]),
            flag' NextYear (mconcat [long "next-year", help "next year"]),
            flag' AllTime (mconcat [long "all-time", help "all time"])
          ]
      )
  where
    parseBeginEnd :: Parser (Maybe Period)
    parseBeginEnd =
      ( \mb me ->
          case (mb, me) of
            (Nothing, Nothing) -> Nothing
            (Just begin, Nothing) -> Just (BeginOnly begin)
            (Nothing, Just end) -> Just (EndOnly end)
            (Just begin, Just end) -> Just (BeginEnd begin end)
      )
        <$> option
          (Just <$> maybeReader parseLocalBegin)
          (mconcat [value Nothing, long "begin", metavar "LOCALTIME", help "start time (inclusive)"])
        <*> option
          (Just <$> maybeReader parseLocalEnd)
          (mconcat [value Nothing, long "end", metavar "LOCALTIME", help "end tiem (inclusive)"])
    parseLocalBegin :: String -> Maybe LocalTime
    parseLocalBegin s = LocalTime <$> parseLocalDay s <*> pure midnight <|> parseExactly s
    parseLocalEnd :: String -> Maybe LocalTime
    parseLocalEnd s =
      (LocalTime <$> (addDays 1 <$> parseLocalDay s) <*> pure midnight) <|> parseExactly s
    parseExactly :: String -> Maybe LocalTime
    parseExactly s =
      parseTimeM True defaultTimeLocale "%F %R" s <|> parseTimeM True defaultTimeLocale "%F %T" s
    parseLocalDay :: String -> Maybe Day
    parseLocalDay = parseTimeM True defaultTimeLocale "%F"

parseOutputFormat :: Parser (Maybe OutputFormat)
parseOutputFormat =
  optional
    ( choices
        [ flag' OutputPretty $ mconcat [long "pretty", help "pretty text"],
          flag' OutputYaml $ mconcat [long "yaml", help "Yaml"],
          flag' OutputJSON $ mconcat [long "json", help "single-line JSON"],
          flag' OutputJSONPretty $ mconcat [long "pretty-json", help "pretty JSON"]
        ]
    )

choices :: [Parser a] -> Parser a
choices = asum
