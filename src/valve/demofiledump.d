module demoreader.valve.demofiledump;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import demoreader.dr;
import demoreader.util.byteprinter;

// -----------------------------------------------------------------------------

/*
 * demofiledump.h
 * https://github.com/ValveSoftware/csgo-demoinfo/blob/30a0165/demoinfogo/demofiledump.h
 */

enum MAX_PLAYER_NAME_LENGTH = 32;
enum MAX_CUSTOM_FILES       = 4;
enum SIGNED_GUID_LEN        = 32;

struct player_info_t
{
	char[MAX_PLAYER_NAME_LENGTH] name = 0;        /// name as it appears in-game
	int                          userID;
	char[SIGNED_GUID_LEN+1]      guid = 0;        /// steamid3
	ubyte[3]                     padding1;

	uint                         friendsID;       /// accountid
	char[MAX_PLAYER_NAME_LENGTH] friendsName = 0; /// (normally empty, but hacked clients can put stuff here)

	bool                         fakeplayer;
	bool                         ishltv;
	bool                         isreplay;
	ubyte[1]                     padding2;

	uint[MAX_CUSTOM_FILES]       customFiles;     /// crc values of custom files (spray, jingle, 2 x unused)

	ubyte                        filesDownloaded;
	ubyte[3]                     padding3;

	void checkCreate()
	{
		check();
	}

	void checkUpdate(player_info_t* oldValue)
	{
		if (name != oldValue.name)
		{
			assert(DemoReader.get().serverAllowsNameChange);
		}
		assert(userID          == oldValue.userID);
		assert(guid            == oldValue.guid);

		assert(!oldValue.friendsID      || friendsID   == oldValue.friendsID);
		assert(!oldValue.friendsName[0] || friendsName == oldValue.friendsName);

		assert(fakeplayer      == oldValue.fakeplayer);
		assert(ishltv          == oldValue.ishltv);
		assert(isreplay        == oldValue.isreplay);

		//assert(filesDownloaded >= oldValue.filesDownloaded); // skial/2022-04-30_13-39-10.dem

		check();
	}

