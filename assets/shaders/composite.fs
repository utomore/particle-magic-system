#version 330

// Bloom, pass 3 of 3: composite (func-spec 0023 S7).
//
// The blurred bright pass added back over the original image. Added, not
// mixed: bloom is light arriving at the sensor from somewhere it should
// not have, and light adds. Mixing would darken the source wherever the
// glow is strong, which is the opposite of what glowing means.
//
// intensity == 0 makes this the identity on texture0, exactly -- the
// early return, not a multiply by zero. That is the zero-ripple clause of
// S7: with bloom turned off the composite may not alter one bit of the
// image it was handed, and "0 * bloom is 0" would still leave the
// clamp/format round trip in the path.

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

uniform sampler2D bloomTexture;
uniform float intensity;

out vec4 finalColor;

void main()
{
    vec4 base = texture(texture0, fragTexCoord);

    if (intensity <= 0.0) {
        finalColor = base * colDiffuse * fragColor;
        return;
    }

    vec3 bloom = texture(bloomTexture, fragTexCoord).rgb;

    // Clamped, because this is an LDR pipeline (func-spec 0023 §8-5 books
    // real HDR for another round): without the clamp a bright core plus
    // its own glow wraps rather than saturates, and a white-hot particle
    // would come out dark.
    vec3 lit = min(base.rgb + bloom * intensity, vec3(1.0));

    finalColor = vec4(lit, base.a) * colDiffuse * fragColor;
}
