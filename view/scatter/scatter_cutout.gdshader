shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_disabled;

// The ground scatter's leaf and flower cards, cut out at alpha_cutoff.
#define CUTOUT
#include "res://view/scatter/scatter.gdshaderinc"
