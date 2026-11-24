// Known-answer tests for the code the fuzz targets reach that upstream's unit tests do not:
// GameData pack/unpack (NETMSG_GAMEDATA) and the spring:// / rapid:// URI parsers.
#include <memory>
#include <string>

#include "Game/GameData.h"
#include "Net/Protocol/BaseNetProtocol.h"
#include "System/Net/RawPacket.h"
#include "System/UriParser.h"

#include <catch_amalgamated.hpp>

TEST_CASE("GameData round trip")
{
	const std::string script = "[GAME]\n{\n\tMapName=Comet Catcher Redux;\n\tGameType=Balanced Annihilation;\n}\n";
	GameData gd(script);
	gd.SetRandomSeed(0xC0FFEEu);
	std::shared_ptr<const netcode::RawPacket> pkt(gd.Pack());
	REQUIRE(pkt != nullptr);
	CHECK(pkt->data[0] == NETMSG_GAMEDATA);
	CHECK(pkt->length == gd.GetPackedSize());

	GameData back(pkt);
	CHECK(back.GetSetupText() == script);
	CHECK(back.GetRandomSeed() == 0xC0FFEEu);
}

TEST_CASE("GameData refuses oversized setup")
{
	// random, incompressible text larger than a 16-bit packet length
	std::string big;
	uint32_t x = 12345;
	for (int i = 0; i < 200000; ++i) { x = x * 1103515245u + 12345u; big.push_back(char(33 + (x >> 16) % 90)); }
	GameData gd(big);
	CHECK(gd.GetPackedSize() > GameData::MAX_PACKED_SIZE);
	CHECK(gd.Pack() == nullptr);
}

TEST_CASE("ParseSpringUri")
{
	std::string user, pass, host;
	int port = 0;
	REQUIRE(ParseSpringUri("spring://alice:secret@example.org:8452", user, pass, host, port));
	CHECK(user == "alice");
	CHECK(pass == "secret");
	CHECK(host == "example.org");
	CHECK(port == 8452);

	user.clear(); pass.clear(); host.clear(); port = 0;
	REQUIRE(ParseSpringUri("spring://example.net", user, pass, host, port));
	CHECK(host == "example.net");
	CHECK(user.empty());

	CHECK_FALSE(ParseSpringUri("http://example.org", user, pass, host, port));
}

TEST_CASE("ParseRapidUri")
{
	std::string tag;
	REQUIRE(ParseRapidUri("rapid://byar:test", tag));
	CHECK(tag == "byar:test");
	CHECK_FALSE(ParseRapidUri("spring://x", tag));
}
