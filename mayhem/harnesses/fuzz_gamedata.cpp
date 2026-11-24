// Fuzz the NETMSG_GAMEDATA decoder (GameData(shared_ptr<const RawPacket>)) and the
// re-encoder (GameData::Pack). A client receives this packet from the server; the decoder
// inflates the zlib-compressed start script and reads the checksums and random seed.
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>

#include "Game/GameData.h"
#include "Net/Protocol/BaseNetProtocol.h"
#include "System/Net/RawPacket.h"
#include "System/Net/UnpackPacket.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
	// Packets reach GameData's constructor only after the dispatcher has matched the
	// message id: the constructor asserts pckt->data[0] == NETMSG_GAMEDATA (GameData.cpp).
	if (size < 1 || data[0] != NETMSG_GAMEDATA || size > 0xFFFFFFFFu)
		return -1;

	auto pckt = std::make_shared<const netcode::RawPacket>(data, static_cast<uint32_t>(size));
	std::unique_ptr<GameData> gd;
	try {
		gd = std::make_unique<GameData>(pckt);
	} catch (const netcode::UnpackPacketException&) {
		return 0;
	}

	// Re-encode what was decoded and decode it again: the round trip must preserve the
	// start script (this is what the server does when it forwards GameData to clients).
	const std::string setup = gd->GetSetupText();
	std::unique_ptr<const netcode::RawPacket> packed(gd->Pack());
	if (packed == nullptr)
		return 0; // larger than MAX_PACKED_SIZE: Pack refuses by contract

	std::shared_ptr<const netcode::RawPacket> again(packed.release());
	try {
		GameData gd2(again);
		if (gd2.GetSetupText() != setup || gd2.GetRandomSeed() != gd->GetRandomSeed())
			abort();
	} catch (const netcode::UnpackPacketException&) {
		abort(); // Pack produced a packet its own decoder rejects
	}
	return 0;
}
