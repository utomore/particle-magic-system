#version 330

// Particle vertex shader (func-spec 0023 S5).
//
// Deliberately the default pipeline's vertex stage, plus one extra
// output: the clip-space position, which the fragment stage needs to work
// out where this fragment sits in the depth buffer for the soft-particle
// fade. Everything else -- the MVP transform, the vertex colour, the
// texcoord -- is what raylib's own vertex shader does, because ADR-0018
// replaces the "no custom shader" premise and nothing else: the billboard
// geometry is still expanded on the CPU (ADR-0009's dynamic quad mesh),
// so this stage has no work of its own to do.

in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;

uniform mat4 mvp;

out vec2 fragTexCoord;
out vec4 fragColor;
out vec4 fragClipPos;

void main()
{
    fragTexCoord = vertexTexCoord;
    fragColor = vertexColor;

    vec4 clip = mvp * vec4(vertexPosition, 1.0);
    fragClipPos = clip;
    gl_Position = clip;
}
