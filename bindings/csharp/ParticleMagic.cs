// ParticleMagic.cs -- reference C# binding for the particle magic C ABI
// (func-spec 0011 §7 S4; the contract is include/particle_magic.h).
//
// Engine-independent on purpose: nothing here references Unity, so the
// file drops into a plain .NET project, a Godot C# project or a Unity one
// unchanged. examples/unity/SpellRenderer.cs is what a Unity component
// built on top of it looks like.
//
// test/BindingContractSpec.hs parses this file and fails the build if the
// entry points or the constants drift from the header, so treat the two
// as one edit.
//
// The arrays are blittable (float[], uint[], int[]), so the marshaller
// pins them and passes a pointer -- one interop call per frame, no
// per-element copying. Allocate them once and reuse them; a fresh array
// per frame is just GC pressure.

using System;
using System.Runtime.InteropServices;

namespace ParticleMagic
{
    /// <summary>Raw P/Invoke surface. One method per header declaration.</summary>
    public static class Pm
    {
        // Windows: particle-magic-ffi.dll, Linux: libparticle-magic-ffi.so,
        // macOS: libparticle-magic-ffi.dylib. The name goes in without the
        // prefix or the extension; the runtime adds the platform's own.
        public const string Dll = "particle-magic-ffi";

        // --- Contract constants (mirrors of include/particle_magic.h) ---

        public const int AbiVersion = 1;        // PM_ABI_VERSION
        public const int MaxParticles = 4096;   // PM_MAX_PARTICLES (see pm_max_particles)
        public const int BatchInfoStride = 4;   // PM_BATCH_INFO_STRIDE

        public const int Ok = 0;                // PM_OK
        public const int ErrJson = -1;          // PM_ERR_JSON
        public const int ErrBudget = -2;        // PM_ERR_BUDGET
        public const int ErrCapacity = -3;      // PM_ERR_CAPACITY
        public const int ErrArgs = -4;          // PM_ERR_ARGS
        public const int ErrQuota = -5;         // PM_ERR_QUOTA: scene full, retry after a Dismiss
        public const int ErrInternal = -6;      // PM_ERR_INTERNAL: a bug in the library, never in your call
        public const int ErrState = -7;         // PM_ERR_STATE: called out of order

        public const int BlendAlpha = 0;        // PM_BLEND_ALPHA
        public const int BlendAdditive = 1;     // PM_BLEND_ADDITIVE
        public const int ShapeSquare = 0;       // PM_SHAPE_SQUARE
        public const int ShapeSoftDot = 1;      // PM_SHAPE_SOFT_DOT
        public const int ShapeRing = 2;         // PM_SHAPE_RING
        public const int ShapeSpark = 3;        // PM_SHAPE_SPARK
        // PM_SHAPE_TRAIL: stretch the quad along the particle's own
        // velocity. The stretch is per PARTICLE, not per batch -- read it
        // from the velocity columns of pm_observe_ex, not from batchInfo,
        // which has no room for it and never will.
        public const int ShapeTrail = 4;        // PM_SHAPE_TRAIL

        public const int PlaneSideXY = 0;       // PM_PLANE_SIDE_XY: (x, y), depth = -z
        public const int PlaneTopXZ = 1;        // PM_PLANE_TOP_XZ:  (x, z), depth = -y

        // 3*3*3 = 27 cells, one per bit of the uint pm_occupancy_mask
        // returns. Bits 27..31 are always clear.
        public const int OccupancyDimDefault = 3; // PM_OCCUPANCY_DIM_DEFAULT

        // Runtime settings for pm_init_ex (host-runtime F003).
        public const int GcDefault = 0;         // PM_GC_DEFAULT
        public const int GcNonmoving = 1;       // PM_GC_NONMOVING
        // Statistics can ONLY be turned on while the runtime starts, so a
        // host that wants GC numbers has to ask here.
        public const int StatsOff = 0;          // PM_STATS_OFF
        public const int StatsOn = 1;           // PM_STATS_ON
        public const int MaxCapabilities = 256; // PM_MAX_CAPABILITIES
        public const int NurseryMinBytes = 8192; // PM_NURSERY_MIN_BYTES
        public const int NurseryMaxBytes = 1073741824; // PM_NURSERY_MAX_BYTES

        // --- Runtime lifecycle ---
        //
        // pm_init() or pm_init_ex() once per process, before anything
        // else. Do NOT call pm_shutdown() unless the process is ending:
        // the GHC runtime cannot be restarted in the same process, and
        // after shutdown this library refuses every call with ErrState --
        // an editor that keeps native plugins loaded between play sessions
        // would otherwise fail on the second run (see
        // examples/unity/README.md).
        //
        // Everything below answers ErrState (or null, or a neutral value)
        // until the runtime is up, instead of taking the process down.

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void pm_init();

