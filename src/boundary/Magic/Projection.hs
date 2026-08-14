-- | Boundary re-export of the core projection surface (ADR-0008,
-- func-spec 0008 §4.2).
--
-- The executable depends on magic-boundary only (the package boundary
-- @test\/BoundarySpec.hs@ guards), so this module is the shell's sole
-- doorway to 'Magic.Project'. The name deliberately differs from the core
-- module's: the test suite depends on both libraries at once, and a
-- same-named re-export would force @PackageImports@ on every test that
-- touches projection.
module Magic.Projection (module Magic.Project) where

import Magic.Project
