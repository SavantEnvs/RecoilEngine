// Fuzz the replay (.sdfz) reader CDemoReader (rts/System/LoadSave/DemoReader.cpp): the gzip
// container, demo header, embedded start script, packet stream and player/team statistics.
// Replays are downloaded and shared freely. The call sequence is upstream's demotool
// (tools/DemoTool/DemoTool.cpp): construct, LoadStats, then GetData until ReachedEnd.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>
#include <unistd.h>

#include "System/LoadSave/DemoReader.h"
#include "System/Net/RawPacket.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
	const char* tmp = getenv("TMPDIR");
	std::string path = std::string(tmp && *tmp ? tmp : "/tmp") + "/fuzz_demo_XXXXXX.sdfz";
	const int fd = mkstemps(&path[0], 5);
	if (fd < 0) abort();
	if (size && write(fd, data, size) != (ssize_t)size) abort();
	close(fd);
	try {
		CDemoReader reader(path, 0.0f);
		reader.LoadStats();
		while (!reader.ReachedEnd()) {
			netcode::RawPacket* p = reader.GetData(3.402823466e+38f);
			if (p == nullptr) continue;
			delete p;
		}
	} catch (const std::exception&) {
		// content_error / std::runtime_error: how a broken replay is rejected
	}
	unlink(path.c_str());
	return 0;
}
