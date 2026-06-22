// Core Image colour kernels for skin smoothing, written in Metal Shading
// Language. This replaces the deprecated Core Image Kernel Language
// (`CIColorKernel(source:)`) path: the `.ci.metal` suffix makes Xcode compile
// these into the app's default Metal library with the Core Image kernel ABI,
// so `CIColorKernel(functionName:fromMetalLibraryData:)` can load them.
//
// MSL kernels are precompiled — they initialise faster than CIKL and get
// compile-time diagnostics instead of a runtime `nil`. The maths below is a
// 1:1 port of the previous CIKL kernels (verified by KeyframesAndSkinSmoothTests).

#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

extern "C" {
namespace coreimage {

    // Single-channel skin-tone probability mask in [0,1], in RGB for display.
    float4 skinMask(sample_t image, float warmthBias, float luminanceGate) {
        // Unpremultiply to get true colours for the YCbCr conversion.
        float alpha = image.a;
        float3 rgb = alpha > 0.0 ? image.rgb / alpha : float3(0.0);

        // YCbCr conversion (normalised 0-1 inputs, 0-1 outputs).
        float y  = 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b;
        float cb = 0.5 - 0.168736 * rgb.r - 0.331264 * rgb.g + 0.5 * rgb.b;
        float cr = 0.5 + 0.5 * rgb.r - 0.418688 * rgb.g - 0.081312 * rgb.b;

        // Skin-tone window in Cb-Cr space, biased by warmth.
        float cbMin = 0.3 + warmthBias * 0.05;
        float cbMax = 0.5 + warmthBias * 0.05;
        float crMin = 0.5 + warmthBias * 0.05;
        float crMax = 0.7 + warmthBias * 0.05;

        // Soft falloff at the edges of the window.
        float cbDist = smoothstep(cbMin - 0.05, cbMin, cb) * (1.0 - smoothstep(cbMax, cbMax + 0.05, cb));
        float crDist = smoothstep(crMin - 0.05, crMin, cr) * (1.0 - smoothstep(crMax, crMax + 0.05, cr));

        float skinProb = cbDist * crDist;

        // Luminance gate: reduce probability in very dark or very bright regions.
        float lumGate = smoothstep(0.0, luminanceGate * 0.5, y) * (1.0 - smoothstep(1.0 - luminanceGate * 0.5, 1.0, y));
        skinProb *= lumGate;

        // Scale by alpha so transparent regions don't accumulate probability.
        skinProb *= alpha;

        return float4(skinProb, skinProb, skinProb, alpha);
    }

    // Composites the smoothed image over the original using the mask + strength.
    float4 skinBlend(sample_t original, sample_t smoothed, sample_t mask, float strength) {
        float maskVal = mask.r * strength;
        return mix(original, smoothed, maskVal);
    }

}
}