        // Start the runtime with your settings. Returns Pm.Ok; Pm.ErrArgs
        // (out of range -- nothing started); or Pm.ErrState, which means
        // either that the call was out of order, or that the runtime was
        // already running in this process, so the capability count took
        // effect but the nursery, GC mode and statistics flag could not.
        //
        //     var cfg = new PmConfig {
        //         size = (uint)Marshal.SizeOf<PmConfig>(),
        //         capabilities = 4,
        //         stats = Pm.StatsOn,
        //     };
        //     int rc = Pm.pm_init_ex(ref cfg);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_init_ex(ref PmConfig config);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void pm_shutdown();

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_abi_version();

        /// <summary>Particle cap this build enforces; allocate the six columns from it.</summary>
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_max_particles();

        // --- Spell lifecycle ---

        // circleJsonUtf8 must be NUL-terminated UTF-8 bytes: passing a
        // string would leave the encoding up to the scripting backend.
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr pm_cast(byte[] circleJsonUtf8,
                                            float[] casterPos, float[] casterFacing,
                                            ulong seed, byte[] errBuf, int errLen);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_cast_ex(byte[] circleJsonUtf8,
                                            float[] casterPos, float[] casterFacing,
                                            ulong seed, byte[] errBuf, int errLen,
                                            out IntPtr outSpell);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void pm_advance(IntPtr spell, float dt);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_is_finished(IntPtr spell);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern double pm_age(IntPtr spell);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_observe(IntPtr spell,
                                            float[] posX, float[] posY, float[] posZ,
                                            float[] size, float[] life, uint[] color,
                                            int capacity, int[] batchInfo, int maxBatches);

        /// <summary>
        /// pm_observe plus three velocity columns, in units per second.
        ///
        /// Identical in every other respect -- same batches, same
        /// batchInfo layout, same all-or-nothing capacity rule -- because
        /// pm_observe is literally this call with the three velocity
        /// arrays null. Pass null for any velocity column you do not
        /// want; a spell with no "trail" style fills the ones you do pass
        /// with zeros rather than failing.
        ///
        /// This is what a ShapeTrail batch needs: stretch each quad along
        /// (velX, velY, velZ) by a length that grows with the velocity's
        /// magnitude, and clamp it, or a fast particle streaks across the
        /// whole screen.
        /// </summary>
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_observe_ex(IntPtr spell,
                                               float[] posX, float[] posY, float[] posZ,
                                               float[] size, float[] life, uint[] color,
                                               float[] velX, float[] velY, float[] velZ,
                                               int capacity, int[] batchInfo, int maxBatches);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void pm_free(IntPtr spell);

        // --- Scenes: several casts alive at once (func-spec 0018) ---
        //
        // A PmScene* is an IntPtr like a PmSpell*, and the rules are the
        // same: one scene per thread, free it exactly once. Two things
        // differ, and both bite silently if you get them wrong:
        //
        //   * size the six columns from the globalCap you passed to
        //     pm_scene_new, NOT from pm_max_particles(). The query bounds
        //     ONE spell; a scene holds several. Undersize them and the
        //     second cast starts returning ErrCapacity from
        //     pm_scene_observe.
        //   * a spell inside a scene has no PmSpell* of its own. Never
        //     hand a scene's spell id to pm_free, and never move a
        //     PmSpell* into a scene -- pick one mode per cast.
        //
        // ErrQuota is the one failure worth reacting to rather than only
        // logging: the spell compiled, the scene is simply full, so a
        // host may pm_scene_dismiss something and cast again.

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr pm_scene_new(int globalCap);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void pm_scene_free(IntPtr scene);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_scene_cast(IntPtr scene, byte[] circleJsonUtf8,
                                               float[] casterPos, float[] casterFacing,
                                               ulong seed, byte[] errBuf, int errLen,
                                               out int outId);

        // circleJsons is an array of NUL-terminated UTF-8 buffers composed
        // into ONE spell. IntPtr[] rather than byte[][]: the marshaller
        // cannot pin a jagged array, so pin each row yourself (GCHandle,
        // or Marshal.AllocHGlobal + copy) and pass the pointers.
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_scene_cast_many(IntPtr scene, IntPtr[] circleJsons, int count,
                                                    float[] casterPos, float[] casterFacing,
                                                    ulong seed, byte[] errBuf, int errLen,
                                                    out int outId);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void pm_scene_dismiss(IntPtr scene, int spellId);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void pm_scene_advance(IntPtr scene, float dt);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_scene_observe(IntPtr scene,
                                                  float[] posX, float[] posY, float[] posZ,
                                                  float[] size, float[] life, uint[] color,
                                                  int capacity, int[] batchInfo, int maxBatches);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_scene_budget(IntPtr scene, out int outUsed, out int outCap);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_scene_count(IntPtr scene);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_scene_spells(IntPtr scene, int[] outIds, int maxIds);

