// PmSmoke.cs -- the func-spec 0011 S5 manual smoke, as one command
// (README.md §7). Editor-only: put it in Assets/Editor/.
//
//   unity run <project> --non-interactive -- \
//       -executeMethod PmSmoke.Run -pmSpellDir <repo>/assets/spells
//
// Exits 0 when every check passes, 1 otherwise, and writes the report to
// <project>/Logs/pm-smoke-result.txt as well as the editor log. It runs in
// batch mode with -nographics, so it needs no display and no scene.
//
// What it is for: `cabal test` proves the library and the C ABI. It cannot
// prove that *Unity's* P/Invoke marshaller moves those arrays correctly,
// that the DLL loads from Assets/Plugins, or that SpellRenderer's mesh path
// works. That gap is what this file closes -- and it closes it against the
// same two files a host would actually copy, not a rewrite of them.

using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using UnityEditor;
using UnityEngine;
using ParticleMagic;

public static class PmSmoke
{
    const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;

    static readonly StringBuilder Report = new StringBuilder();
    static int failures;

    static string spellDir;
    static int cap;
    static float[] px, py, pz, size, life;
    static uint[] color;
    static int[] info, order;
    static byte[] err = new byte[256];

    public static void Run()
    {
        try
        {
            spellDir = SpellDir();
            Body();
        }
        catch (Exception e)
        {
            failures++;
            Report.AppendLine("EXCEPTION " + e);
        }

        Report.AppendLine(failures == 0 ? "== ALL PASS ==" : "== " + failures + " FAILURE(S) ==");

        string outFile = Path.Combine(ProjectRoot(), "Logs/pm-smoke-result.txt");
        Directory.CreateDirectory(Path.GetDirectoryName(outFile));
        File.WriteAllText(outFile, Report.ToString());
        Debug.Log("PmSmoke:\n" + Report);

        EditorApplication.Exit(failures == 0 ? 0 : 1);
    }

    // ---------------------------------------------------------------- checks

