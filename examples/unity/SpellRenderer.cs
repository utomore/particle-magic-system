// SpellRenderer.cs -- minimal Unity host for the particle magic C ABI
// (func-spec 0011 §7 S5). Manual smoke, like examples/c/main.c: this file
// is not built by the repo, it is dropped into a Unity project alongside
// bindings/csharp/ParticleMagic.cs. See README.md next to it.
//
// What it demonstrates, in order of how easy each is to get wrong:
//
//   1. pm_init() exactly once, pm_shutdown() never (README §4).
//   2. A fixed-timestep accumulator with a per-frame step ceiling, planned
//      by the library's own pm_plan_steps rather than by hand: the
//      simulation always steps FixedDt, the frame rate does whatever it
//      does, and one loading hitch cannot ask for hundreds of steps.
//   3. The handedness flip -- the library's space is right-handed, Unity's
//      is left-handed, so Z is negated in both directions.
//   4. Reused, pre-allocated columns sized from pm_max_particles().
//   5. pm_depth_order() for the alpha batches, which is what func-spec
//      0011 put on the C ABI in the first place: painter's order without
//      reimplementing the sort in C#.

using System;
using UnityEngine;
using ParticleMagic;

public class SpellRenderer : MonoBehaviour
{
    [Tooltip("A magic circle JSON file, e.g. one of assets/spells/*.json from the repo.")]
    public TextAsset circleJson;

    [Tooltip("Blend SrcAlpha OneMinusSrcAlpha, ZWrite Off.")]
    public Material alphaMaterial;

    [Tooltip("Blend SrcAlpha One, ZWrite Off.")]
    public Material additiveMaterial;

    public ulong seed = 42;
    public bool castOnStart = true;

    // Additive blending commutes, so only the alpha batches need ordering.
    public bool sortAlphaBatches = true;

    const int MaxBatches = 8;
    const float FixedDt = 1f / 60f;

    // The same step, widened for the planner: pm_plan_steps works in
    // double, pm_advance_ex takes a float. Deriving one from the other is
    // what keeps the planned time and the advanced time the same number.
    const double FixedDtSeconds = FixedDt;

    // Ceiling on simulation steps in one rendered frame -- the
    // spiral-of-death guard. 8 is the value the repo's demo shell runs on
    // (app/Main.hs, lcMaxStepsPerFrame).
    const int MaxStepsPerFrame = 8;

    // --- Host-owned buffers, allocated once (a per-frame array is just
    // --- garbage for the collector to sweep).
    float[] px, py, pz, size, life;
    uint[] color;
    int[] batchInfo, order;
    int capacity;

    // Vertex scratch: one camera-facing quad per particle.
    Vector3[] vertices;
    Vector2[] uvs;
    Color32[] colors;
    Mesh mesh;

    IntPtr spell = IntPtr.Zero;

    // Double, because pm_plan_steps is: a float accumulator drifts against
    // a double simulation. PmSmoke.cs reaches this field by name.
    double accumulator;

    // The GHC runtime starts once per process and cannot be restarted, so
    // this runs before any scene and nothing ever stops it. See README §4.
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
    static void BootParticleMagic()
    {
        Pm.pm_init();

        int abi = Pm.pm_abi_version();
        if (abi != Pm.AbiVersion)
            Debug.LogError($"particle-magic: ABI {abi} in the DLL, {Pm.AbiVersion} in this binding");
    }

    void Awake()
    {
        // Ask the library, do not trust the macro: PM_MAX_PARTICLES is
        // pinned at the first generation's value, pm_max_particles() is
        // the one that tracks the core.
        capacity = Pm.pm_max_particles();

        px = new float[capacity];
        py = new float[capacity];
        pz = new float[capacity];
        size = new float[capacity];
        life = new float[capacity];
        color = new uint[capacity];
        batchInfo = new int[MaxBatches * Pm.BatchInfoStride];
        order = new int[capacity];

        vertices = new Vector3[capacity * 4];
        uvs = new Vector2[capacity * 4];
        colors = new Color32[capacity * 4];

        mesh = new Mesh { indexFormat = UnityEngine.Rendering.IndexFormat.UInt32 };
        mesh.MarkDynamic();
    }

    void Start()
    {
        if (castOnStart && circleJson != null)
            Cast(circleJson.text, transform.position, transform.forward);
    }

    public void Cast(string json, Vector3 position, Vector3 facing)
    {
        if (spell != IntPtr.Zero) { Pm.pm_free(spell); spell = IntPtr.Zero; }

        var bytes = System.Text.Encoding.UTF8.GetBytes(json + "\0");
        var err = new byte[256];

        int code = Pm.pm_cast_ex(bytes,
                                 PmConvert.ToPm(position.x, position.y, position.z),
                                 PmConvert.ToPm(facing.x, facing.y, facing.z),
                                 seed, err, err.Length, out spell);

        if (code != Pm.Ok)
        {
            int len = Array.IndexOf(err, (byte)0);
            Debug.LogError("particle-magic: " + System.Text.Encoding.UTF8.GetString(err, 0, len < 0 ? err.Length : len));
            spell = IntPtr.Zero;
        }

        accumulator = 0.0;
    }

