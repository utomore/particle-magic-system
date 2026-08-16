#version 330

// Particle fragment shader (func-spec 0023 S5/S8).
//
// Two jobs. The first is to be exactly the default raylib shader:
// texture0 (the procedurally generated sprite of func-spec 0015) times
// the vertex colour (the per-particle ColorRamp of func-spec 0002) times
// colDiffuse. That is what keeps "the effects are the magic" true --
// colour is semantics here, and no shader of ours is allowed to reinterpret
// it.
//
// The second is the soft-particle fade. A billboard that intersects solid
// geometry cuts it with a hard straight line, which reads as a sheet of
// paper stuck through the floor. Fading the fragment out as it approaches
// whatever is already in the depth buffer removes the line.
//
// softDistance == 0 turns the second job off ENTIRELY -- not "almost off".
// The early return below is what makes the zero-ripple law of S8 a fact
// about the code rather than a hope about floating point: with the fade
// distance at zero this shader is byte-for-byte the default one.

in vec2 fragTexCoord;
in vec4 fragColor;
in vec4 fragClipPos;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

// Scene depth, as written by the depth pre-pass (App.Scene). Named
// texture1 because that is raylib's own name for the material's SECOND
// map slot, and DrawMesh only binds textures that live in a map slot --
// a sampler registered with SetShaderValueTexture is never bound for a
// mesh draw, which silently makes every particle transparent.
//
// When there is no scene there is nothing to intersect, so the host binds
// softDistance = 0 and this sampler is never read.
uniform sampler2D texture1;
uniform float softDistance;
uniform float nearPlane;
uniform float farPlane;

out vec4 finalColor;

// Depth-buffer value -> distance from the eye, in world units. The buffer
// stores a hyperbolic encoding, so a raw difference of two depth values
// is not a distance and fading on it would make the softness depend on
// how far the camera happens to be from the origin.
float linearize(float depth)
{
    float ndc = depth * 2.0 - 1.0;
    return (2.0 * nearPlane * farPlane)
         / (farPlane + nearPlane - ndc * (farPlane - nearPlane));
}

void main()
{
    vec4 base = texture(texture0, fragTexCoord) * colDiffuse * fragColor;

    if (softDistance <= 0.0) {
        finalColor = base;
        return;
    }

    // Where this fragment lands in the depth texture.
    vec2 screenUV = (fragClipPos.xy / fragClipPos.w) * 0.5 + 0.5;
    float sceneDepth = linearize(texture(texture1, screenUV).r);
    float thisDepth = linearize(gl_FragCoord.z);

    // Fade to nothing as the gap closes. clamp() rather than smoothstep()
    // so that a fragment well clear of the geometry is left at exactly
    // 1.0 -- an approximate 1.0 would dim every particle in the scene
    // slightly, which is a global change dressed up as a local one.
    float fade = clamp((sceneDepth - thisDepth) / softDistance, 0.0, 1.0);

    finalColor = vec4(base.rgb, base.a * fade);
}