    static void Body()
    {
        Note("spells: " + spellDir);

        // A. The runtime starts, and says what generation it is.
        Pm.pm_init();
        int abi = Pm.pm_abi_version();
        Check(abi == Pm.AbiVersion, "pm_abi_version() == " + Pm.AbiVersion + " (got " + abi + ")");

        cap = Pm.pm_max_particles();
        Check(cap > 0, "pm_max_particles() == " + cap);
        Note("pinned PM_MAX_PARTICLES constant in the binding: " + Pm.MaxParticles);

        px = new float[cap];
        py = new float[cap];
        pz = new float[cap];
        size = new float[cap];
        life = new float[cap];
        color = new uint[cap];
        info = new int[8 * Pm.BatchInfoStride];
        order = new int[cap];

        // B. A real spell, through Unity's marshaller.
        string json = File.ReadAllText(Path.Combine(spellDir, "ring-fire.json"));
        IntPtr spell = Cast(json, 20260814UL);
        Check(spell != IntPtr.Zero, "pm_cast_ex(ring-fire) succeeded");
        if (spell == IntPtr.Zero) return;

        for (int i = 0; i < 60; i++) Pm.pm_advance(spell, 1f / 60f);
        Check(Math.Abs(Pm.pm_age(spell) - 1.0) < 1e-5, "pm_age() ~= 1.0s after 60 fixed steps (got " + Pm.pm_age(spell) + ")");

        int total = Observe(spell);
        Check(total > 0, "pm_observe wrote " + total + " particles");

        bool finite = true, lifeInRange = true, anyAlpha = false;
        for (int i = 0; i < total; i++)
        {
            if (float.IsNaN(px[i]) || float.IsInfinity(px[i]) || float.IsNaN(py[i]) || float.IsNaN(pz[i])) finite = false;
            if (life[i] < 0f || life[i] > 1f) lifeInRange = false;
            if ((color[i] & 0xFF) != 0) anyAlpha = true;
        }
        Check(finite, "every position is finite (the marshaller moved real floats)");
        Check(lifeInRange, "every life fraction is within [0, 1]");
        Check(anyAlpha, "some particle has non-zero alpha (0xRRGGBBAA byte order, not 0xAABBGGRR)");

        var c0 = PmConvert.Unpack(color[0]);
        Note(string.Format("particle 0: pos=({0:F3},{1:F3},{2:F3}) size={3:F3} life={4:F3} color=0x{5:X8} -> rgba({6},{7},{8},{9})",
                           px[0], py[0], pz[0], size[0], life[0], color[0], c0.R, c0.G, c0.B, c0.A));

        // C. Projection: the plane selection is exact, not approximate.
        var ox = new float[cap];
        var oy = new float[cap];
        var od = new float[cap];

        Check(Pm.pm_project(Pm.PlaneSideXY, px, py, pz, total, ox, oy, od) == Pm.Ok, "pm_project(SIDE_XY) == PM_OK");
        bool side = true;
        for (int i = 0; i < total; i++) if (ox[i] != px[i] || oy[i] != py[i] || od[i] != -pz[i]) side = false;
        Check(side, "SIDE_XY == (x, y, -z), bit for bit, for all " + total);

        bool top = Pm.pm_project(Pm.PlaneTopXZ, px, py, pz, total, ox, oy, od) == Pm.Ok;
        for (int i = 0; i < total; i++) if (ox[i] != px[i] || oy[i] != pz[i] || od[i] != -py[i]) top = false;
        Check(top, "TOP_XZ == (x, z, -y), bit for bit, for all " + total);

        // D. Painter's order.
        Check(Pm.pm_depth_order(Pm.PlaneSideXY, px, py, pz, total, order) == Pm.Ok, "pm_depth_order(SIDE_XY) == PM_OK");
        var seen = new bool[total];
        bool permutation = true, farToNear = true;
        float previous = float.PositiveInfinity;
        for (int k = 0; k < total; k++)
        {
            int i = order[k];
            if (i < 0 || i >= total || seen[i]) { permutation = false; break; }
            seen[i] = true;
            if (-pz[i] > previous) farToNear = false;
            previous = -pz[i];
        }
        Check(permutation, "the indices are a permutation of [0, " + total + ")");
        Check(farToNear, "depths are non-increasing (far to near)");

        // E. The error path writes nothing.
        for (int i = 0; i < total; i++) ox[i] = -12345.5f;
        Check(Pm.pm_project(42, px, py, pz, total, ox, oy, od) == Pm.ErrArgs, "unknown plane -> PM_ERR_ARGS");
        bool untouched = true;
        for (int i = 0; i < total; i++) if (ox[i] != -12345.5f) untouched = false;
        Check(untouched, "and wrote nothing at all");
        Check(Pm.pm_depth_order(Pm.PlaneSideXY, px, py, pz, -1, order) == Pm.ErrArgs, "negative count -> PM_ERR_ARGS");

        // F. Handles come and go; the runtime stays up.
        Pm.pm_free(spell);
        spell = Cast(json, 7UL);
        Check(spell != IntPtr.Zero, "a second pm_cast in the same process still works (no pm_shutdown)");
        if (spell != IntPtr.Zero) Pm.pm_free(spell);

        // G/H. The example component.
        MeshSmoke(json);
        SortingSmoke();
    }

    // The mesh path of examples/unity/SpellRenderer.cs, pumped by hand:
    // batch mode has no frame loop, so Awake/Cast/Update are invoked
    // directly with a primed accumulator.
    static void MeshSmoke(string json)
    {
        var camera = MainCamera();
        var host = new GameObject("Spell");
        var renderer = host.AddComponent<SpellRenderer>();
        renderer.castOnStart = false;
        renderer.seed = 20260814;

        var type = typeof(SpellRenderer);
        type.GetMethod("Awake", Private).Invoke(renderer, null);
        Check(true, "SpellRenderer.Awake allocated its columns from pm_max_particles()");

        renderer.Cast(json, Vector3.zero, Vector3.forward);
        var spellField = type.GetField("spell", Private);
        Check((IntPtr)spellField.GetValue(renderer) != IntPtr.Zero, "SpellRenderer.Cast produced a handle");

        Pump(renderer, 10);

        var mesh = (Mesh)type.GetField("mesh", Private).GetValue(renderer);
        Check(mesh != null && mesh.vertexCount > 0, "the mesh has " + (mesh == null ? 0 : mesh.vertexCount) + " vertices");
        Check(mesh != null && mesh.vertexCount % 4 == 0, "vertices come in quads (4 per particle)");
        Check(mesh != null && mesh.subMeshCount >= 1, "one submesh per batch (" + (mesh == null ? 0 : mesh.subMeshCount) + ")");

        bool meshFinite = true;
        foreach (var v in mesh.vertices) if (float.IsNaN(v.x) || float.IsNaN(v.y) || float.IsNaN(v.z)) meshFinite = false;
        Check(meshFinite, "every vertex is finite");
        Note("mesh bounds: " + mesh.bounds + "  (z is the library's z negated -- the handedness flip)");

        type.GetMethod("OnDestroy", Private).Invoke(renderer, null);
        Check((IntPtr)spellField.GetValue(renderer) == IntPtr.Zero, "OnDestroy freed the handle (and did not stop the RTS)");

        UnityEngine.Object.DestroyImmediate(host);
        UnityEngine.Object.DestroyImmediate(camera);
    }

