#version 460 core
#include <flutter/runtime_effect.glsl>
uniform vec2 uSize;
uniform vec2 uOrigin;
uniform vec2 uViewport;
uniform vec2 uImageSize;
uniform float uRadius;
uniform float uRefraction;
uniform float uBlur;
uniform float uOpacity;
uniform float uBackgroundOpacity;
uniform vec3 uTint;
uniform vec3 uBase;
uniform float uLight;
uniform vec2 uPointer;
uniform float uActivity;
uniform sampler2D uWallpaper;
out vec4 fragColor;

float distanceToEdge(vec2 p) {
  vec2 q = abs(p - uSize * .5) - (uSize * .5 - vec2(uRadius));
  return length(max(q, vec2(0))) + min(max(q.x, q.y), 0.0) - uRadius;
}
vec3 sampleWallpaper(vec2 p) {
  float scale = max(uViewport.x / uImageSize.x, uViewport.y / uImageSize.y);
  vec2 displayed = uImageSize * scale;
  vec2 uv = (p - (uViewport - displayed) * .5) / displayed;
  return texture(uWallpaper, clamp(uv, vec2(.001), vec2(.999))).rgb;
}
void main() {
  vec2 p = FlutterFragCoord().xy;
  float d = distanceToEdge(p);
  vec2 normal = normalize(vec2(distanceToEdge(p + vec2(.5, 0)) - distanceToEdge(p - vec2(.5, 0)),
    distanceToEdge(p + vec2(0, .5)) - distanceToEdge(p - vec2(0, .5))) + vec2(.00001));
  float lens = pow(clamp(1.0 + d / 32.0, 0.0, 1.0), 2.0);
  vec2 samplePoint = uOrigin + p - normal * uRefraction * lens;
  // Zero activity follows the original sampling path exactly.
  if (uActivity > 0.0) {
    vec2 delta = p - uPointer;
    float influence = pow(max(0.0, 1.0 - length(delta) / 64.0), 2.0);
    samplePoint -= delta * influence * .18 * uActivity;
  }
  vec3 wallpaper = sampleWallpaper(samplePoint) * .4;
  wallpaper += sampleWallpaper(samplePoint + vec2(uBlur, 0)) * .15;
  wallpaper += sampleWallpaper(samplePoint - vec2(uBlur, 0)) * .15;
  wallpaper += sampleWallpaper(samplePoint + vec2(0, uBlur)) * .15;
  wallpaper += sampleWallpaper(samplePoint - vec2(0, uBlur)) * .15;
  vec3 background = mix(uBase, wallpaper, uBackgroundOpacity);
  vec3 color = mix(background, uTint, uOpacity);
  float rim = exp(-abs(d + 1.2) * .9) * uLight;
  float lighting = .5 + .5 * dot(normal, normalize(vec2(-.8, -1)));
  color = mix(color, vec3(1), rim * lighting * .5);
  fragColor = vec4(color, 1);
}