    void Update()
    {
        if (spell == IntPtr.Zero) return;

        // Fixed timestep, planned by the library instead of by hand.
        // Determinism -- and the force-field integrator -- assume a
        // constant dt, so several steps per rendered frame is normal and
        // costs almost nothing: sampling happens in pm_observe. What the
        // hand-rolled accumulator loop this replaces lacked is the
        // ceiling: one loading hitch and it asks for hundreds of steps,
        // which makes the next frame later still.
        int steps;
        double nextAccumulator;
        if (Pm.pm_plan_steps(FixedDtSeconds, MaxStepsPerFrame, Time.deltaTime,
                             accumulator, out steps, out nextAccumulator) == Pm.Ok)
        {
            accumulator = nextAccumulator;
            for (int i = 0; i < steps; i++) Pm.pm_advance_ex(spell, FixedDt);
        }
        else
        {
            // The planner writes neither output when it rejects an
            // argument, so the accumulator keeps last frame's value and
            // the clock simply does not move this frame.
            Debug.LogWarning("particle-magic: pm_plan_steps rejected this frame's timing");
        }

        int batches = Pm.pm_observe(spell, px, py, pz, size, life, color,
                                    capacity, batchInfo, MaxBatches);
        if (batches < 0)
        {
            // Nothing was written -- do not draw last frame's leftovers.
            Debug.LogWarning("particle-magic: pm_observe returned " + batches);
            return;
        }

        if (batches > 0) Draw(batches);

        if (Pm.pm_is_finished(spell) != 0)
        {
            Pm.pm_free(spell);
            spell = IntPtr.Zero;
        }
    }

    void Draw(int batches)
    {
        var cam = Camera.main;
        if (cam == null) return;

        int total = 0;
        for (int b = 0; b < batches; b++)
            total += batchInfo[b * Pm.BatchInfoStride + 1];
        if (total == 0) return;

        // One call gives a far-to-near permutation of every particle; the
        // per-batch loop below just walks it in order and keeps its own.
        bool ordered = false;
        if (sortAlphaBatches)
            ordered = Pm.pm_depth_order(Pm.PlaneSideXY, px, py, pz, total, order) == Pm.Ok;

        // Billboards face the camera: two screen-aligned axes scaled by
        // each particle's half-extent.
        Vector3 right = cam.transform.right;
        Vector3 up = cam.transform.up;

        mesh.Clear();
        mesh.subMeshCount = batches;

        int vertexCount = 0;
        var triangles = new int[batches][];

        for (int b = 0; b < batches; b++)
        {
            int offset = batchInfo[b * Pm.BatchInfoStride + 0];
            int count = batchInfo[b * Pm.BatchInfoStride + 1];
            int blend = batchInfo[b * Pm.BatchInfoStride + 2];

            var indices = new int[count * 6];
            int written = 0;

            foreach (int i in ParticleOrder(b, offset, count, blend, ordered, total))
            {
                int v = vertexCount;
                // Right-handed -> left-handed: negate Z.
                Vector3 centre = new Vector3(px[i], py[i], -pz[i]);
                float half = size[i];
                Color32 tint = ToUnity(PmConvert.Unpack(color[i]));

                vertices[v + 0] = centre - right * half - up * half;
                vertices[v + 1] = centre + right * half - up * half;
                vertices[v + 2] = centre + right * half + up * half;
                vertices[v + 3] = centre - right * half + up * half;

                uvs[v + 0] = new Vector2(0, 0);
                uvs[v + 1] = new Vector2(1, 0);
                uvs[v + 2] = new Vector2(1, 1);
                uvs[v + 3] = new Vector2(0, 1);

                colors[v + 0] = colors[v + 1] = colors[v + 2] = colors[v + 3] = tint;

                indices[written++] = v + 0;
                indices[written++] = v + 1;
                indices[written++] = v + 2;
                indices[written++] = v + 0;
                indices[written++] = v + 2;
                indices[written++] = v + 3;

                vertexCount += 4;
            }

            triangles[b] = indices;
        }

        mesh.SetVertices(vertices, 0, vertexCount);
        mesh.SetUVs(0, uvs, 0, vertexCount);
        mesh.SetColors(colors, 0, vertexCount);
        for (int b = 0; b < batches; b++)
            mesh.SetTriangles(triangles[b], b, false);

        for (int b = 0; b < batches; b++)
        {
            int blend = batchInfo[b * Pm.BatchInfoStride + 2];
            var material = blend == Pm.BlendAdditive ? additiveMaterial : alphaMaterial;
            if (material != null)
                Graphics.DrawMesh(mesh, Matrix4x4.identity, material, gameObject.layer,
                                  null, b, null, false, false);
        }
    }

    // Alpha batches are drawn far to near (painter's order); additive
    // batches commute, so they stay in buffer order and skip the walk.
    System.Collections.Generic.IEnumerable<int> ParticleOrder(
        int batch, int offset, int count, int blend, bool ordered, int total)
    {
        if (!ordered || blend == Pm.BlendAdditive)
        {
            for (int i = 0; i < count; i++) yield return offset + i;
            yield break;
        }

        for (int k = 0; k < total; k++)
        {
            int i = order[k];
            if (i >= offset && i < offset + count) yield return i;
        }
    }

    static Color32 ToUnity(PmColor c) => new Color32(c.R, c.G, c.B, c.A);

    void OnDestroy()
    {
        if (spell != IntPtr.Zero) { Pm.pm_free(spell); spell = IntPtr.Zero; }
        // Deliberately no pm_shutdown() -- see README §4.
    }
}
