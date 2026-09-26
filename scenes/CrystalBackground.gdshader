shader_type canvas_item;
render_mode unshaded;

uniform float purchase_progress : hint_range(0.0, 1.0) = 0.0;
uniform float research_progress : hint_range(0.0, 1.0) = 0.0;

const vec3 DEEP = vec3(0.035, 0.025, 0.095);
const vec3 VIOLET = vec3(0.20, 0.075, 0.34);
const vec3 CYAN = vec3(0.12, 0.75, 0.95);
const vec3 CRYSTAL = vec3(0.66, 0.34, 1.0);

float diamond_distance(vec2 point) {
	return abs(point.x) * 0.72 + abs(point.y) * 0.52;
}

void fragment() {
	vec2 uv = UV;
	float time = TIME;
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 centered = uv - vec2(0.5);
	centered.x *= aspect;

	// Dégradé sombre et deux halos larges, assez discrets pour garder le texte
	// de l'interface lisible.
	float vertical = smoothstep(0.0, 1.0, uv.y);
	vec3 color = mix(DEEP, vec3(0.065, 0.035, 0.16), vertical);
	float pulse = 0.5 + 0.5 * sin(time * 0.32);
	float central_halo = exp(-length(centered - vec2(0.0, -0.08)) * 3.2);
	float lower_halo = exp(-length(centered - vec2(0.0, 0.34)) * 4.0);
	vec3 glow = mix(VIOLET, CYAN, research_progress * 0.78);
	color += glow * central_halo * (0.075 + pulse * 0.025);
	color += CRYSTAL * lower_halo * (0.025 + pulse * 0.012);

	// Cinq facettes apparaissent l'une après l'autre à mesure que le joueur
	// progresse. Leur dérive lente et leur rotation sont animées par le temps;
	// l'achat agit sur le nombre et l'intensité visibles, pas sur une image fixe.
	for (int i = 0; i < 5; i++) {
		float index = float(i);
		float threshold = index * 0.17;
		float activation = smoothstep(threshold, threshold + 0.24,
			purchase_progress + (i == 0 ? 0.16 : 0.0));
		float side = mod(index, 2.0) * 2.0 - 1.0;
		float drift = sin(time * (0.12 + index * 0.012) + index * 1.7);
		vec2 center = vec2(
			side * (0.14 + 0.15 * fract(index * 0.37)) + drift * 0.025,
			0.12 + 0.17 * mod(index * 0.61, 1.0)
				+ cos(time * 0.09 + index) * 0.025);
		vec2 local = uv - center;
		local.x *= aspect;
		float angle = time * (0.10 + index * 0.018) * side;
		mat2 rotation = mat2(vec2(cos(angle), -sin(angle)),
			vec2(sin(angle), cos(angle)));
		local = rotation * local;
		float size = 0.030 + purchase_progress * 0.012;
		float distance_to_edge = diamond_distance(local);
		float body = 1.0 - smoothstep(size * 0.58, size, distance_to_edge);
		float rim = exp(-abs(distance_to_edge - size) * 150.0);
		vec3 shard_color = mix(CRYSTAL, CYAN, research_progress * 0.68);
		float shimmer = 0.72 + 0.28 * sin(time * 1.1 + index * 2.3);
		color += shard_color * activation * shimmer * (body * 0.18 + rim * 0.11);
	}

	// Une trame de lumière extrêmement faible évite un aplat statique avant le
	// premier achat; sa phase se déplace lentement, sans scintillement rapide.
	float current = sin((uv.x * 5.0 + uv.y * 2.2) * 3.14159 + time * 0.18);
	float lines = smoothstep(0.992, 1.0, abs(current));
	color += glow * lines * (0.008 + purchase_progress * 0.012);
	COLOR = vec4(color, 1.0);
}
