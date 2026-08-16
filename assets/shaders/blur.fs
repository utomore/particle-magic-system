#version 330

// Bloom, pass 2 of 3: one axis of a separable Gaussian (func-spec 0023 S7).
//
// Run twice -- direction = (1,0), then direction = (0,1). A 2D Gaussian
// is the outer product of two 1D ones, so two 9-tap passes give the same
// result as one 81-tap pass at less than a quarter of the samples. That
// separability is the whole reason a blur is affordable per frame at all.
//
// The weights are a normalized 1D Gaussian (sigma ~ 2 texels). They sum
// to 1, which is what keeps the pass from brightening or darkening the
// image it is only supposed to spread.

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

// (1, 0) for the horizontal pass, (0, 1) for the vertical one.
uniform vec2 direction;
// 1 / render-target size, so the tap offsets are one texel apart
// regardless of the resolution the bloom chain runs at.
uniform vec2 texelSize;

out vec4 finalColor;

const float weights[5] = float[](0.227027, 0.194594, 0.121621, 0.054054, 0.016216);

void main()
{
    vec2 step = direction * texelSize;

    vec3 sum = texture(texture0, fragTexCoord).rgb * weights[0];

    for (int i = 1; i < 5; i++) {
        vec2 offset = step * float(i);
        sum += texture(texture0, fragTexCoord + offset).rgb * weights[i];
        sum += texture(texture0, fragTexCoord - offset).rgb * weights[i];
    }

    finalColor = vec4(sum, 1.0) * colDiffuse * fragColor;
}
