-- | This module provides a GHC 'Plugin' that allows LiquidHaskell to be hooked directly into GHC's
-- compilation pipeline, facilitating its usage and adoption.

{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}

module Language.Haskell.Liquid.GHC.Plugin (

  plugin

  ) where

import qualified Liquid.GHC.API         as O
import           Liquid.GHC.API         as GHC hiding (Type)
import qualified Text.PrettyPrint.HughesPJ               as PJ
import qualified Language.Fixpoint.Types                 as F
import qualified  Language.Haskell.Liquid.GHC.Misc        as LH
import qualified Language.Haskell.Liquid.UX.CmdLine      as LH
import qualified Language.Haskell.Liquid.GHC.Interface   as LH
import qualified Language.Haskell.Liquid.Liquid          as LH
import qualified Language.Haskell.Liquid.Types.PrettyPrint as LH ( filterReportErrors
                                                                 , filterReportErrorsWith
                                                                 , defaultFilterReporter
                                                                 , reduceFilters )
import qualified Language.Haskell.Liquid.GHC.Logging     as LH   (addTcRnUnknownMessages)

import           Language.Haskell.Liquid.GHC.Plugin.Types
import           Language.Haskell.Liquid.GHC.Plugin.Util as Util
import           Language.Haskell.Liquid.GHC.Plugin.SpecFinder
                                                         as SpecFinder

import           Language.Haskell.Liquid.GHC.Types       (MGIModGuts(..), miModGuts)
import           Language.Haskell.Liquid.Transforms.Rec (transformRecExpr)
import           Language.Haskell.Liquid.Transforms.InlineAux (inlineAux)
import           Language.Haskell.Liquid.Transforms.Rewrite (rewriteBinds)
import           GHC.LanguageExtensions

import           Control.Monad
import qualified Control.Monad.Catch as Ex
import           Control.Monad.IO.Class (MonadIO)

import           Data.Coerce
import           Data.Function                            ((&))
import qualified Data.List                               as L
import qualified Data.Set                                as S
import           Data.Set                                 ( Set )


import qualified Data.HashSet                            as HS
import qualified Data.HashMap.Strict                     as HM

import           Language.Fixpoint.Types           hiding ( errs
                                                          , panic
                                                          , Error
                                                          , Result
                                                          , Expr
                                                          )

import qualified Language.Haskell.Liquid.Measure         as Ms
import           Language.Haskell.Liquid.Parse
import           Language.Haskell.Liquid.Transforms.ANF
import           Language.Haskell.Liquid.Types     hiding ( getConfig )
import           Language.Haskell.Liquid.Bare
import           Language.Haskell.Liquid.UX.CmdLine

-- | Represents an abnormal but non-fatal state of the plugin. Because it is not
-- meant to escape the plugin, it is not thrown in IO but instead carried around
-- in an `Either`'s `Left` case and handled at the top level of the plugin
-- function.
newtype LiquidCheckException = ErrorsOccurred [Filter] -- Unmatched expected errors
  deriving (Eq, Ord, Show)

---------------------------------------------------------------------------------
-- | State and configuration management -----------------------------------------
---------------------------------------------------------------------------------

-- | Set to 'True' to enable debug logging.
debugLogs :: Bool
debugLogs = False

---------------------------------------------------------------------------------
-- | Useful functions -----------------------------------------------------------
---------------------------------------------------------------------------------

-- | Combinator which conditionally print on the screen based on the value of 'debugLogs'.
debugLog :: MonadIO m => String -> m ()
debugLog msg = when debugLogs $ liftIO (putStrLn msg)

---------------------------------------------------------------------------------
-- | The Plugin entrypoint ------------------------------------------------------
---------------------------------------------------------------------------------

