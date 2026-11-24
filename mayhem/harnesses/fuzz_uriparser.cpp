// Fuzz the spring:// and rapid:// URI parsers (rts/System/UriParser.cpp); the engine takes
// these from its command line, typically handed over by a lobby or a web link.
#include <cstdint>
#include <string>

#include "System/UriParser.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
	const std::string uri(reinterpret_cast<const char*>(data), size);
	std::string user, pass, host, tag;
	int port = 0;
	ParseSpringUri(uri, user, pass, host, port);
	ParseRapidUri(uri, tag);
	return 0;
}
