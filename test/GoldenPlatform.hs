-- | The scope of the bit-for-bit laws, after func-spec 0019 S2 measured
-- them on a second platform (ADR-0016).
--
-- Every golden in this repository was recorded on Windows x86_64 and, for
-- eighteen specs, "determinism" was written down as if it were
-- platform-free. The first Linux run of the suite said otherwise: 23
-- golden comparisons failed, all of them in the position columns, and the
-- cause is not this project's arithmetic. IEEE-754 mandates correct
-- rounding for @sqrt@ but not for @sin@ and @cos@, and the two libm
-- implementations (mingw's and glibc's) disagree on the last bit for
-- about 1.3% of arguments — measured directly: 63 of 4096 @Float@ angles
-- for @sin@, 46 of 4096 for @cos@, worst case 1 ulp each. Downstream that
-- is a worst absolute difference of 1.79e-07 world units in @pbPosX@ and
-- @pbPosZ@; @pbPosY@, @pbSize@, @pbLife@ and @pbColor@ came out
-- bit-identical on both platforms.
--
-- So the law narrows rather than dies: /on a given platform/ the output
-- is bit-for-bit reproducible, which is what replay, regression nets and
-- the FFI equivalence law all actually rest on. Across platforms the
-- guarantee is the structure — the same particles, in the same order, in
-- the same counts, within a couple of ulp.
--
-- Mechanically that means the digest half of a golden is asserted only
-- where the golden was recorded, and the platform-independent half is
-- asserted everywhere. Adding a second reference platform is a matter of
-- recording a second set of goldens and widening 'referencePlatform';
-- nothing else in the three golden specs would move.
module GoldenPlatform
  ( referencePlatform
  , platformScopeNote
  ) where

import System.Info (os)

-- | Is this the platform the committed goldens were recorded on?
--
-- @System.Info.os@ is @\"mingw32\"@ on Windows for both 32- and 64-bit
-- GHC; this project has only ever shipped x86_64 builds.
referencePlatform :: Bool
referencePlatform = os == "mingw32"

-- | Appended to the failure and pending messages of every law this
-- scoping touches, so a red or skipped test on a non-reference platform
-- explains itself without a trip to the ADR.
platformScopeNote :: String
platformScopeNote =
  "bit-for-bit goldens are a same-platform law (ADR-0016): recorded on "
    ++ "windows/x86_64, and cross-platform the position columns may differ "
    ++ "by a couple of ulp because libm's sin/cos are not correctly "
    ++ "rounded. Running on "
    ++ os
    ++ "."
