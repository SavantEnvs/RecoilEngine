// Fuzz the savegame deserializer creg::CInputStreamSerializer::LoadPackage
// (rts/System/creg/Serializer.cpp). Savegames (.ssf) are shared between players and loaded
// by the engine; LoadPackage reads the class table, object table and object member data.
// The registered classes mirror upstream's creg unit test (test/engine/System/LoadSave).
#include <cstdint>
#include <exception>
#include <sstream>
#include <string>
#include <vector>

#include "System/creg/creg_cond.h"
#include "System/creg/Serializer.h"

struct EmbeddedObj {
	CR_DECLARE_STRUCT(EmbeddedObj);
	int value;
};
CR_BIND(EmbeddedObj, );
CR_REG_METADATA(EmbeddedObj, CR_MEMBER(value));

enum EnumClass { A, B, C, D };

struct TestObj {
	CR_DECLARE(TestObj);
	TestObj() {
		bvar = false; intvar = 0; fvar = 0.f; enumVar = A;
		for (int a = 0; a < 5; a++) sarray[a] = 0;
		children[0] = children[1] = nullptr;
		embeddedPtr = &embedded;
	}
	virtual ~TestObj() {}

	bool bvar;
	int intvar;
	float fvar;
	EnumClass enumVar;
	std::string str;
	int sarray[5];
	std::vector<int> darray;
	EmbeddedObj* embeddedPtr;
	TestObj* children[2];
	EmbeddedObj embedded;
};
CR_BIND(TestObj, );
CR_REG_METADATA(TestObj, (
	CR_MEMBER(bvar), CR_MEMBER(intvar), CR_MEMBER(fvar), CR_MEMBER(enumVar),
	CR_MEMBER(str), CR_MEMBER(sarray), CR_MEMBER(darray), CR_MEMBER(children),
	CR_MEMBER(embedded), CR_MEMBER(embeddedPtr)
));

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
	std::istringstream is(std::string(reinterpret_cast<const char*>(data), size));
	void* root = nullptr;
	creg::Class* rootCls = nullptr;
	try {
		creg::CInputStreamSerializer ss;
		ss.LoadPackage(&is, root, rootCls);
	} catch (const std::exception&) {
		// content_error / stream errors are the documented way a broken savegame fails
	}
	// Loaded objects are intentionally not freed: the object graph from a corrupt file can
	// alias arbitrarily, and leak detection is off for this fleet.
	return 0;
}