plugin :: GHC.Plugin
plugin = GHC.defaultPlugin {
    typeCheckResultAction = liquidPlugin
  , driverPlugin          = lhDynFlags
  , pluginRecompile       = purePlugin
  }
  where
    liquidPlugin :: [CommandLineOption] -> ModSummary -> TcGblEnv -> TcM TcGblEnv
    liquidPlugin opts summary gblEnv = do
      cfg <- liftIO $ LH.getOpts opts
      if skipModule cfg then return gblEnv
      else liquidPluginGo cfg summary gblEnv

    -- Unfortunately, we can't make Haddock run the LH plugin, because the former
    -- does mangle the '.hi' files, causing annotations to not be persisted in the
    -- 'ExternalPackageState' and/or 'HomePackageTable'. For this reason we disable
    -- the plugin altogether if the module is being compiled with Haddock.
    -- See also: https://github.com/ucsd-progsys/liquidhaskell/issues/1727
    -- for a post-mortem.
    liquidPluginGo cfg summary gblEnv = do
      logger <- getLogger
      dynFlags <- getDynFlags
      withTiming logger (text "LiquidHaskell" <+> brackets (ppr $ ms_mod_name summary)) (const ()) $ do
        if gopt Opt_Haddock dynFlags
          then do
            -- Warn the user
            let msg     = PJ.vcat [ PJ.text "LH can't be run with Haddock."
                                  , PJ.nest 4 $ PJ.text "Documentation will still be created."
                                  ]
            let srcLoc  = mkSrcLoc (mkFastString $ ms_hspp_file summary) 1 1
            let warning = mkWarning (mkSrcSpan srcLoc srcLoc) msg
            liftIO $ printWarning logger warning
            pure gblEnv
          else do
            newGblEnv <- typecheckHook cfg summary gblEnv
            case newGblEnv of
              -- Exit with success if all expected errors were found
              Left (ErrorsOccurred []) -> pure gblEnv
              -- Exit with error if there were unmatched expected errors
              Left (ErrorsOccurred errorFilters) -> do
                defaultFilterReporter (LH.modSummaryHsFile summary) errorFilters
                failM
              Right newGblEnv' ->
                pure newGblEnv'

--------------------------------------------------------------------------------
-- | GHC Configuration & Setup -------------------------------------------------
--------------------------------------------------------------------------------

lhDynFlags :: [CommandLineOption] -> HscEnv -> IO HscEnv
lhDynFlags _ hscEnv =
    return hscEnv
      { hsc_dflags =
          hsc_dflags hscEnv
           -- Ignore-interface-pragmas need to be unset to have access to
           -- the RHS unfoldings in the `Ghc.Var`s which is
           -- needed as part of the reflection of foreign functions in the logic
           --
           -- This needs to be active before the plugin runs, so pragmas are
           -- read at the time the interface files are loaded.
           `gopt_unset` Opt_IgnoreInterfacePragmas
      }

-- | Overrides the default 'DynFlags' options. Specifically, we need the GHC
-- lexer not to throw away block comments, as this is where the LH spec comments
-- would live. This is why we set the 'Opt_KeepRawTokenStream' option.
customDynFlags :: DynFlags -> DynFlags
customDynFlags df =
    df `gopt_set` Opt_ImplicitImportQualified
       `gopt_set` Opt_PIC
       `gopt_set` Opt_DeferTypedHoles
       `gopt_set` Opt_KeepRawTokenStream
       `xopt_set` MagicHash
       `xopt_set` DeriveGeneric
       `xopt_set` StandaloneDeriving

maybeInsertBreakPoints :: Config -> DynFlags -> DynFlags
maybeInsertBreakPoints cfg dflags =
    if insertCoreBreakPoints cfg then
      -- Opt_InsertBreakpoints is used during desugaring to prevent the
      -- simple optimizer from inlining local bindings to which we might want
      -- to attach specifications.
      --
      -- https://gitlab.haskell.org/ghc/ghc/-/issues/24386
      dflags `gopt_set` Opt_InsertBreakpoints
    else
      dflags

--------------------------------------------------------------------------------
-- | \"Unoptimising\" things ----------------------------------------------------
--------------------------------------------------------------------------------

