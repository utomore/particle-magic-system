-- | The exception firewall's trigger, for the out-of-process smoke
-- (host-runtime F006, T9/T10; design.md M8's "test-only build target").
--
-- __This module is not part of the library.__ It lives outside @src\/ffi@,
-- it is compiled only into the @particle-magic-ffi-poison@ foreign library
-- (cabal flag @oop-poison@, @default: False@), and that library's file name
-- differs from the shipped one so it can never be mistaken for it. The
-- shipped @particle-magic-ffi.def@, @include\/particle_magic.h@ and the C#
-- binding are untouched, which is the whole reason the trigger is shaped
-- this way: @test\/FFIContractSpec.hs@'s three-way reconciliation reads
-- @src\/ffi\/Magic\/FFI.hs@, the shipped @.def@ and the header, and this
-- module is in none of them.
--
-- __Why a trigger is needed at all.__ @PM_ERR_INTERNAL@ is the answer to a
-- bug inside this library. There is no legitimate call that produces one —
-- a call that did would be a defect to fix, not a fixture to test with — so
-- the only honest way to see the firewall work from C is to put a bomb
-- somewhere the real entry points will step on it.
--
-- __Where the bomb goes.__ Not here. This function does not throw: if it
-- did, the test would be watching this module's own firewall rather than
-- the shipped symbols'. It hands back a perfectly valid handle whose
-- /contents/ are bottom, using the laziness 'newSpellHandle' documents on
-- purpose. The failure then happens inside @pm_observe@, @pm_age@,
-- @pm_is_finished@ and friends — the symbols a host actually calls — which
-- is exactly what C2.1 is about.
--
-- The handle is a fresh one, so the poison cannot spread: a spell cast
-- before it keeps working, which the probe asserts.
module Magic.FFI.Poison (pm_poison_spell) where

import Foreign.StablePtr (StablePtr)
import Magic.FFI (SpellCell, firewall, newSpellHandle, nullSpell)

foreign export ccall "pm_poison_spell"
  pm_poison_spell :: IO (StablePtr SpellCell)

-- | A live, registry-valid @PmSpell*@ over a value that raises the moment
-- anything forces it.
--
-- Wrapped in 'firewall' like every shipped entry point, so this symbol
-- cannot become the one hole in the wall it exists to test.
pm_poison_spell :: IO (StablePtr SpellCell)
pm_poison_spell =
  firewall nullSpell $
    newSpellHandle (error "pm_poison_spell: deliberate internal failure (host-runtime F006)")