	void check()
	{
		// 1. name
		assert(name[0]);
		assert(memchr(name.ptr, '\0', name.length));
		assert(!name.hasHiddenData);

		// 2. userid
		assert(userID > 0);

		// 3. guid
		if (guid[0..4] != "BOT\0")
		{
			uint accountid = atoi(&guid["[U:1:".length]);

			assert(accountid > 0);

			char[32] tmp = void;
			snprintf(tmp.ptr, 32, "[U:1:%u]", accountid);
			assert(!strcmp(guid.ptr, tmp.ptr));

			if (friendsID)
				assert(friendsID == accountid);

			assert(!fakeplayer);
		}
		else
		{
			// bot, check that they're allowed
			assert(DemoReader.get().serverAllowsBots);

			// skial/2022-06-27_19-57-54.dem
			// skial/blankit2_skial.dem
			// skial/freakstage_skial.dem
			// % demoreader skial/* | mawk '/^ new/ && /"BOT"/ && (/friendsID/ || !/fakeplayer/)'
			// % demoreader skial/* | mawk '/^ new/ && /"BOT"/ && (/friendsID/ || !/fakeplayer/)' | grep -Po 'friendsID: \K\d+' | mawk '{print"https://steamcommunity.com/profiles/[U:1:"$0"]"}' | sort -Vu
			// they're all pretty low so might not be actual steamids?
			// all are private profiles or "not set up" though
			if (DemoReader.get().isOfficialServer)
			{
				assert(friendsID == 0);
				assert(fakeplayer);
			}

		}
		if (guid.hasHiddenData)
			// tf2-d1.dem (2013)
			assert(guid == "BOT\0 CBaseClient::SendServerInfo\0");

		// 4. padding1
		assert(padding1.isAllZeros);

		// 5. friendsID
		// (all checks done in "3. guid")

		// 6. friendsName
		if (friendsName[0])
		{
			// cheater
			// the bots that set this always have "ZERO WIDTH SPACE" here
			// https://www.fileformat.info/info/unicode/char/200b/index.htm
			static immutable ubyte[friendsName.sizeof] knownFriendsName = [
				0xe2, 0x80, 0x8b,
			];
			//assert(friendsName == cast(char[])knownFriendsName[]);
		}
		assert(!friendsName.hasHiddenData);

		// 7. fakeplayer
		if (fakeplayer)
		{
			assert(guid[0] == 'B');
			assert(DemoReader.get().serverAllowsBots);
		}
		else
		{
			// fakeplayer not set
			// this should be a real player then
			if (DemoReader.get().isOfficialServer)
			{
				assert(guid[0] == '[');
			}
			else
			{
				// there are some bots without fakeplayer set
				// % demoreader skial/* | mawk '/^ new/ && /"BOT"/ && !/fakeplayer/'
				assert(guid[0] == '[' || guid[0] == 'B');
			}
		}

		// 8. ishltv
		if (ishltv)
		{
			assert(fakeplayer);
			assert(guid[0] == 'B');
			assert(DemoReader.get().serverAllowsHalfLifeTelevision);
		}

		// 9. isreplay
		if (isreplay)
		{
			assert(0); // not used
		}

		// 10. padding2
		assert(padding2.isAllZeros);

		// 11. customFiles
		// first two are whatever, last two are unused
		//assert(customFiles[2] == 0);
		//assert(customFiles[3] == 0);

		// 12. filesDownloaded
		if (!filesDownloaded)
		{
			// ok
		}
		else
		{
			assert(DemoReader.get().serverAllowsCustomFileDownload);

			if (filesDownloaded == 1)
				assert(customFiles[0] || customFiles[1]);
			else if (filesDownloaded == 2)
				assert(customFiles[0] && customFiles[1]);
			else
				assert(0);
		}

		// 13. padding3
		assert(padding3.isAllZeros);

		/*
		 * from this we can deduce:
		 * 
		 * the above 3 are always present
		 * 
		 * players load in stages
		 * 1. required fields
		 * 2. above plus friendsID
		 * 3. above plus custom files (if the player has any)
		 * 
		 * unknown where friendsName fits since the bots that use it don't advertise any custom files
		 * 
		 * it's possible for customFiles to load after friendsID
		 * or - a player who has customFiles can appear without them for a moment
		 * to verify:
		 * % ./run | grep -P -A1 'friendsID(?!.*customFiles)'
		 * many have "old: friendsID but no customFiles", "new: same thing but with customFiles added"
		 * 
		 * ^ so, to really know if a player has customFiles, it may not be enough to look at this struct
		 * need to know when they're fully loaded in
		 * maybe some event like spawn, or something...
		 * disconnect might be too early since it's possible to do during the connect process
		 * 
		 * ^ could try to correspond with other events, like the "connected" message
		 * 
		 * are the bots blocking some function that sends customFiles?
		 * or do they really have cl_soundfile set to empty? (fps config?)
		 * 
		 * i wonder if connection problems with steam can affect friendsID
		 * like when item server is down
		 * ^ they wouldn't get on the server, i think
		 */

		/*
		 * maybe friendsID is set when they're authenticated with steam?
		 * 
		 * it's sometimes already set when userinfo is created but not always
		 */

		uint fields = countFields();
		switch (fields)
		{
			// general
			case 0b0_0000_000_00_111: // defaults
			case 0b0_0000_000_01_111: // +friendsId
			case 0b0_0000_000_11_111: // +friendsId +friendsName
			case 0b0_0001_000_01_111: // +friendsId              +spray
			case 0b0_0010_000_01_111: // +friendsId                     +jingle
			case 0b0_0011_000_01_111: // +friendsId              +spray +jingle
				break;

			// non-valve server
			case 0b1_0001_000_01_111: // +friendsId              +spray         +filesDownloaded
			case 0b1_0011_000_01_111: // +friendsId              +spray +jingle +filesDownloaded
			case 0b0_0000_001_00_111: // +fakeplayer
			case 0b0_0000_011_00_111: // +fakeplayer +ishltv
				break;

			default:
			{
				debug
				{
					fprintf(stderr, "unknown fields setup 0x%x\n", fields);
				}
				assert(0, "unknown player info fields setup");
			}
		}
	}