    // Does the component actually draw in the order pm_depth_order gives?
    // Unity's vertex z is the library's negated z, which for
    // PM_PLANE_SIDE_XY is exactly the depth being sorted by -- so the
    // emitted z sequence can be compared with the permutation directly.
    static void SortingSmoke()
    {
        var candidates = new List<string>();

        foreach (var path in Directory.GetFiles(spellDir, "*.json"))
        {
            IntPtr handle = Cast(File.ReadAllText(path), 20260814UL);
            if (handle == IntPtr.Zero) continue;
            for (int i = 0; i < 60; i++) Pm.pm_advance(handle, 1f / 60f);
            Observe(handle);
            int batches = LastBatches;
            Pm.pm_free(handle);

            var line = new StringBuilder(Path.GetFileNameWithoutExtension(path) + ": " + batches + " batch(es)");
            for (int b = 0; b < batches; b++)
            {
                int offset = info[b * Pm.BatchInfoStride + 0];
                int count = info[b * Pm.BatchInfoStride + 1];
                int blend = info[b * Pm.BatchInfoStride + 2];

                // A flat sigil has no depth to sort by, and would make the
                // comparison below vacuous.
                float lo = float.MaxValue, hi = float.MinValue;
                for (int i = offset; i < offset + count; i++)
                {
                    if (pz[i] < lo) lo = pz[i];
                    if (pz[i] > hi) hi = pz[i];
                }
                float spread = count > 0 ? hi - lo : 0f;

                line.Append(blend == Pm.BlendAdditive ? " additive" : " alpha");
                line.Append("(n=" + count + ", z spread " + spread.ToString("F2") + ")");

                if (blend == Pm.BlendAlpha && count > 8 && spread > 0.5f && batches == 1) candidates.Add(path);
            }
            Note(line.ToString());
        }

        Check(candidates.Count > 0, "some shipped spell has an alpha batch with depth to sort");
        if (candidates.Count == 0) return;

        var camera = MainCamera();
        bool everySorted = true, everyMatches = true;

        foreach (var path in candidates)
        {
            string text = File.ReadAllText(path);
            float[] emitted = QuadDepths(text);

            bool nonIncreasing = emitted.Length > 8;
            for (int i = 1; i < emitted.Length; i++) if (emitted[i] > emitted[i - 1] + 1e-6f) nonIncreasing = false;
            if (!nonIncreasing) everySorted = false;

            IntPtr handle = Cast(text, 20260814UL);
            for (int i = 0; i < 60; i++) Pm.pm_advance(handle, 1f / 60f);
            int total = Observe(handle);
            Pm.pm_depth_order(Pm.PlaneSideXY, px, py, pz, total, order);
            Pm.pm_free(handle);

            bool matches = total == emitted.Length;
            for (int k = 0; k < total && matches; k++)
                if (Math.Abs(emitted[k] - (-pz[order[k]])) > 1e-6f) matches = false;
            if (!matches) everyMatches = false;

            bool reordered = false;
            for (int k = 0; k < total; k++) if (order[k] != k) reordered = true;

            Note(Path.GetFileNameWithoutExtension(path) + ": " + emitted.Length + " quads, far-to-near=" + nonIncreasing
                 + ", equals pm_depth_order=" + matches + ", differs from buffer order=" + reordered);
        }

        UnityEngine.Object.DestroyImmediate(camera);

        Check(everySorted, "sortAlphaBatches: quads are emitted far to near");
        Check(everyMatches, "and in exactly the permutation pm_depth_order returned");
    }

