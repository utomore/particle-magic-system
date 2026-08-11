-- | Analytic particle layer (func-spec 0001 §4.5, architecture §4.6).
--
-- ⚠ Stub behavior, permanent signature: @sample@'s shape is final from day
-- one — a stateless pure function of time. The skeleton semantics is the
-- plain-discharge fountain:
--
--   * particle @i@ is born at @spawn_i = i * particleLifetime / budget@,
--     lives 'particleLifetime' seconds, and respawns cyclically;
--   * position = casterPos + facing·speed·age + hash-channel lateral drift;
--   * color = white, size = 0.05, life field = age / particleLifetime.
--
-- Randomness already uses the final mechanism ('hashChan'): fully
-- deterministic in @(Seed, i, channel)@, so the same @(spell, ctx, t)@
-- always yields a bit-for-bit identical buffer.
module Magic.Particle.Analytic
  ( sample
  ) where

import Data.Fixed (mod')
import qualified Data.Vector.Unboxed as U
import Magic.Compile (CompiledSpell (..), particleLifetime)
import Magic.Types
  ( CastContext (..)
  , Time (..)
  , V3 (..)
  , cross
  , hashChan
  , normalize
  , vscale
  )
import Magic.Particle.Buffer (ParticleBuffer (..), emptyBuffer)

-- | Fountain cone parameters (skeleton constants).
fountainSpeed, fountainSpread :: Float
fountainSpeed = 4.0
fountainSpread = 1.6

sample :: CompiledSpell -> CastContext -> Time -> ParticleBuffer
sample spell ctx (Time t)
  | t < 0 || spellBudget spell <= 0 = emptyBuffer
  | otherwise =
      ParticleBuffer
        { pbPosX = U.generate born (posComponent (\(V3 x _ _) -> x))
        , pbPosY = U.generate born (posComponent (\(V3 _ y _) -> y))
        , pbPosZ = U.generate born (posComponent (\(V3 _ _ z) -> z))
        , pbSize = U.replicate born 0.05
        , pbLife = U.generate born (realToFrac . lifeOf)
        , pbColor = U.replicate born 0xFFFFFFFF
        , pbCount = born
        }
  where
    budget = spellBudget spell
    spawnInterval = particleLifetime / fromIntegral budget
    born = min budget (floor (t / spawnInterval) + 1)

    facing = normalize (casterFacing ctx)
    -- Orthonormal lateral basis around the facing axis.
    refAxis =
      let V3 fx _ _ = facing
       in if abs fx < 0.9 then V3 1 0 0 else V3 0 1 0
    lateralU = normalize (cross facing refAxis)
    lateralW = cross facing lateralU

    ageOf :: Int -> Double
    ageOf i = (t - fromIntegral i * spawnInterval) `mod'` particleLifetime

    lifeOf :: Int -> Double
    lifeOf i = ageOf i / particleLifetime

    positionOf :: Int -> V3
    positionOf i =
      let age = realToFrac (ageOf i) :: Float
          c0 = hashChan (seed ctx) i 0 - 0.5
          c1 = hashChan (seed ctx) i 1 - 0.5
          drift = vscale (c0 * fountainSpread) lateralU + vscale (c1 * fountainSpread) lateralW
       in casterPos ctx + vscale (fountainSpeed * age) facing + vscale age drift

    posComponent :: (V3 -> Float) -> Int -> Float
    posComponent f = f . positionOf
