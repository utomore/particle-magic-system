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

        public const int BlendAlpha = 0;        // PM_BLEND_ALPHA
        public const int BlendAdditive = 1;     // PM_BLEND_ADDITIVE
        public const int ShapeSquare = 0;       // PM_SHAPE_SQUARE
        public const int ShapeSoftDot = 1;      // PM_SHAPE_SOFT_DOT
        public const int ShapeRing = 2;         // PM_SHAPE_RING
        public const int ShapeSpark = 3;        // PM_SHAPE_SPARK

        public const int PlaneSideXY = 0;       // PM_PLANE_SIDE_XY: (x, y), depth = -z
        public const int PlaneTopXZ = 1;        // PM_PLANE_TOP_XZ:  (x, z), depth = -y

        // --- Runtime lifecycle ---
        //
        // pm_init() once per process, before anything else. Do NOT call
        // pm_shutdown() unless the process is ending: the GHC runtime
        // cannot be restarted in the same process, and an editor that
        // keeps native plugins loaded between play sessions will fail on
        // the second run (see examples/unity/README.md).

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void pm_init();

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

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void pm_free(IntPtr spell);

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
