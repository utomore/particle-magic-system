#version 330

// Bloom, pass 1 of 3: the bright pass (func-spec 0023 S7).
//
// Keep what is brighter than the threshold, drop the rest. Everything
// downstream blurs and adds back only what survives here, which is why
// bloom reads as "the bright things glow" rather than "the picture is out
// of focus".
//
// The subtract-and-rescale (rather than a hard cutoff) is what keeps the
// glow from having a visible edge of its own: a pixel just over the
// threshold contributes almost nothing and ramps up smoothly, so the
// bloom has no contour where the test flips.

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform float threshold;

out vec4 finalColor;

void main()
{
    vec4 source = texture(texture0, fragTexCoord) * colDiffuse * fragColor;

    // Perceptual luminance: a saturated blue and a saturated yellow of the
    // same RGB magnitude do not glow alike, and weighting by channel is
    // what makes the fire spells bloom without the water ones smearing.
    float luma = dot(source.rgb, vec3(0.2126, 0.7152, 0.0722));

    float keep = max(luma - threshold, 0.0) / max(1.0 - threshold, 0.0001);

    finalColor = vec4(source.rgb * keep, 1.0);
}