-- | LiquidHaskell requires the unoptimised core binds in order to work correctly, but at the same time the
-- user can invoke GHC with /any/ optimisation flag turned out. This is why we grab the core binds by
-- desugaring the module during /parsing/ (before that's already too late) and we cache the core binds for
-- the rest of the program execution.
unoptimiseDynFlags :: DynFlags -> DynFlags
unoptimiseDynFlags df = updOptLevel 0 df
    { debugLevel   = 1
    , ghcLink      = LinkInMemory
    , backend      = interpreterBackend
    , ghcMode      = CompManager
    }

--------------------------------------------------------------------------------
-- | Typechecking phase --------------------------------------------------------
--------------------------------------------------------------------------------

-- | We hook at this stage of the pipeline in order to call \"liquidhaskell\". This
-- might seems counterintuitive as LH works on a desugared module. However, there
-- are a bunch of reasons why we do this:
--
-- 1. Tools like \"ghcide\" works by running the compilation pipeline up until
--    this stage, which means that we won't be able to report errors and warnings
--    if we call /LH/ any later than here;
--
-- 2. Although /LH/ works on \"Core\", it requires the _unoptimised_ \"Core\" that we
--    grab from parsing (again) the module by using the GHC API, so we are really
--    independent from the \"normal\" compilation pipeline.
--
typecheckHook :: Config -> ModSummary -> TcGblEnv -> TcM (Either LiquidCheckException TcGblEnv)
typecheckHook cfg0 modSummary0 tcGblEnv = do
  debugLog $ "We are in module: " <> show (toStableModule thisModule)
  let modSummary =
        updateModSummaryDynFlags (customDynFlags . unoptimiseDynFlags) modSummary0
      thisFile = LH.modSummaryHsFile modSummary

  env0 <- env_top <$> getEnv
  let env = env0 { hsc_dflags = ms_hspp_opts modSummary }
  parsed0 <- liftIO $ parseModuleIO env (LH.keepRawTokenStream modSummary)
  let specComments = map mkSpecComment $ LH.extractSpecComments parsed0
      parsed = addNoInlinePragmasToLocalBinds parsed0

  case parseSpecComments (coerce specComments) of
    Left errors ->
      LH.filterReportErrors thisFile GHC.failM continue (getFilters cfg0) Full errors
    Right specs ->

      withPragmas cfg0 thisFile [s | Pragma s <- specs] $ \cfg -> do

        let modSummary2 = updateModSummaryDynFlags (maybeInsertBreakPoints cfg) modSummary
            parsed2 = parsed { pm_mod_summary = modSummary2 }
            env2 = env { hsc_dflags = ms_hspp_opts modSummary2 }

        -- The LH plugin itself calls the type checker (see following line). This
        -- would lead to a loop if we didn't remove the plugin when calling the type
        -- checker.
        typechecked     <- liftIO $ typecheckModuleIO (dropPlugins env2) (LH.ignoreInline parsed2)
        resolvedNames   <- liftIO $ LH.lookupTyThings env2 tcGblEnv
        availTyCons     <- liftIO $ LH.availableTyCons env2 tcGblEnv (tcg_exports tcGblEnv)
        availVars       <- liftIO $ LH.availableVars env2 tcGblEnv (tcg_exports tcGblEnv)

        unoptimisedGuts <- liftIO $ desugarModuleIO env2 modSummary2 typechecked

        let tcData = mkTcData (tcg_rn_imports tcGblEnv) resolvedNames availTyCons availVars
        let pipelineData = PipelineData unoptimisedGuts tcData specs

        updEnv (\e -> e {env_top = env2}) $
          liquidHaskellCheckWithConfig cfg pipelineData modSummary2 tcGblEnv

  where
    thisModule :: Module
    thisModule = tcg_mod tcGblEnv

    dropPlugins hsc_env = hsc_env { hsc_plugins = emptyPlugins }

    continue = pure $ Left (ErrorsOccurred [])

    updateModSummaryDynFlags f ms = ms { ms_hspp_opts = f (ms_hspp_opts ms) }

serialiseSpec :: Module -> TcGblEnv -> LiquidLib -> TcM TcGblEnv
serialiseSpec thisModule tcGblEnv liquidLib = do
  -- ---
  -- -- CAN WE 'IGNORE' THE BELOW? TODO:IGNORE -- issue use `emptyLiquidLib` instead of pmrClientLib
  -- ProcessModuleResult{..} <- processModule lhContext

  -- liftIO $ putStrLn "liquidHaskellCheck 7"

  -- -- Call into the existing Liquid interface
  -- out <- liftIO $ LH.checkTargetInfo pmrTargetInfo

  -- liftIO $ putStrLn "liquidHaskellCheck 8"

  -- -- Report the outcome of the checking
  -- LH.reportResult errorLogger cfg [giTarget (giSrc pmrTargetInfo)] out
  -- case o_result out of
  --   Safe _stats -> pure ()
  --   _           -> failM

  -- liftIO $ putStrLn "liquidHaskellCheck 9"
  -- ---

  let serialisedSpec = Util.serialiseLiquidLib liquidLib thisModule
  debugLog $ "Serialised annotation ==> " ++ (O.showSDocUnsafe . O.ppr $ serialisedSpec)

  -- liftIO $ putStrLn "liquidHaskellCheck 10"

  pure $ tcGblEnv { tcg_anns = serialisedSpec : tcg_anns tcGblEnv }

processInputSpec :: Config -> PipelineData -> ModSummary -> TcGblEnv -> BareSpec -> TcM (Either LiquidCheckException TcGblEnv)
processInputSpec cfg pipelineData modSummary tcGblEnv inputSpec = do
  hscEnv <- env_top <$> getEnv
  debugLog $ " Input spec: \n" ++ show inputSpec
  debugLog $ "Relevant ===> \n" ++ unlines (renderModule <$> S.toList (relevantModules (hsc_mod_graph hscEnv) modGuts))

  logicMap :: LogicMap <- liftIO LH.makeLogicMap

  -- debugLog $ "Logic map:\n" ++ show logicMap

  let lhContext = LiquidHaskellContext {
        lhGlobalCfg       = cfg
      , lhInputSpec       = inputSpec
      , lhModuleLogicMap  = logicMap
      , lhModuleSummary   = modSummary
      , lhModuleTcData    = pdTcData pipelineData
      , lhModuleGuts      = pdUnoptimisedCore pipelineData
      , lhRelevantModules = relevantModules (hsc_mod_graph hscEnv) modGuts
      }

  -- liftIO $ putStrLn ("liquidHaskellCheck 6: " ++ show isIg)
  if isIgnore inputSpec
    then pure $ Left (ErrorsOccurred [])
    else do
      liquidLib' <- checkLiquidHaskellContext lhContext
      traverse (serialiseSpec thisModule tcGblEnv) liquidLib'

  where
    thisModule :: Module
    thisModule = tcg_mod tcGblEnv

    modGuts :: ModGuts
    modGuts = pdUnoptimisedCore pipelineData

liquidHaskellCheckWithConfig
  :: Config -> PipelineData -> ModSummary -> TcGblEnv -> TcM (Either LiquidCheckException TcGblEnv)
liquidHaskellCheckWithConfig cfg pipelineData modSummary tcGblEnv = do
  -- Here, we are calling Liquid Haskell's parser, acting on the unparsed
  -- spec comments stored in the pipeline data.
  inputSpec <-
    getLiquidSpec thisModule (pdSpecComments pipelineData)

  processInputSpec cfg pipelineData modSummary tcGblEnv inputSpec
    `Ex.catch` (\(e :: UserError) -> reportErrs cfg [e])
    `Ex.catch` (\(e :: Error) -> reportErrs cfg [e])
    `Ex.catch` (\(es :: [Error]) -> reportErrs cfg es)

  where
    thisFile :: FilePath
    thisFile = LH.modSummaryHsFile modSummary

    continue :: TcM (Either LiquidCheckException TcGblEnv)
    continue = pure $ Left (ErrorsOccurred [])

    reportErrs :: (Show e, F.PPrint e) => Config -> [TError e] -> TcM (Either LiquidCheckException TcGblEnv)
    reportErrs cfg = LH.filterReportErrors thisFile GHC.failM continue (getFilters cfg) Full

    thisModule :: Module
    thisModule = tcg_mod tcGblEnv

checkLiquidHaskellContext :: LiquidHaskellContext -> TcM (Either LiquidCheckException LiquidLib)
checkLiquidHaskellContext lhContext = do
  pmr <- processModule lhContext
  case pmr of
    Left e -> pure $ Left e
    Right ProcessModuleResult{..} -> do
      -- Call into the existing Liquid interface
      out <- liftIO $ LH.checkTargetInfo pmrTargetInfo

      let bareSpec = lhInputSpec lhContext
          file = LH.modSummaryHsFile $ lhModuleSummary lhContext

      withPragmas (lhGlobalCfg lhContext) file (Ms.pragmas $ fromBareSpec bareSpec) $ \moduleCfg ->  do
        let filters = getFilters moduleCfg
        -- Report the outcome of the checking
        LH.reportResult (errorLogger file filters) moduleCfg [giTarget (giSrc pmrTargetInfo)] out
        -- If there are unmatched filters or errors, and we are not reporting with
        -- json, we don't make it to this part of the code because errorLogger
        -- will throw an exception.
        --
        -- F.Crash is also handled by reportResult and errorLogger
        case o_result out of
          F.Safe _ -> return $ Right pmrClientLib
          _ | json moduleCfg -> failM
            | otherwise -> return $ Left $ ErrorsOccurred []

errorLogger :: FilePath -> [Filter] -> OutputResult -> TcM ()
errorLogger file filters outputResult = do
  LH.filterReportErrorsWith
    FilterReportErrorsArgs { errorReporter = \errs ->
                               LH.addTcRnUnknownMessages [(sp, e) | (sp, e) <- errs]
                           , filterReporter = LH.defaultFilterReporter file
                           , failure = GHC.failM
                           , continue = pure ()
                           , matchingFilters = LH.reduceFilters (\(src, doc) -> PJ.render doc ++ " at " ++ LH.showPpr src) filters
                           , filters = filters
                           }
    (LH.orMessages outputResult)

isIgnore :: BareSpec -> Bool
isIgnore (MkBareSpec sp) = any ((== "--skip-module") . F.val) (pragmas sp)

--------------------------------------------------------------------------------
-- | Working with bare & lifted specs ------------------------------------------
--------------------------------------------------------------------------------

loadDependencies :: Config
                 -- ^ The 'Config' associated to the /current/ module being compiled.
                 -> Module
                 -> [Module]
                 -> TcM TargetDependencies
loadDependencies currentModuleConfig thisModule mods = do
  hscEnv    <- env_top <$> getEnv
  results   <- SpecFinder.findRelevantSpecs
                 (excludeAutomaticAssumptionsFor currentModuleConfig) hscEnv mods
  deps      <- foldM processResult mempty (reverse results)
  redundant <- liftIO $ configToRedundantDependencies hscEnv currentModuleConfig

  debugLog $ "Redundant dependencies ==> " ++ show redundant

  pure $ foldl' (flip dropDependency) deps redundant
  where
    processResult :: TargetDependencies -> SpecFinderResult -> TcM TargetDependencies
    processResult !acc (SpecNotFound mdl) = do
      debugLog $ "[T:" ++ renderModule thisModule
              ++ "] Spec not found for " ++ renderModule mdl
      pure acc
    processResult _ (SpecFound originalModule location _) = do
      dynFlags <- getDynFlags
      debugLog $ "[T:" ++ show (moduleName thisModule)
              ++ "] Spec found for " ++ renderModule originalModule ++ ", at location " ++ show location
      Util.pluginAbort (O.showSDoc dynFlags $ O.text "A BareSpec was returned as a dependency, this is not allowed, in " O.<+> O.ppr thisModule)
    processResult !acc (LibFound originalModule location lib) = do
      debugLog $ "[T:" ++ show (moduleName thisModule)
              ++ "] Lib found for " ++ renderModule originalModule ++ ", at location " ++ show location
      pure $ TargetDependencies {
          getDependencies = HM.insert (toStableModule originalModule) (libTarget lib) (getDependencies $ acc <> libDeps lib)
        }

data LiquidHaskellContext = LiquidHaskellContext {
    lhGlobalCfg        :: Config
  , lhInputSpec        :: BareSpec
  , lhModuleLogicMap   :: LogicMap
  , lhModuleSummary    :: ModSummary
  , lhModuleTcData     :: TcData
  , lhModuleGuts       :: ModGuts
  , lhRelevantModules  :: Set Module
  }

--------------------------------------------------------------------------------
-- | Per-Module Pipeline -------------------------------------------------------
--------------------------------------------------------------------------------

data ProcessModuleResult = ProcessModuleResult {
    pmrClientLib  :: LiquidLib
  -- ^ The \"client library\" we will serialise on disk into an interface's 'Annotation'.
  , pmrTargetInfo :: TargetInfo
  -- ^ The 'GhcInfo' for the current 'Module' that LiquidHaskell will process.
  }

-- | Process the spec comments from one module. Also looks for
-- "companion specs" for the current module and merges them in
-- if it finds one.
getLiquidSpec :: Module -> [BPspec] -> TcM BareSpec
getLiquidSpec thisModule specComments = do
  let commSpec = toBareSpec . snd $
        hsSpecificationP (moduleName thisModule) specComments
  env    <- env_top <$> getEnv
  res <- liftIO $ SpecFinder.findCompanionSpec env thisModule
  case res of
    SpecFound _ _ companionSpec -> do
      debugLog $ "Companion spec found for " ++ renderModule thisModule
      pure $ commSpec <> companionSpec
    _ -> pure commSpec

processModule :: LiquidHaskellContext -> TcM (Either LiquidCheckException ProcessModuleResult)
processModule LiquidHaskellContext{..} = do
  debugLog ("Module ==> " ++ renderModule thisModule)
  hscEnv              <- env_top <$> getEnv

  let bareSpec        = lhInputSpec
  -- /NOTE/: For the Plugin to work correctly, we shouldn't call 'canonicalizePath', because otherwise
  -- this won't trigger the \"external name resolution\" as part of 'Language.Haskell.Liquid.Bare.Resolve'
  -- (cfr. 'allowExtResolution').
  let file            = LH.modSummaryHsFile lhModuleSummary

  _                   <- liftIO $ LH.checkFilePragmas $ Ms.pragmas (fromBareSpec bareSpec)

  withPragmas lhGlobalCfg file (Ms.pragmas $ fromBareSpec bareSpec) $ \moduleCfg -> do
    dependencies       <- loadDependencies moduleCfg
                                           thisModule
                                           (S.toList lhRelevantModules)

    debugLog $ "Found " <> show (HM.size $ getDependencies dependencies) <> " dependencies:"
    when debugLogs $
      forM_ (HM.keys . getDependencies $ dependencies) $ debugLog . moduleStableString . unStableModule

    debugLog $ "mg_exports => " ++ O.showSDocUnsafe (O.ppr $ mg_exports modGuts)
    debugLog $ "mg_tcs => " ++ O.showSDocUnsafe (O.ppr $ mg_tcs modGuts)

    dynFlags <- getDynFlags
    targetSrc  <- liftIO $ makeTargetSrc moduleCfg dynFlags file lhModuleTcData modGuts hscEnv
    logger <- getLogger

    -- See https://github.com/ucsd-progsys/liquidhaskell/issues/1711
    -- Due to the fact the internals can throw exceptions from pure code at any point, we need to
    -- call 'evaluate' to force any exception and catch it, if we can.


    result <-
      makeTargetSpec moduleCfg lhModuleLogicMap targetSrc bareSpec dependencies

    let continue = pure $ Left (ErrorsOccurred [])
        reportErrs :: (Show e, F.PPrint e) => [TError e] -> TcRn (Either LiquidCheckException ProcessModuleResult)
        reportErrs = LH.filterReportErrors file GHC.failM continue (getFilters moduleCfg) Full

    (case result of
      -- Print warnings and errors, aborting the compilation.
      Left diagnostics -> do
        liftIO $ mapM_ (printWarning logger)    (allWarnings diagnostics)
        reportErrs $ allErrors diagnostics
      Right (warnings, targetSpec, liftedSpec) -> do
        liftIO $ mapM_ (printWarning logger) warnings
        let targetInfo = TargetInfo targetSrc targetSpec

        debugLog $ "bareSpec ==> "   ++ show bareSpec
        debugLog $ "liftedSpec ==> " ++ show liftedSpec

        let clientLib  = mkLiquidLib liftedSpec & addLibDependencies dependencies

        let result' = ProcessModuleResult {
              pmrClientLib  = clientLib
            , pmrTargetInfo = targetInfo
            }

        pure $ Right result')
      `Ex.catch` (\(e :: UserError) -> reportErrs [e])
      `Ex.catch` (\(e :: Error) -> reportErrs [e])
      `Ex.catch` (\(es :: [Error]) -> reportErrs es)

  where
    modGuts    = lhModuleGuts
    thisModule = mg_module modGuts

makeTargetSrc :: Config
              -> DynFlags
              -> FilePath
              -> TcData
              -> ModGuts
              -> HscEnv
              -> IO TargetSrc
makeTargetSrc cfg dynFlags file tcData modGuts hscEnv = do
  let preNormCoreBinds = preNormalize cfg modGuts
  when (dumpPreNormalizedCore cfg) $ do
    putStrLn "\n*************** Pre-normalized CoreBinds *****************\n"
    putStrLn $ unlines $ L.intersperse "" $ map (GHC.showPpr dynFlags) preNormCoreBinds
  coreBinds <- anormalize cfg hscEnv modGuts { mg_binds = preNormCoreBinds }

  -- The type constructors for a module are the (nubbed) union of the ones defined and
  -- the ones exported. This covers the case of \"wrapper modules\" that simply re-exports
  -- everything from the imported modules.
  let availTcs    = tcAvailableTyCons tcData
  let allTcs      = L.nub (mgi_tcs mgiModGuts ++ availTcs)

  let dataCons       = concatMap (map dataConWorkId . tyConDataCons) allTcs
  let (fiTcs, fiDcs) = LH.makeFamInstEnv (getFamInstances modGuts)
  let things         = tcResolvedNames tcData
  let impVars        = LH.importVars coreBinds ++ LH.classCons (mgi_cls_inst mgiModGuts)

  debugLog $ "_gsTcs   => " ++ show allTcs
  debugLog $ "_gsFiTcs => " ++ show fiTcs
  debugLog $ "_gsFiDcs => " ++ show fiDcs
  debugLog $ "dataCons => " ++ show dataCons
  debugLog $ "coreBinds => " ++ (O.showSDocUnsafe . O.ppr $ coreBinds)
  debugLog $ "impVars => " ++ (O.showSDocUnsafe . O.ppr $ impVars)
  debugLog $ "defVars  => " ++ show (L.nub $ dataCons ++ letVars coreBinds ++ tcAvailableVars tcData)
  debugLog $ "useVars  => " ++ (O.showSDocUnsafe . O.ppr $ readVars coreBinds)
  debugLog $ "derVars  => " ++ (O.showSDocUnsafe . O.ppr $ HS.fromList (LH.derivedVars cfg mgiModGuts))
  debugLog $ "gsExports => " ++ show (mgi_exports  mgiModGuts)
  debugLog $ "gsTcs     => " ++ (O.showSDocUnsafe . O.ppr $ allTcs)
  debugLog $ "gsCls     => " ++ (O.showSDocUnsafe . O.ppr $ mgi_cls_inst mgiModGuts)
  debugLog $ "gsFiTcs   => " ++ (O.showSDocUnsafe . O.ppr $ fiTcs)
  debugLog $ "gsFiDcs   => " ++ show fiDcs
  debugLog $ "gsPrimTcs => " ++ (O.showSDocUnsafe . O.ppr $ GHC.primTyCons)
  debugLog $ "things   => " ++ (O.showSDocUnsafe . O.vcat . map O.ppr $ things)
  debugLog $ "allImports => " ++ show (tcAllImports tcData)
  debugLog $ "qualImports => " ++ show (tcQualifiedImports tcData)
  return $ TargetSrc
    { giTarget    = file
    , giTargetMod = ModName Target (moduleName (mg_module modGuts))
    , giCbs       = coreBinds
    , giImpVars   = impVars
    , giDefVars   = L.nub $ dataCons ++ letVars coreBinds ++ tcAvailableVars tcData
    , giUseVars   = readVars coreBinds
    , giDerVars   = HS.fromList (LH.derivedVars cfg mgiModGuts)
    , gsExports   = mgi_exports  mgiModGuts
    , gsTcs       = allTcs
    , gsCls       = mgi_cls_inst mgiModGuts
    , gsFiTcs     = fiTcs
    , gsFiDcs     = fiDcs
    , gsPrimTcs   = GHC.primTyCons
    , gsQualImps  = tcQualifiedImports tcData
    , gsAllImps   = tcAllImports       tcData
    , gsTyThings  = [ t | (_, Just t) <- things ]
    }
  where
    mgiModGuts :: MGIModGuts
    mgiModGuts = miModGuts deriv modGuts
      where
        deriv   = Just $ instEnvElts $ mg_inst_env modGuts

    preNormalize :: Config -> ModGuts -> [CoreBind]
    preNormalize cfg modGuts = rewriteBinds cfg orig_cbs
      where
        orig_cbs = transformRecExpr inl_cbs
        inl_cbs  = inlineAux cfg (mg_module modGuts) (mg_binds modGuts)

getFamInstances :: ModGuts -> [FamInst]
getFamInstances guts = famInstEnvElts (mg_fam_inst_env guts)