        // --- Where a spell is (func-spec 0025) ---
        //
        // Optional: a purely visual spell never needs any of it, and a
        // host that calls none of these pays nothing. Nothing here
        // advances a clock or touches a particle, so it is safe to ask
        // between Advance and Observe.
        //
        // outAxes is 9 floats, ROW MAJOR: [0..2] = U (face right),
        // [3..5] = V (face up), [6..8] = the face normal. The oriented
        // box is much tighter than its AABB for a beam-shaped spell;
        // pm_spell_bounds is the axis-aligned answer if your collision
        // layer only speaks AABB.

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_spell_bounds(IntPtr spell, float[] outMin, float[] outMax);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_spell_box(IntPtr spell, float[] outCenter,
                                              float[] outAxes, float[] outHalf);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_emitter_count(IntPtr spell);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_emitter_box(IntPtr spell, int index, float[] outCenter,
                                                float[] outAxes, float[] outHalf);

        // outCounts needs dim*dim*dim ints; a short array gets
        // ErrCapacity and is left untouched.
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_occupancy(IntPtr spell, int dim, int[] outCounts, int capacity);

        // Bit c set == cell c of a 3x3x3 grid holds particles. One call,
        // no array: a broad-phase overlap test is (a & b) != 0.
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern uint pm_occupancy_mask(IntPtr spell);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_scene_spell_bounds(IntPtr scene, int spellId,
                                                       float[] outMin, float[] outMax);

        // --- 2D projection (optional; a 3D host ignores these) ---

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_project(int plane,
                                            float[] posX, float[] posY, float[] posZ,
                                            int count,
                                            float[] outX, float[] outY, float[] outDepth);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int pm_depth_order(int plane,
                                                float[] posX, float[] posY, float[] posZ,
                                                int count, int[] outIndices);
    }

    /// <summary>
    /// Runtime settings for <see cref="Pm.pm_init_ex"/> (host-runtime
    /// F003). Blittable and laid out exactly as the header's PmConfig:
    /// zero it, set <c>size</c>, fill in what you care about. A size this
    /// library does not recognise is Pm.ErrArgs rather than a silently
    /// half-applied configuration.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct PmConfig
    {
        /// <summary>sizeof(PmConfig) -- Marshal.SizeOf&lt;PmConfig&gt;().</summary>
        public uint size;

        /// <summary>0 = follow the hardware; else 1..Pm.MaxCapabilities.
        /// A game host usually wants 2..4, not 0: the whole machine
        /// competes with your own job system.</summary>
        public uint capabilities;

        /// <summary>0 = the runtime's default (4 MiB); else
        /// Pm.NurseryMinBytes..Pm.NurseryMaxBytes.</summary>
        public ulong nursery_bytes;

        /// <summary>Pm.GcDefault or Pm.GcNonmoving (shorter pauses).</summary>
        public uint gc_mode;

        /// <summary>Pm.StatsOff or Pm.StatsOn. Can only be decided
        /// here -- the runtime accepts it while starting up and never
        /// afterwards.</summary>
        public uint stats;
    }

    /// <summary>A particle colour, unpacked from the library's 0xRRGGBBAA word.</summary>
    public struct PmColor
    {
        public byte R, G, B, A;

        public PmColor(byte r, byte g, byte b, byte a) { R = r; G = g; B = b; A = a; }
    }

    /// <summary>
    /// The two conversions every non-Haskell host needs: colour unpacking
    /// and the handedness flip.
    /// </summary>
    public static class PmConvert
    {
        /// <summary>0xRRGGBBAA -- R in the highest byte, A in the lowest.</summary>
        public static PmColor Unpack(uint c) =>
            new PmColor((byte)(c >> 24), (byte)(c >> 16), (byte)(c >> 8), (byte)c);

        /// <summary>Premultiplied-free float channels, 0..1, in case a shader wants them.</summary>
        public static void Unpack(uint c, out float r, out float g, out float b, out float a)
        {
            r = ((c >> 24) & 0xFF) / 255f;
            g = ((c >> 16) & 0xFF) / 255f;
            b = ((c >> 8) & 0xFF) / 255f;
            a = (c & 0xFF) / 255f;
        }

        /// <summary>
        /// A position for the library, from a left-handed host (+Z into
        /// the screen): the abstract space is right-handed, so Z flips.
        /// Getting this wrong never crashes -- it silently reverses the
        /// spin of `vortex` force fields.
        /// </summary>
        public static float[] ToPm(float x, float y, float z) => new[] { x, y, -z };

        /// <summary>
        /// The same flip on the way back, applied to a whole observed
        /// column in place, which is cheaper than per-particle conversion.
        /// </summary>
        public static void FlipZ(float[] posZ, int count)
        {
            if (posZ == null) throw new ArgumentNullException(nameof(posZ));
            int n = Math.Min(count, posZ.Length);
            for (int i = 0; i < n; i++) posZ[i] = -posZ[i];
        }
    }
}
