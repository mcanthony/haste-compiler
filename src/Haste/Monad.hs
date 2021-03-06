{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleInstances,
             MultiParamTypeClasses #-}
module Haste.Monad (
    JSGen, genJS, dependOn, getModName, addLocal, getCfg, continue, isolate,
    pushBind, popBind, getCurrentBinding, whenCfg, rename, getActualName
  ) where
import Control.Monad.State.Strict
import Haste.AST as AST hiding (modName)
import qualified Data.Set as S
import Control.Applicative
import qualified Data.Map as M

data GenState cfg = GenState {
    -- | Dependencies in current context.
    deps         :: ![Name],
    -- | Local variables in current context.
    locals       :: ![Name],
    -- | The current continuation. Code is generated by appending to this
    --   continuation.
    continuation :: !(Stm -> Stm),
    -- | The stack of nested lambdas we've traversed.
    bindStack    :: ![Var],
    -- | Name of the module being compiled.
    modName      :: !String,
    -- | Current compiler configuration.
    config       :: !cfg,
    -- | Mapping of variable renamings.
    renames      :: !(M.Map Var Var)
  }

initialState :: cfg -> GenState cfg
initialState cfg = GenState {
    deps         = [],
    locals       = [],
    continuation = id,
    bindStack    = [],
    modName      = "",
    config       = cfg,
    renames      = M.empty
  }

newtype JSGen cfg a =
  JSGen (State (GenState cfg) a)
  deriving (Monad, Functor, Applicative)

class Dependency a where
  -- | Add a dependency to the function currently being generated.
  dependOn :: a -> JSGen cfg ()
  -- | Mark a symbol as local, excluding it from the dependency graph.
  addLocal :: a -> JSGen cfg ()

instance Dependency AST.Name where
  {-# INLINE dependOn #-}
  dependOn v = JSGen $ do
    st <- get
    put st {deps = v : deps st}

  {-# INLINE addLocal #-}
  addLocal v = JSGen $ do
    st <- get
    put st {locals = v : locals st}

instance Dependency AST.Var where
  {-# INLINE dependOn #-}
  dependOn (Foreign _)      = return ()
  dependOn (Internal n _ _) = dependOn n

  {-# INLINE addLocal #-}
  addLocal (Foreign _)      = return ()
  addLocal (Internal n _ _) = addLocal n

instance Dependency a => Dependency [a] where
  dependOn = mapM_ dependOn
  addLocal = mapM_ addLocal

instance Dependency a => Dependency (S.Set a) where
  dependOn = dependOn . S.toList
  addLocal = addLocal . S.toList

genJS :: cfg         -- ^ Config to use for code generation.
      -> String      -- ^ Name of the module being compiled.
      -> JSGen cfg a -- ^ The code generation computation.
      -> (a, S.Set AST.Name, S.Set AST.Name, Stm -> Stm)
genJS cfg myModName (JSGen gen) =
  case runState gen (initialState cfg) {modName = myModName} of
    (a, GenState dependencies loc cont _ _ _ _) ->
      (a, S.fromList dependencies, S.fromList loc, cont)

getModName :: JSGen cfg String
getModName = JSGen $ modName <$> get

pushBind :: Var -> JSGen cfg ()
pushBind v = JSGen $ do
  st <- get
  put st {bindStack = v : bindStack st}

popBind :: JSGen cfg ()
popBind = JSGen $ do
  st <- get
  put st {bindStack = tail $ bindStack st}

getCurrentBinding :: JSGen cfg Var
getCurrentBinding = JSGen $ fmap (head . bindStack) get

-- | Add a new continuation onto the current one.
continue :: (Stm -> Stm) -> JSGen cfg ()
continue cont = JSGen $ do
  st <- get
  put st {continuation = continuation st . cont}

-- | Run a GenJS computation in isolation, returning its results rather than
--   writing them to the output stream. Dependencies and locals are still
--   updated, however, and any enclosing renames are still visible within
--   the isolated computation.
isolate :: JSGen cfg a -> JSGen cfg (a, Stm -> Stm)
isolate gen = do
  myMod <- getModName
  cfg <- getCfg
  b <- getCurrentBinding
  rns <- renames <$> JSGen get
  let (x, dep, loc, cont) = genJS cfg myMod $ do
        pushBind b
        JSGen $ do
          st <- get
          put st {renames = rns}
        gen
  dependOn dep
  addLocal loc
  return (x, cont)

getCfg :: JSGen cfg cfg
getCfg = JSGen $ fmap config get

whenCfg :: (cfg -> Bool) -> JSGen cfg () -> JSGen cfg ()
whenCfg p act = do
  cfg <- getCfg
  when (p cfg) act

-- | Run a computation with the given renaming added to its context.
rename :: Var -> Var -> JSGen cfg a -> JSGen cfg a
rename from to m = do
  st <- JSGen get
  JSGen $ put st {renames = M.insert from to $ renames st}
  x <- m
  st' <- JSGen get
  JSGen $ put st' {renames = renames st}
  return x

-- | Get the actual name of a variable, recursing through multiple renamings
--   if necessary.
getActualName :: Var -> JSGen cfg Var
getActualName v = do
  rns <- renames <$> JSGen get
  maybe (return v) getActualName $ M.lookup v rns
