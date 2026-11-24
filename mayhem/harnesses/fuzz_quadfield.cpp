// Fuzz CQuadField's ray query GetQuadsOnRay (rts/Sim/Misc/QuadField.cpp). Lua gadgets and
// widgets from downloaded games drive these with arbitrary start/dir/length values
// (Spring.TraceRay*, weapon/projectile ray tests); only the ray traversal compiles
// without the Sim object graph (UNIT_TEST build, as upstream's QuadField test), including NaN, inf and negatives.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#include "Sim/Misc/QuadField.h"
#include "Sim/Misc/GlobalConstants.h"
#include "System/float3.h"

namespace {
struct Reader {
	const uint8_t* p; size_t n;
	float f() { float v = 0.f; if (n >= 4) { memcpy(&v, p, 4); p += 4; n -= 4; } return v; }
	// world coordinate: a signed 16-bit value in 1/4 elmo steps (about +-8192 elmos, maps
	// are at most a few thousand elmos per side, so this covers on- and off-map positions)
	float c() { int16_t v = 0; if (n >= 2) { memcpy(&v, p, 2); p += 2; n -= 2; } return v / 4.0f; }
	uint8_t b() { uint8_t v = 0; if (n) { v = *p++; --n; } return v; }
};

void Check(const QuadFieldQuery& q, int numQuads) {
	if (q.quads == nullptr) return;
	std::vector<int> v(*q.quads);
	for (int qi : v)
		if (qi < 0 || qi >= numQuads) abort(); // index outside the quad grid
	std::sort(v.begin(), v.end());
	if (std::adjacent_find(v.begin(), v.end()) != v.end()) abort(); // duplicate quad
}
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
	Reader r{data, size};
	// Init(mapDims in squares, quadSize in elmos) asserts that the map is a whole number
	// of quads, so derive both from a quad size in squares and a count of quads.
	const int qsq = 1 + (r.b() % 8);
	const int w = qsq * (1 + (r.b() % 16));
	const int h = qsq * (1 + (r.b() % 16));
	quadField.Init(int2(w, h), qsq * SQUARE_SIZE);
	const int numQuads = quadField.GetNumQuadsX() * quadField.GetNumQuadsZ();

	while (r.n > 0) {
		const uint8_t op = r.b() % 2;
		const float3 a(r.c(), r.c(), r.c());
		float3 d(r.c(), r.c(), r.c());
		const float len = r.f();
		// Positions/directions are decoded as bounded world coordinates; the length is a raw
		// float (NaN, inf, negative, huge), the value callers fail to validate (#3266).
		QuadFieldQuery q;
		switch (op) {
			case 0: quadField.GetQuadsOnRay(q, a, d, len); break;
			case 1: quadField.GetQuadsOnRay(q, a, float3(d).SafeNormalize(), len); break;
		}
		Check(q, numQuads);
	}
	return 0;
}
