{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE OverloadedStrings #-}

module Game
  ( mkEntityGrid
  , mkGameState
  , step
  , Entity
  , EntityGrid
  , Command(..)
  , GameState(..)
  , Tile(..)
  , getMessage
  , represent
  , setCommand
  , isDoor
  , isWall
  ) where

import           Prelude                        ( head )
import           Relude                  hiding ( head )

import           Utils

import           Control.Lens
import           Data.Default
import           Data.Graph.AStar
import           Data.List                      ( delete )
import           Data.Maybe
import qualified Data.Set                      as Set
import qualified Data.Vector.Fixed             as Vec
import           System.Random


data Component =
    CanMove
  | HasHealth Int
  | IsWall
  | IsDoor
  | IsPotion Effect
  | IsGoal
  | IsEvil
  | IsPlayer
  deriving (Eq, Ord)

-- TODO placeholder
data Effect = Effect
  deriving (Eq, Ord)

-- TODO location could be a component!
--      this would allow for eg inventory items
data Entity = Entity
  { _posX       :: Int
  , _posY       :: Int
  , _components :: Set Component
  }
  deriving Eq

makeLenses ''Entity

-- TODO use th or something?
canMove, hasHealth, isPlayer, isGoal, isWall, isDoor, isEvil, isPotion
  :: Entity -> Bool
canMove =
  any
      (\case
        CanMove -> True
        _       -> False
      )
    . view components
hasHealth =
  any
      (\case
        HasHealth _ -> True
        _           -> False
      )
    . view components
isPlayer =
  any
      (\case
        IsPlayer -> True
        _        -> False
      )
    . view components
isGoal =
  any
      (\case
        IsGoal -> True
        _      -> False
      )
    . view components
isWall =
  any
      (\case
        IsWall -> True
        _      -> False
      )
    . view components
isDoor =
  any
      (\case
        IsDoor -> True
        _      -> False
      )
    . view components
isEvil =
  any
      (\case
        IsEvil -> True
        _      -> False
      )
    . view components
isPotion =
  any
      (\case
        IsPotion _ -> True
        _          -> False
      )
    . view components

getHealth :: Entity -> Int
getHealth =
  head
    . concatMap
        (\case
          HasHealth h -> [h]
          _           -> []
        )
    . view components

setHealth :: Int -> Entity -> Entity
setHealth n = over
  components
  (Set.map
    (\case
      HasHealth _ -> HasHealth n
      c           -> c
    )
  )

randomItemComponents :: StdGen -> Set Component
randomItemComponents rng =
  fromList [randomChoice [IsPotion (randomChoice [Effect] rng)] rng]


type EntityGrid = Matrix (Maybe Entity)

mkEntityGrid :: EntityGrid
mkEntityGrid = Matrix . Vec.replicate . Vec.replicate $ Nothing


data Command = Noop | North | East | South | West | Drink deriving (Eq, Ord, Show)


data GameState = GameState
  { gameRNG   :: StdGen
  , _entities :: [Entity]
  , _command  :: Command
  , _message  :: [Text]
  }

makeLenses ''GameState

getMessage :: GameState -> [Text]
getMessage = view message

setCommand :: Command -> GameState -> GameState
setCommand = set command

mkGameState :: Command -> IO GameState
mkGameState cmd = do
  [rng, rngPlayer, rngGoal, rngItems, rngEvil, rngWalls] <- replicateM
    6
    newStdGen
  let gameState = GameState
        { gameRNG   = rng
        , _entities = ( mkPlayer rngPlayer
                      . mkGoal rngGoal
                      . mkItems rngItems
                      . mkEvil rngEvil
                      . mkWalls rngWalls
                      )
                        []
        , _command  = cmd
        , _message  = []
        }
      entities' = gameState ^. entities
  case
      gridAStar entities'
                (findCoords isPlayer entities')
                (findCoords isGoal entities')
    of
      Just _  -> return gameState
      Nothing -> mkGameState cmd
 where
  findCoords f = getCoords . fromJust . find f
  getCoords e = (e ^. posX, e ^. posY)
  randomCoord       = randomR (0 :: Int, matrixSize - 1)
  randomCoordNoEdge = randomR (1 :: Int, matrixSize - 2)

  mkEntityOnEmpty comps rng es =
    if any (\e -> e ^. posX == x && e ^. posY == y) es
      then mkEntityOnEmpty comps newRNG es
      else Entity x y comps : es
   where
    (x, rng'  ) = randomCoord rng
    (y, newRNG) = randomCoord rng'

  mkPlayer = mkEntityOnEmpty [CanMove, HasHealth 10, IsPlayer]

  mkGoal   = mkEntityOnEmpty [IsGoal]

  mkItems  = mkItems' (5 :: Integer)
  mkItems' 0 _ es = es
  mkItems' n rng es =
    let (compsRNG, newRNG) = split rng
        es' = mkEntityOnEmpty (randomItemComponents compsRNG) rng es
    in  mkItems' (n - 1) newRNG es'

  mkEvil = mkEvil' (5 :: Integer)
  mkEvil' 0 _   es = es
  mkEvil' n rng es = mkEvil' (n - 1) newRNG es'
   where
    (newRNG, _) = split rng
    es'         = mkEntityOnEmpty [CanMove, HasHealth 3, IsEvil] rng es

  mkWalls rng es = mkWalls' (25 :: Integer) rng es

  -- TODO code is ugly; should probably refactor slightly
  mkWalls' 0 _ es = es
  mkWalls' n rng es =
    let
      -- x and y are reversed depending on whether the wall is vertical or
      -- horizontal
      pos1 isX = if isX then posX else posY
      dim1 isX = if isX then x else y
      pos2 isX = if isX then posY else posX
      dim2 isX = if isX then y else x

      (x, rng' ) = randomCoordNoEdge rng
      (y, rng'') = randomCoordNoEdge rng'
      adjEntities isX = filter
        (\e ->
          abs (view (pos1 isX) e - dim1 isX)
            <  3
            && view (pos2 isX) e
            -  dim2 isX
            == 0
        )
        es
      constrainWalls isMin isX =
        (\case
            []    -> if isMin then Just 0 else Just (matrixSize - 1)
            e : _ -> if Set.member IsDoor (e ^. components)
              then Nothing
              else Just $ e ^. pos1 isX
          )
          . (if isMin then reverse else id)
          . sortOn (view $ pos1 isX)
          . filter ((if isMin then (>=) else (<=)) (dim1 isX) . view (pos1 isX))
          . filter ((== dim2 isX) . view (pos2 isX))
      dimRanges =
        [ constrainWalls isMin isX es
        | isX   <- [True, False]
        , isMin <- [True, False]
        ]
    in
      case dimRanges of
        [Just minX, Just maxX, Just minY, Just maxY] ->
          let
            newWalls = if even n
              then [ Entity x' y [IsWall] | x' <- [minX .. maxX] ]
              else [ Entity x y' [IsWall] | y' <- [minY .. maxY] ]
            (doorPos, newRNG) = randomR (0, length newWalls - 1) rng''
            newWallsWithDoor  = newWalls & ix doorPos %~ set components [IsDoor]
          in
            if null (adjEntities $ odd n)
              then mkWalls' (n + 1) newRNG (newWallsWithDoor ++ es)
              else mkWalls' (n - 1) newRNG es
        _ -> mkWalls' (n - 1) rng'' es


-- types of tiles that the renderer should use
-- (corresponding representations/images aren't actually provided in Game.hs)
data Tile = DefaultTile | PlayerTile | GoalTile | WallTile | DoorTile | EvilTile | PotionTile

data System = System
  { qualifier :: Entity -> Bool
  , everyTick :: Command -> Entity -> GameState -> GameState
  , buildRepr :: Entity -> Tile -> Tile
  , buildName :: Entity -> Text -> Text
  }

instance Default System where
  def = System { qualifier = const False
               , everyTick = \_ _ -> id
               , buildRepr = const id
               , buildName = const id
               }

-- runs a system's everyTick over all entities
runSystemET :: System -> GameState -> GameState
runSystemET s gs = (foldl' (.) id . map (everyTick s $ gs ^. command))
  (filter (qualifier s) (gs ^. entities))
  gs

-- a* for our entity list
gridAStar :: [Entity] -> (Int, Int) -> (Int, Int) -> Maybe [(Int, Int)]
gridAStar es begin dest = aStar getNeighbors
                                (\_ _ -> 1)
                                (const 1)
                                (== dest)
                                begin
 where
  getNeighbors (x, y) =
    (fromList . filter
        (\(x', y') ->
          none (\e -> e ^. posX == x' && e ^. posY == y' && isWall e) es
            && withinBounds x'
            && withinBounds y'
        )
      )
      [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
  withinBounds = (>= 0) &&$ (< matrixSize)

-- this has to prevent entities from walking on certain things
attemptMove :: Int -> Int -> Entity -> GameState -> GameState
attemptMove x y e g =
  (case filter (hasHealth &&$ sameLoc) (g ^. entities) of
      e' : _ ->
        over message (name e <> " viciously attacks " <> name e' :)
          . over entities (replace e' (setHealth (getHealth e' - 1) e'))
      [] -> over
        entities
        (\es -> if any (isWall &&$ sameLoc) es
          then es
          else replace e (set posY y . set posX x $ e) es
        )
    )
    g
  where sameLoc e' = (e' ^. posX, e' ^. posY) == (x, y)

fromMoveCommand :: Command -> Entity -> GameState -> GameState
fromMoveCommand c e =
  (case c of
      North -> attemptMove (e ^. posX) (e ^. posY - 1)
      East  -> attemptMove (e ^. posX + 1) (e ^. posY)
      South -> attemptMove (e ^. posX) (e ^. posY + 1)
      West  -> attemptMove (e ^. posX - 1) (e ^. posY)
      _     -> \_ x -> x
    )
    e

detectWin :: System
detectWin = def
  { qualifier = isPlayer
  , everyTick = \_ e g ->
                  if getCoords e
                     == (getCoords . fromJust . find isGoal) (g ^. entities)
                  then
                    over message ("you win!" :) g
                  else
                    g
  }
  where getCoords e = (e ^. posX, e ^. posY)

moveEvil :: System
moveEvil = def
  { qualifier = canMove &&$ isEvil
  , everyTick = \_ e g ->
                  (case filter isPlayer $ g ^. entities of
                      p : _ ->
                        (case
                            gridAStar (g ^. entities)
                                      (e ^. posX, e ^. posY)
                                      ((\e' -> (e' ^. posX, e' ^. posY)) p)
                          of
                            Just ((x, y) : _) -> attemptMove x y e
                            _                 -> id
                        )
                      [] -> id
                    )
                    g
  }

drinkPotion :: System
drinkPotion = def
  { qualifier = isPlayer
  , everyTick = \c e g -> if c == Drink
    then
      case
        filter
          (\e' ->
            e ^. posX == e' ^. posX && e ^. posY == e' ^. posY && isPotion e'
          )
          (g ^. entities)
      of
        []    -> g -- drinking nothing doesn't do very much
        p : _ -> over entities (delete p) g -- TODO apply effect
    else g
  }

systems :: [System]
systems =
  [ -- render and name player
    def { qualifier = isPlayer
        , buildRepr = \_ _ -> PlayerTile
        , buildName = \_ _ -> "the player"
        }
    -- render goal
  , def { qualifier = isGoal, buildRepr = \_ _ -> GoalTile }
    -- render wall
  , def { qualifier = isWall, buildRepr = \_ _ -> WallTile }
    -- render door
  , def { qualifier = isDoor, buildRepr = \_ _ -> DoorTile }
    -- render and name enemy
  , def { qualifier = isEvil
        , buildRepr = \_ _ -> EvilTile
        , buildName = \_ _ -> "a rat"
        }
    -- render potion
  , def { qualifier = isPotion, buildRepr = \_ _ -> PotionTile }
    -- move player
  , def { qualifier = isPlayer &&$ canMove, everyTick = fromMoveCommand }
    -- move enemy
  , moveEvil
    -- display player hp
  , def
    { qualifier = isPlayer &&$ hasHealth
    , everyTick = \_ e g ->
      over message (++ ["you have " <> (show . getHealth) e <> " hp"]) g
    }
    -- drink potion
  , drinkPotion
    -- implement death
  , def
    { qualifier = hasHealth
    , everyTick = \_ e -> if getHealth e <= 0
                    then over message (name e <> " has died!" :)
                      . over entities (delete e)
                    else id
    }
  , -- implement goal
    detectWin
  ]

buildFromEntity :: (System -> Entity -> a -> a) -> a -> Entity -> a
buildFromEntity f x e =
  (foldl' (.) id . map (($ e) . f) . filter (($ e) . qualifier) $ systems) x

name :: Entity -> Text
name = buildFromEntity buildName "something"

represent :: Entity -> Tile
represent = buildFromEntity buildRepr DefaultTile


-- currently an out-of-bounds entity will just not appear
-- this is bc gset uses ix
getGrid :: GameState -> EntityGrid
getGrid =
  flip compose mkEntityGrid
    . map setEntity
    . sortOn (Down . view components)
    . (^. entities)
  where setEntity e = mset (e ^. posX) (e ^. posY) (Just e)

executeStep :: GameState -> GameState
executeStep =
  over message reverse . (compose . map runSystemET) systems . set message []

step :: (EntityGrid -> a) -> State GameState a
step render = do
  modify executeStep
  get <&> render . getGrid