	private uint countFields()
	{
		uint rv;

		if (name[0])         rv |= 1 << 0;
		if (userID)          rv |= 1 << 1;
		if (guid[0])         rv |= 1 << 2;

		if (friendsID)       rv |= 1 << 3;
		if (friendsName[0])  rv |= 1 << 4;

		if (fakeplayer)      rv |= 1 << 5;
		if (ishltv)          rv |= 1 << 6;
		if (isreplay)        rv |= 1 << 7;

		if (customFiles[0])  rv |= 1 << 8;
		if (customFiles[1])  rv |= 1 << 9;
		if (customFiles[2])  rv |= 1 << 10;
		if (customFiles[3])  rv |= 1 << 11;

		if (filesDownloaded) rv |= 1 << 12;

		// test account (shut up asserts)
		// task: fix the switch not to assert on these, maybe check that it's a
		//  listen server or something. would still want to know if anyone else
		//  has these
		if (friendsID % 10000 == 6460 || friendsID == 1111200260)
		{
			rv &= ~(1 << 4);
			rv &= ~(1 << 10);
			rv &= ~(1 << 11);
		}

		return rv;
	}

	void print()
	{
		printf("player_info_t(");

		if (name[0])
			printf("name: \"%s\", ",        name.ptr);
		if (userID)
			printf("userID: %u, ",          userID);
		if (guid[0])
			printf("guid: \"%s\", ",        guid.ptr);
		if (friendsID)
			printf("friendsID: %u, ",       friendsID);

		if (!friendsName.isAllZeros)
		{
			printf("friendsName: ");
			printbytes(cast(ubyte[])friendsName, BYTEPRINTER_NO_UNICODE);
			printf(", ");
		}

		if (fakeplayer)
			printf("fakeplayer: %s, ",      fakeplayer ? "true".ptr : "false".ptr);
		if (ishltv)
			printf("ishltv: %s, ",          ishltv ? "true".ptr : "false".ptr);
		if (isreplay)
			printf("isreplay: %s, ",        isreplay ? "true".ptr : "false".ptr);
		if (customFiles[0] | customFiles[1] | customFiles[2] | customFiles[3])
			printf("customFiles: [%08x, %08x, %08x, %08x], ", customFiles[0], customFiles[1], customFiles[2], customFiles[3]);
		if (filesDownloaded)
			printf("filesDownloaded: %hhu, ", filesDownloaded);

		printf("\b\b)"); // erase last ", " by terminal magic
	}
}
debug static assert(player_info_t.sizeof == 132);

private:

bool hasHiddenData(char[] s)
{
	foreach (i, c; s)
	{
		if (!c)
		{
			return !isAllZeros(s[i..$]);
		}
	}
	assert(0);
}

unittest
{
	assert(!hasHiddenData([1, 2, 0]));
	assert( hasHiddenData([1, 2, 0, 1, 0]));
}

bool isAllZeros(C)(C[] data)
if (C.sizeof == 1)
{
	assert(data.length); // ???

	uint bs;
	foreach (b; data)
	{
		bs |= b;
	}
	return bs == 0;
}

bool isAllZeros(T)(ref T data)
if (__traits(isStaticArray, T))
{
	uint bs;
	foreach (b; (cast(ubyte*)&data)[0..T.sizeof])
	{
		bs |= b;
	}
	return bs == 0;
}

bool hasEmbeddedNull(char[] s)
{
	ubyte seenNul;
	ubyte seenCharAfterNul;
	foreach (c; s)
	{
		seenNul |= !c;
		if (seenNul)
			seenCharAfterNul |= c;
	}
	return seenCharAfterNul != 0;
}

unittest
{
	assert(!hasEmbeddedNull([0]));
	assert(!hasEmbeddedNull([1, 0]));
	assert( hasEmbeddedNull([1, 0, 1, 0]));
}
