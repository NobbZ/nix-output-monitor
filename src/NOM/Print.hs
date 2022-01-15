{-# LANGUAGE DataKinds #-}

module NOM.Print (stateToText) where

import Relude

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (NominalDiffTime, UTCTime, defaultTimeLocale, diffUTCTime, formatTime)

import Data.Generics.Sum (_Ctor)
import Data.Tree (Forest)
import qualified Data.Tree as Tree
import NOM.Parser (Derivation (toStorePath), Host (Localhost), StorePath (name))
import NOM.Print.Table (Entry, blue, bold, cells, cyan, disp, dummy, green, grey, header, label, magenta, markup, markups, prependLines, printAlignedSep, red, text, yellow)
import NOM.Print.Tree (showForest)
import NOM.State (BuildForest, BuildState (..), BuildStatus (Building, Built, Failed), DerivationNode (DerivationNode, derivation), StorePathNode (StorePathNode, path))
import NOM.State.Tree (aggregateTree, collapseForestN, replaceDuplicates)
import NOM.Update (collapseMultimap, countPaths)
import NOM.Util ((.>), (<.>>), (<<|>>>), (<|>>))
import Optics (has)
import System.Console.Terminal.Size (Window)
import qualified System.Console.Terminal.Size as Window

vertical, lowerleft, upperleft, horizontal, down, up, clock, running, done, bigsum, goal, warning, todo, leftT, average :: Text
vertical = "┃"
lowerleft = "┗"
upperleft = "┏"
leftT = "┣"
horizontal = "━"
down = "⬇"
up = "⬆"
clock = "⏲"
running = "▶"
done = "✔"
todo = "⏳"
warning = "⚠"
goal = "🏁"
average = "∅"
bigsum = "∑"

showCond :: Monoid m => Bool -> m -> m
showCond = memptyIfFalse

stateToText :: Maybe (Window Int) -> UTCTime -> BuildState -> Text
stateToText maybeWindow now buildState@BuildState{..}
  | not inputReceived = time <> showCond (diffUTCTime now startTime > 30) (markup grey " nom hasn‘t detected any input. Have you redirected nix-build stderr into nom? (See the README for details.)")
  | not anythingGoingOn = time
  | otherwise =
    buildsDisplay
      <> table
      <> unlines errors
 where
  anythingGoingOn = totalBuilds + downloadsDone + numOutstandingDownloads + numFailedBuilds > 0
  buildsDisplay =
    showCond
      anythingGoingOn
      $ prependLines
        (upperleft <> horizontal)
        (vertical <> " ")
        (vertical <> " ")
        (printBuilds maybeWindow now buildForest)
        <> "\n"
  table =
    prependLines
      (leftT <> stimes (3 :: Int) horizontal <> " ")
      (vertical <> "    ")
      (lowerleft <> horizontal <> " " <> bigsum <> " ")
      $ printAlignedSep innerTable
  innerTable = fromMaybe (one (text "")) (nonEmpty headers) :| tableRows
  headers =
    (cells 3 <$> optHeader showBuilds "Builds")
      <> (cells 2 <$> optHeader showDownloads "Downloads")
      <> optHeader showUploads "Uploads"
      <> optHeader showHosts "Host"
  optHeader cond = showCond cond . one . bold . header :: Text -> [Entry]
  tableRows =
    showCond
      showHosts
      (printHosts buildState showBuilds showDownloads showUploads)
      <> maybeToList (nonEmpty lastRow)
  lastRow =
    showCond
      showBuilds
      [ nonZeroBold numRunningBuilds (yellow (label running (disp numRunningBuilds)))
      , nonZeroBold numCompletedBuilds (green (label done (disp numCompletedBuilds)))
      , nonZeroBold numOutstandingBuilds (blue (label todo (disp numOutstandingBuilds)))
      ]
      <> showCond
        showDownloads
        [ nonZeroBold downloadsDone (green (label down (disp downloadsDone)))
        , nonZeroBold numOutstandingDownloads . blue . label todo . disp $ numOutstandingDownloads
        ]
      <> showCond showUploads [text ""]
      <> (one . bold . lastBuildColor . header $ lastBuildText <> time)
  lastBuildIcon drv
    | drv `Set.member` outstandingBuilds = (id, todo)
  lastBuildIcon drv
    | drv `Set.member` completedBuildsSet = (green, goal)
  lastBuildIcon drv
    | setAny ((== drv) . fst) runningBuildsSet = (id, running)
  lastBuildIcon _ = (red, warning)
  (lastBuildColor, lastBuildText) =
    lastPlannedBuild & maybe (id, "") \build ->
      let (c, i) = lastBuildIcon build in (c, i <> " " <> (name . toStorePath) build <> " ")

  showHosts = numHosts > 0
  showBuilds = totalBuilds > 0
  showDownloads = downloadsDone + length outstandingDownloads > 0
  showUploads = countPaths completedUploads > 0
  numFailedBuilds = Set.size failedBuildsSet
  numOutstandingDownloads = Set.size outstandingDownloads
  numHosts =
    Set.size (Set.filter (/= Localhost) (Map.keysSet runningBuilds <> Map.keysSet completedBuilds <> Map.keysSet completedUploads))
  numRunningBuilds = Set.size runningBuildsSet
  failedBuildsSet = collapseMultimap failedBuilds
  completedBuildsSet = collapseMultimap completedBuilds
  runningBuildsSet = collapseMultimap runningBuilds
  numCompletedBuilds = Set.size completedBuildsSet
  numOutstandingBuilds = length outstandingBuilds
  totalBuilds = numOutstandingBuilds + numRunningBuilds + numCompletedBuilds
  downloadsDone = countPaths completedDownloads
  time = clock <> " " <> timeDiff now startTime

setAny :: (a -> Bool) -> Set a -> Bool
setAny pred' = Set.foldl' (\y x -> pred' x || y) False

printHosts :: BuildState -> Bool -> Bool -> Bool -> [NonEmpty Entry]
printHosts BuildState{runningBuilds, completedBuilds, completedDownloads, completedUploads} showBuilds showDownloads showUploads =
  mapMaybe nonEmpty $ labelForHost <$> hosts
 where
  labelForHost h =
    showCond
      showBuilds
      [ nonZeroShowBold numRunningBuilds (yellow (label running (disp numRunningBuilds)))
      , nonZeroShowBold doneBuilds (green (label done (disp doneBuilds)))
      , dummy
      ]
      <> showCond
        showDownloads
        [nonZeroShowBold downloads (green (label down (disp downloads))), dummy]
      <> showCond
        showUploads
        [nonZeroShowBold uploads (green (label up (disp uploads)))]
      <> one (magenta (header (toText h)))
   where
    uploads = l h completedUploads
    downloads = l h completedDownloads
    numRunningBuilds = l h runningBuilds
    doneBuilds = l h completedBuilds
  hosts =
    sort
      . toList
      $ Map.keysSet runningBuilds
        <> Map.keysSet completedBuilds
        <> Map.keysSet completedUploads
        <> Map.keysSet completedDownloads
  l host = Set.size . Map.findWithDefault mempty host

nonZeroShowBold :: Int -> Entry -> Entry
nonZeroShowBold num = if num > 0 then bold else const dummy
nonZeroBold :: Int -> Entry -> Entry
nonZeroBold num = if num > 0 then bold else id

targetRatio :: Int
targetRatio = 3

type LinkTreeNode = Either (Either DerivationNode StorePathNode) (Either Derivation StorePath)
type ElisionTreeNode = (Maybe LinkTreeNode, Elision)
type Elision = Set Summary

data Summary
  = SummaryBuildDone Derivation
  | SummaryBuildWaiting Derivation
  | SummaryBuildRunning Derivation
  | SummaryBuildFailed Derivation
  | SummaryDownloadWaiting StorePath
  | SummaryDownloadRunning StorePath
  | SummaryDownloadDone StorePath
  | SummaryUploadRunning StorePath
  | SummaryUploadDone StorePath
  deriving (Eq, Ord, Show, Generic)

possibleElisions :: [LinkTreeNode -> Bool]
possibleElisions =
  [ \case
      Right (Right _) -> True
      _ -> False
  , \case
      Right (Left _) -> True
      _ -> False
  , \case
      Left (Left (DerivationNode _ (Just (_, Built{})))) -> True
      _ -> False
  , \case
      Left (Left (DerivationNode _ Nothing)) -> True
      _ -> False
  ]

summarize :: Either DerivationNode StorePathNode -> Elision
summarize =
  \case
    Left (DerivationNode d (Just (_, Built{}))) -> one (SummaryBuildDone d)
    Left (DerivationNode d (Just (_, Building{}))) -> one (SummaryBuildRunning d)
    Left (DerivationNode d (Just (_, Failed{}))) -> one (SummaryBuildFailed d)
    Left (DerivationNode d Nothing) -> one (SummaryBuildWaiting d)
    _ -> mempty

lb :: Text
lb = "▓"

printBuilds ::
  Maybe (Window Int) ->
  UTCTime ->
  BuildForest ->
  NonEmpty Text
printBuilds maybeWindow now forest = markup bold " Dependency Graph: " :| showForest textForest
 where
  maxRows :: Int
  maxRows = maybe maxBound Window.height maybeWindow `div` targetRatio
  withSummaries :: Forest (Either DerivationNode StorePathNode, Elision)
  withSummaries = forest <|>> aggregateTree summarize
  withLinks :: Forest ElisionTreeNode
  withLinks = replaceDuplicates mkLink withSummaries <<|>>> either (first Left) (first Right) .> first Just
  applyElisions :: Int -> Forest ElisionTreeNode -> Forest ElisionTreeNode
  applyElisions = go possibleElisions
   where
    go :: [LinkTreeNode -> Bool] -> Int -> Forest ElisionTreeNode -> Forest ElisionTreeNode
    go [] _ f = f
    go (nextElision : moreElisions) n f
      | n <= 0 = f
      | nAfter <= 0 = forest''
      | otherwise = go moreElisions' nAfter forest''
     where
      (nAfter, forest'') = collapseForestN nextElision n f
      moreElisions' = moreElisions <|>> \e x -> e x || nextElision x
  forestToPrint :: Forest ElisionTreeNode
  forestToPrint = applyElisions (length (foldMap Tree.flatten withLinks) - maxRows) withLinks
  printNode :: LinkTreeNode -> Text
  printNode = either (either printDerivation printStorePath) printLink
  textForest :: Forest Text
  textForest = fmap (\(x, y) -> maybe (markup grey (show (length y) <> " more")) printNode x <> " " <> showElision y) <$> forestToPrint
  showElision y =
    bar red (has (_Ctor @"SummaryBuildFailed"))
      <> bar green (has (_Ctor @"SummaryBuildDone"))
      <> bar yellow (has (_Ctor @"SummaryBuildRunning"))
      <> bar blue (has (_Ctor @"SummaryBuildWaiting"))
   where
    bar color p = markup color $ stimesMonoid count lb
    --bar color p = markup color $ case () of
      --_ | count <= 2 -> stimesMonoid count lb
      --_ | count > 2, count < 10 -> lb <> show count <> stimesMonoid (count - 2) lb
      --_ -> lb <> show count <> stimesMonoid (count - 3) lb
     where
      count = length (filter p (toList y))
  mkLink :: (Either DerivationNode StorePathNode, Elision) -> (Either Derivation StorePath, Elision)
  mkLink = first (bimap derivation path)
  printLink :: Either Derivation StorePath -> Text
  printLink = (<> markup bold " ↴") . name . either toStorePath id
  printDerivation :: DerivationNode -> Text
  printDerivation (DerivationNode derivation status) = case status of
    Nothing -> markup blue . (todo <>) . name . toStorePath $ derivation
    Just (host, buildStatus) -> case buildStatus of
      Building t l ->
        unwords $
          [ markup yellow running
          , hostMarkup host derivation
          , clock
          , timeDiff now t
          ]
            <> maybe [] (\x -> ["(" <> average <> timeDiffSeconds x <> ")"]) l
      Failed dur code _at ->
        unwords
          [ markup yellow warning
          , hostMarkup host derivation
          , markups [red, bold] (unwords ["failed with exit code", show code, "after", clock, timeDiffSeconds dur])
          ]
      Built dur _at ->
        unwords
          [ markup green done
          , hostMarkup host derivation
          , clock
          , timeDiffSeconds dur
          ]
  printStorePath :: StorePathNode -> Text
  printStorePath (StorePathNode path _ _) = name path

hostMarkup :: Host -> Derivation -> Text
hostMarkup Localhost build = markups [cyan, bold] (name . toStorePath $ build)
hostMarkup host build = hostMarkup Localhost build <> " on " <> markup magenta (toText host)

timeFormat :: String
timeFormat = "%02H:%02M:%02S"

timeDiff :: UTCTime -> UTCTime -> Text
timeDiff =
  diffUTCTime
    <.>> formatTime defaultTimeLocale timeFormat
    .> toText

timeDiffSeconds :: Int -> Text
timeDiffSeconds =
  fromIntegral
    .> formatTime @NominalDiffTime defaultTimeLocale timeFormat
    .> toText
