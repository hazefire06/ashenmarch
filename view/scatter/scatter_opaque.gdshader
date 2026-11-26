shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_disabled;

// The ground scatter's solid models (grass blades, mushrooms, pebbles): no
// discard, so early depth testing keeps working on tile GPUs (WebGL2).
#include "res://view/scatter/scatter.gdshaderinc"
