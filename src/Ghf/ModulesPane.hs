{-# OPTIONS_GHC -fglasgow-exts #-}
-----------------------------------------------------------------------------
--
-- Module      :  Ghf.ModulesPane
-- Copyright   :  (c) Juergen Nicklisch-Franken (aka Jutaro)
-- License     :  GNU-GPL
--
-- Maintainer  :  Juergen Nicklisch-Franken <jnf at arcor.de>
-- Stability   :  experimental
-- Portability :  portable
--
-- | The pane of ghf where modules are presented in tree form with their
--   packages and exports
--
-------------------------------------------------------------------------------

module Ghf.ModulesPane (
    showModules
) where

import Graphics.UI.Gtk hiding (get)
import Graphics.UI.Gtk.ModelView as New
import System.Glib.Signals
import Data.Maybe
import Control.Monad.Reader
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Tree
import Data.List


import Ghf.Core
import Ghf.ViewFrame

instance Pane GhfModules
    where
    primPaneName _  =   "Mod"
    getAddedIndex _ =   0
    getTopWidget    =   castToWidget . boxM
    paneId b        =   "*Modules"

instance Castable GhfModules where
    casting _               =   ModulesCasting
    downCast _ (PaneC a)    =   case casting a of
                                    ModulesCasting  -> Just a
                                    _               -> Nothing

showModules :: GhfAction
showModules = do
    m <- getModules
    lift $ bringPaneToFront m

getModules :: GhfM GhfModules
getModules = do
    panesST     <-  readGhf panes
    prefs       <-  readGhf prefs
    layout      <-  readGhf layout
    let mods    =   catMaybes $ map (downCast ModulesCasting) $ Map.elems panesST
    if null mods || length mods > 1
        then do
            let pp      =   getStandardPanePath (modulesPanePath prefs) layout
            nb          <-  getNotebook pp
            initModules pp nb
            panesST     <- readGhf panes
            let mods    =   catMaybes $ map (downCast ModulesCasting) $ Map.elems panesST
            if null mods || length mods > 1
                then error "Can't init modules"
                else return (head mods)
        else return (head mods)

initModules :: PanePath -> Notebook -> GhfAction
initModules panePath nb = do
    lift $ putStrLn "now init modules"
    ghfR        <-  ask
    panes       <-  readGhf panes
    paneMap     <-  readGhf paneMap
    prefs       <-  readGhf prefs
    currentInfo <-  readGhf currentInfo
    (buf,cids)  <-  lift $ do
        treeView    <-  New.treeViewNew
        putStrLn "now building forest"
        let forest  = case currentInfo of
                        Nothing     ->  []
                        Just pair   ->  subForest (buildModulesTree pair)
        putStrLn "after building forest"
        treeStore   <-  New.treeStoreNew forest
        New.treeViewSetModel treeView treeStore
        facetView   <-  New.treeViewNew
        facetStore  <-  New.listStoreNew []
        New.treeViewSetModel facetView facetStore
        renderer <- New.cellRendererTextNew
        col <- New.treeViewColumnNew
        New.treeViewAppendColumn treeView col
        New.cellLayoutPackStart col renderer True
        New.cellLayoutSetAttributes col renderer treeStore
            $ \row -> [ New.cellText := fst row]
        New.treeViewSetHeadersVisible treeView False

        box <- hBoxNew False 0
        sw <- scrolledWindowNew Nothing Nothing
        scrolledWindowAddWithViewport sw treeView
        scrolledWindowSetPolicy sw PolicyAutomatic PolicyAutomatic
        boxPackStart box sw PackGrow 2
        boxPackStart box facetView PackGrow 2
        let modules = GhfModules box treeStore facetStore
        notebookPrependPage nb box (paneName modules)
        widgetShowAll box
        mbPn <- notebookPageNum nb box
        case mbPn of
            Just i -> notebookSetCurrentPage nb i
            Nothing -> putStrLn "Notebook page not found"
        cid1 <- box `afterFocusIn`
            (\_ -> do runReaderT (makeModulesActive modules) ghfR; return True)
        return (modules,[cid1])
    let newPaneMap  =  Map.insert (paneName buf)
                            (panePath, BufConnections [] [] []) paneMap
    let newPanes = Map.insert (paneName buf) (PaneC buf) panes
    modifyGhf_ (\ghf -> return (ghf{panes = newPanes,
                                    paneMap = newPaneMap}))
    lift $widgetGrabFocus (boxM buf)

fillModulesList :: GhfAction
fillModulesList = do
    (GhfModules _ treeStore _)  <-  getModules
    currentInfo                 <-  readGhf currentInfo
    case currentInfo of
        Nothing             ->  lift $ do
                                    New.treeStoreClear treeStore
        Just pair           ->  let (Node _ li) = buildModulesTree pair
                                in lift $ do
                                    New.treeStoreClear treeStore
                                    mapM_ (\(e,i) -> New.treeStoreInsertTree treeStore [] i e)
                                        $ zip li [0 .. length li]

makeModulesActive :: GhfModules -> GhfAction
makeModulesActive mods      =   do
    activatePane mods (BufConnections[][][])

type ModTree = Tree (String, [(ModuleDescr,PackageDescr)])

--
-- | Make a Tree with a module desription, package description pairs tree to display.
--   Their are nodes with a label but without a module (like e.g. Data).
--
buildModulesTree :: (PackageScope,PackageScope) -> ModTree
buildModulesTree ((localMap,_),(otherMap,_)) =
    let flatPairs           =   concatMap (\e -> map (\f -> (f,e)) (exposedModulesPD e))
                                    (Map.elems localMap ++ Map.elems otherMap)
        emptyTree           =   (Node ("",[]) [])
        resultTree          =   foldl insertPairsInTree emptyTree flatPairs
        in sortTree resultTree
    where
    insertPairsInTree :: ModTree -> (ModuleDescr,PackageDescr) -> ModTree
    insertPairsInTree tree pair =
        let nameArray           =   breakAtDots [] $ tail $ dropWhile (\c -> c /= ':')
                                                       $ moduleIdMD (fst pair)
            pairedWith          =   map (\n -> (n,pair)) nameArray
        in  insertNodesInTree pairedWith tree

    breakAtDots :: [String] -> String -> [String]
    breakAtDots res []          =   reverse res
    breakAtDots res toBreak     =   let (newRes,newToBreak) = span (\c -> c /= '.') toBreak
                                    in  if null newToBreak
                                            then reverse (newRes : res)
                                            else breakAtDots (newRes : res) (tail newToBreak)

    insertNodesInTree :: [(String,(ModuleDescr,PackageDescr))] -> ModTree -> ModTree
    insertNodesInTree list@[(str2,pair)] (Node (str1,pairs) forest) =
        case partition (\ (Node (s,_) _) -> s == str2) forest of
            ([],_)              ->  (Node (str1,pairs) (makeNodes list : forest))
            ([(Node (_,pairsf) l)],rest)
                                ->  (Node (str1,pairs) ((Node (str2,pair : pairsf) l) : rest))
            (_,_)               ->  error "insertNodesInTree: impossible1"
    insertNodesInTree  list@((str2,pair):tl) (Node (str1,pairs) forest) =
        case partition (\ (Node (s,_) _) -> s == str2) forest of
            ([],_)              ->  (Node (str1,pairs)  (makeNodes list : forest))
            ([found],rest)      ->  (Node (str1,pairs) (insertNodesInTree tl found : rest))
            (_,_)               ->  error "insertNodesInTree: impossible2"
    insertNodesInTree [] t      =   t

    makeNodes :: [(String,(ModuleDescr,PackageDescr))] -> ModTree
    makeNodes [(str,pair)]      =   Node (str,[pair]) []
    makeNodes ((str,_):tl)      =   Node (str,[]) [makeNodes tl]

instance Ord a => Ord (Tree a) where
    compare (Node l1 _) (Node l2 _) =  compare l1 l2

sortTree :: Ord a => Tree a -> Tree a
sortTree (Node l forest)    =   Node l (sort (map sortTree forest))