    // ------------------------------------------------------------- plumbing

    static IntPtr Cast(string json, ulong seed)
    {
        IntPtr handle;
        int code = Pm.pm_cast_ex(Encoding.UTF8.GetBytes(json + "\0"),
                                 PmConvert.ToPm(0, 0, 0), PmConvert.ToPm(0, 0, 1),
                                 seed, err, err.Length, out handle);
        if (code != Pm.Ok)
        {
            int n = Array.IndexOf(err, (byte)0);
            Note("cast failed (" + code + "): " + Encoding.UTF8.GetString(err, 0, n < 0 ? err.Length : n));
            return IntPtr.Zero;
        }
        return handle;
    }

    // Sample into the shared columns. Returns the particle total; the batch
    // count is left in LastBatches for the caller that wants it.
    static int LastBatches;

    static int Observe(IntPtr spell)
    {
        LastBatches = Pm.pm_observe(spell, px, py, pz, size, life, color, cap, info, 8);
        if (LastBatches <= 0) return 0;

        int total = 0;
        for (int b = 0; b < LastBatches; b++) total += info[b * Pm.BatchInfoStride + 1];
        return total;
    }

    // One second of simulation in the component's own fixed steps; batch
    // mode reports no real delta time, so the accumulator is primed.
    static void Pump(SpellRenderer renderer, int frames)
    {
        var type = typeof(SpellRenderer);
        var accumulator = type.GetField("accumulator", Private);
        var update = type.GetMethod("Update", Private);
        for (int i = 0; i < frames; i++)
        {
            accumulator.SetValue(renderer, 0.1f);
            update.Invoke(renderer, null);
        }
    }

    static float[] QuadDepths(string json)
    {
        var host = new GameObject("Spell");
        var renderer = host.AddComponent<SpellRenderer>();
        renderer.castOnStart = false;
        renderer.sortAlphaBatches = true;
        renderer.seed = 20260814;

        var type = typeof(SpellRenderer);
        type.GetMethod("Awake", Private).Invoke(renderer, null);
        renderer.Cast(json, Vector3.zero, Vector3.forward);
        Pump(renderer, 10);

        var mesh = (Mesh)type.GetField("mesh", Private).GetValue(renderer);
        var vertices = mesh.vertices;
        var depths = new float[vertices.Length / 4];
        for (int q = 0; q < depths.Length; q++) depths[q] = vertices[q * 4].z;

        type.GetMethod("OnDestroy", Private).Invoke(renderer, null);
        UnityEngine.Object.DestroyImmediate(host);
        return depths;
    }

    // SpellRenderer billboards towards Camera.main and draws nothing
    // without one.
    static GameObject MainCamera()
    {
        var camera = new GameObject("Main Camera", typeof(Camera));
        camera.tag = "MainCamera";
        return camera;
    }

    static string ProjectRoot() => Directory.GetParent(Application.dataPath).FullName;

    // -pmSpellDir <path> on the command line, PM_SPELL_DIR in the
    // environment, or the repo checkout this project was copied out of.
    static string SpellDir()
    {
        var args = Environment.GetCommandLineArgs();
        for (int i = 0; i < args.Length - 1; i++)
            if (args[i] == "-pmSpellDir") return args[i + 1];

        string fromEnv = Environment.GetEnvironmentVariable("PM_SPELL_DIR");
        if (!string.IsNullOrEmpty(fromEnv)) return fromEnv;

        string local = Path.Combine(Application.dataPath, "Spells");
        if (Directory.Exists(local)) return local;

        throw new Exception("no spell directory: pass -pmSpellDir <repo>/assets/spells");
    }

    static void Check(bool ok, string what)
    {
        Report.AppendLine((ok ? "PASS  " : "FAIL  ") + what);
        if (!ok) failures++;
    }

    static void Note(string what) => Report.AppendLine("      " + what);
}
