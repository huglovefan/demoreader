/**
 * implementation of string table code
 */
module demoreader.stringtable;

import core.stdc.stdio;
import std.algorithm;
import std.array;
import demoreader.globals;
import demoreader.valve.bitbuf;
import demoreader.valve.demofiledump;
import demoreader.player;
static import demoreader.entitystuff;

enum trace1 = false; // print table names for trace1

enum StringTableSource
{
	svcCreateStringTable, /// svc_createstringtable (early 1)
	demStringTables,      /// dem_stringtables (early 2)
	svcUpdateStringTable, /// svc_updatestringtable
	none = -1,
}
static assert(StringTableSource.svcCreateStringTable == 0);

Player2.UserInfoSource toUserInfoSource(StringTableSource updateSource)
{
	return cast(Player2.UserInfoSource)updateSource;
}

struct StringTable
{
	alias Entry = StringTableEntry;

	char[] name;
	uint   maxEntries;
	bool   userDataFixedSize;
	uint   userDataSizeBits;

	Entry*[] entries;

	/// check the table for consistency
	/// called after we finish creating/adding/updating all entries in a packet
	void check()
	{
		assert(entries.length <= maxEntries);
		if (name == "userinfo")
			Player2.check();
	}

static:
	StringTable*[]    defs;
	StringTableSource updateSource; /// source of currently happening string table updates

	void reset()
	{
		defs = null;
		updateSource = StringTableSource.none;
	}

	StringTable* get(uint no)
	{
		if (no < defs.length)
			return defs.ptr[no];
		else
			return null;
	}

	StringTable* get(const(char)[] name)
	{
		foreach (st; defs)
		{
			if (st.name == name)
				return st;
		}
		return null;
	}
}

struct StringTableEntry
{
	char[]  name;
	ubyte[] data;

	void setData(ubyte[] newdata, StringTable* st, int entryIndex, StringTableSource updateSource)
	{
		ubyte[] olddata = data;
		data = newdata;

		// hack: convert steamids in super ancient demos
		if (newdata.length == player_info_t.sizeof)
		{
			player_info_t* info = cast(player_info_t*)newdata.ptr;

			if (
				info.guid[0] == 'S' &&
				st.name == "userinfo")
			{
				import core.stdc.stdlib : atoi;
				uint a = atoi(&info.guid["STEAM_0:".length]);
				uint b = atoi(&info.guid["STEAM_0:0:".length]);
				uint accountid = b << 1 | a;
				char[info.guid.sizeof] buf = 0;
				snprintf(buf.ptr, buf.length, "[U:1:%u]", accountid);
				info.guid = buf;
			}
		}

		if (st.name == "instancebaseline")
		{
			scope buf = new bf_read(newdata);
			demoreader.entitystuff.parseInstanceBaseline(buf, cast(string)name);
		}

		/*
		 * print change stuff
		 * done before updating the Player struct
		 */
		//static if (0)
		if (TRACE1)
		if (st.name == "userinfo")
		{
			enum printJoinLeave = true; // short steamid+name listing
			enum printDiff = true; // print old and new
			enum printChanges = false; // print specific changed properties

			// it can get updated with the same data
			if (olddata == newdata)
				return;

			player_info_t* olduser = cast(player_info_t*)olddata.ptr;
			player_info_t* newuser = cast(player_info_t*)newdata.ptr;

			if (printJoinLeave)
			{
				if (olduser && (!newuser || newuser.guid != olduser.guid))
				{
					printf("-%s %s\n", olduser.name.ptr, olduser.guid.ptr);
				}
				if (newuser && (!olduser || olduser.guid != newuser.guid))
				{
					printf("+%s %s\n", newuser.name.ptr, newuser.guid.ptr);
				}
			}

			// some properties changed, print which ones
			if (printChanges && olduser && newuser && olduser.userID == newuser.userID)
			{
				printf("%s.%s (%s): changed:",
					st.name.ptr, this.name.ptr,
					newuser.name.ptr,
					);
				static foreach (m; __traits(allMembers, player_info_t))
				{
					static if (is(typeof(__traits(getMember, player_info_t, m)) == function))
						{}
					else
					{
						if (__traits(getMember, olduser, m) != __traits(getMember, newuser, m))
						{
							static if (is(typeof(__traits(getMember, olduser, m)) : const char[]))
								printf(" %s %s -> %s", m.ptr, __traits(getMember, olduser, m).ptr, __traits(getMember, newuser, m).ptr);
							else static if (is(typeof(__traits(getMember, olduser, m)) : uint))
								printf(" %s %u -> %u", m.ptr, __traits(getMember, olduser, m), __traits(getMember, newuser, m));
							else static if (is(typeof(__traits(getMember, olduser, m)) : const uint[]))
								printf(" %s [%08x %08x] -> [%08x %08x]", m.ptr,
									__traits(getMember, olduser, m)[0],
									__traits(getMember, olduser, m)[1],
									__traits(getMember, newuser, m)[0],
									__traits(getMember, newuser, m)[1],
									);
							else
								printf(" %s (?)", m.ptr);
						}
					}
				}
				printf("\n");
			}

			if (printDiff)
			{
				if (olduser)
				{
					printf(" old %s.%s: ", st.name.ptr, this.name.ptr);
					olduser.print();
					printf("\n");
				}
				printf(" new %s.%s: ", st.name.ptr, this.name.ptr);
				if (newuser) newuser.print();
				else printf("(null)");
				printf("\n");
			}

			//olduser && olduser.check();
			//newuser && newuser.check();
			//if (olduser && newuser)
			//	newuser.checkChange(olduser);
		}

		/*
		 * update Player struct
		 */
		if (st.name == "userinfo")
		{
			assert(!olddata.ptr || olddata.length == player_info_t.sizeof);
			assert(!newdata.ptr || newdata.length == player_info_t.sizeof);

			player_info_t* olduser = cast(player_info_t*)olddata.ptr;
			player_info_t* newuser = cast(player_info_t*)newdata.ptr;

			// change event for the same userid?
			// means it's an update to the existing player
			if (
				olduser && newuser &&
				olduser.userID == newuser.userID)
			{
				// skip updates with the same data
				if (newdata != olddata)
				{
					Player2* pl = Player2.getBySlotIndex(entryIndex, /* force */ true);
					assert(pl);
					pl.setUserInfo(newuser, updateSource.toUserInfoSource);

					newuser.checkUpdate(olduser);
				}
			}
			else
			{
				Player2* oldPl;
				Player2* newPl;

				// old userid gone?
				if (olduser && (!newuser || newuser.userID != olduser.userID))
				{
					oldPl = Player2.getBySlotIndex(entryIndex, /* force */ true);
					assert(oldPl);
					oldPl.setDisconnected(Player2.DisconnectReason.userInfoRemoved);
				}

				// new userid?
				if (newuser && (!olduser || olduser.userID != newuser.userID))
				{
					// note: can be the same as oldPl if it existed already
					// (was created early by the join message thing)
					// in that case, this works like a userinfo update
					newPl = Player2.createForNewUserInfo(entryIndex, newuser, updateSource.toUserInfoSource);
					assert(newPl);
					newuser.checkCreate();
				}

				// old userinfo was removed or replaced by a different player
				if (olduser && (!newuser || newuser.userID != olduser.userID))
				{
					// if it already existed, skip the call because this was
					//  more like a userinfo update than a replacement/removal
					bool alreadyExisted = (newPl == oldPl);

					if (!alreadyExisted)
						oldPl.onStringTableEntryReplacedOrRemoved(newPl);
				}
			}
		}
	}
}

/**
 * parse the data from a SvcCreateStringTable packet
 * 
 * see: CNetworkStringTable::ParseUpdate in engine/networkstringtable.cpp
 */
void readCreateStringTable(bf_read sbuf, StringTable* st, uint numEntries)
{
	enum print = false;
	enum printjoin = false;
	enum printhdr = false;

	if (print || printhdr)
		printf("SvcCreateStringTable (%u)\n", numEntries);

	StringTable.updateSource = StringTableSource.svcCreateStringTable;
	scope(exit)
		StringTable.updateSource = StringTableSource.none;

	enum SUBSTRING_BITS = 5;
	enum MAX_USERDATA_BITS = 14;

	auto stes = appender!(StringTable.Entry*[])();
	stes.reserve(numEntries);

	History!32 hist;

	foreach (loopIndex; 0..numEntries)
	{
		/*
		 * figure out index
		 */

		// Create always has all of them in sequential order
		alias entryIndex = loopIndex;
		if (!sbuf.ReadOneBit())
			assert(0);

		/*
		 * get teh name
		 */

		char[] itemName;
		uint   hasName = sbuf.ReadOneBit();

		if (hasName)
		{
			if (sbuf.ReadOneBit())
			{
				uint   index       = sbuf.ReadUBitLong(5);
				uint   bytestocopy = sbuf.ReadUBitLong(SUBSTRING_BITS);
				char[] part        = sbuf.ReadDString();

				auto s = appender!(char[])();
				s.reserve(bytestocopy+part.length+1);

				s ~= hist.at(index)[0..bytestocopy];
				s ~= part;
				s ~= '\0';

				itemName = s[];
				itemName = itemName.ptr[0..itemName.length-1]; // null byte

				if (printjoin)
				{
					char[] histstr = hist.at(index)[0..bytestocopy];

					printf("joined: [%.*s] [%.*s]\n",
						bytestocopy, histstr.ptr,
						cast(int)part.length, part.ptr,
						);
				}
			}
			else
			{
				itemName = sbuf.ReadDString();
			}
		}
		else
		{
			// Create always has names
			assert(0);
		}

		/*
		 * read teh data
		 */

		ubyte[] itemData;
		uint    hasData = sbuf.ReadOneBit();

		if (hasData)
		{
			if (st.userDataFixedSize)
			{
				itemData = sbuf.ReadDBitArray(st.userDataSizeBits);
			}
			else
			{
				uint bytes = sbuf.ReadUBitLong(MAX_USERDATA_BITS);
				itemData   = sbuf.ReadDByteArray(bytes);
			}
		}

		if (print)
			printf("    %s[%u]: new: %s\n", st.name.ptr, entryIndex, itemName.ptr);

		StringTable.Entry* ste = new StringTable.Entry(itemName);
		ste.setData(itemData, st, entryIndex, StringTableSource.svcCreateStringTable);
		stes ~= ste;

		hist.add(itemName);
	}

	st.entries = stes[];
	assert(st.entries.length == numEntries);
	st.check();
}

/**
 * parse the data from the dem_stringtables message
 * 
 * see: CNetworkStringTable::ReadStringTable in engine/networkstringtable.cpp
 */
void readDemoStringTables(bf_read buf)
{
	enum print = false;
	enum printhdr = false; // print only header

	if (print || printhdr)
		printf("dem_stringtables\n");

	StringTable.updateSource = StringTableSource.demStringTables;
	scope(exit)
		StringTable.updateSource = StringTableSource.none;

	foreach (st; StringTable.defs)
	{
		if (st.name != "userinfo")
			st.entries = null;
	}

	//printf("-\n");
	//printf("-dem_stringtables\n");
	//printf("-\n");

	uint numTables = buf.ReadByte();

	foreach (tableIndex; 0..numTables)
	{
		char[] tableName  = buf.ReadDString();
		uint   numEntries = buf.ReadWord();

		if (print)
			printf("*** [%d/%d] %s (%u)\n", tableIndex+1, numTables, tableName.ptr, numEntries);

		if (trace1)
			printf("  %s\n", tableName.ptr);

		StringTable* st = StringTable.get(tableIndex);
		assert(st);
		assert(st.name == tableName);
		assert(!st.entries.length || st.name == "userinfo");

		if (st.name == "userinfo")
			assert(st.entries.length == numEntries); // old count is correct

		auto stes = appender!(StringTableEntry*[])();
		stes.reserve(numEntries);

		foreach (entryIndex; 0..numEntries)
		{
			char[] entryName = buf.ReadDString();

			// hack: use the existing entry if userinfo
			StringTableEntry* ste;
			if (st.name == "userinfo")
				ste = st.entries[entryIndex];
			else
				ste = new StringTableEntry(entryName);

			stes ~= ste;

			/*
			 * data supplied?
			 */
			if (buf.ReadOneBit())
			{
				uint    userDataSize = buf.ReadWord();
				ubyte[] data         = buf.ReadDByteArray(userDataSize);

				if (print)
					printf("    [%u/%u] %s (%u bytes)\n", entryIndex+1, numEntries, entryName.ptr, userDataSize);

				ste.setData(data, st, entryIndex, StringTableSource.demStringTables);
			}
			else
			{
				if (print)
					printf("    [%u/%u] %s (no data)\n", entryIndex+1, numEntries, entryName.ptr);

				// no data means empty data
				ste.setData(null, st, entryIndex, StringTableSource.demStringTables);
			}
		}

		/*
		 * "client side stuff"
		 * 
		 * current year todo: what were these?
		 */
		uint numClientEntries;
		enum clientIgnoreCnt = 2;
		if (buf.ReadOneBit())
		{
			if (print)
				printf("*** client side stuff\n");

			numClientEntries = buf.ReadWord();
			stes.reserve(numClientEntries);

			foreach (loopIndex; 0..numClientEntries)
			{
				char[] entryName = buf.ReadDString();

				if (loopIndex >= clientIgnoreCnt)
				{
					stes ~= new StringTableEntry(entryName);
				}

				if (buf.ReadOneBit())
				{
					// these never have data
					assert(0);
				}
				else
				{
					if (print)
						printf("    [%u/%u] %s (no data)\n", loopIndex+1, numClientEntries, entryName.ptr);
				}
			}
		}

		st.entries = stes[];
		assert(st.entries.length == numEntries+cast(uint)max(cast(int)numClientEntries-clientIgnoreCnt, 0));
		st.check();
	}
}

/**
 * parse the data from a SvcUpdateStringTable packet
 * 
 * see: CNetworkStringTable::ParseUpdate in engine/networkstringtable.cpp
 */
void updateStringTable(bf_read sbuf, StringTable* st, uint numEntries)
{
	import std.math : log2;

	enum print = false;
	enum printhdr = false;
	enum printjoin = false;

	enum SUBSTRING_BITS = 5;
	enum MAX_USERDATA_BITS = 14;

	if (print || printhdr)
		printf("SvcUpdateStringTable (%u)\n", numEntries);

	StringTable.updateSource = StringTableSource.svcUpdateStringTable;
	scope(exit)
		StringTable.updateSource = StringTableSource.none;

	History!32 hist;

	int entryIndex = -1;
	int entryIndexBits = cast(int)log2(double(st.maxEntries));

	foreach (loopIndex; 0..numEntries)
	{
		/*
		 * figure out index
		 */
		entryIndex = (sbuf.ReadOneBit())
		/**/       ? entryIndex+1
		/**/       : sbuf.ReadUBitLong(entryIndexBits);

		/*
		 * get teh name
		 */

		char[] itemName;
		uint   hasName = sbuf.ReadOneBit();

		if (hasName)
		{
			if (sbuf.ReadOneBit())
			{
				uint   index       = sbuf.ReadUBitLong(5);
				uint   bytestocopy = sbuf.ReadUBitLong(SUBSTRING_BITS);
				char[] part        = sbuf.ReadDString();

				auto s = appender!(char[])();
				s.reserve(bytestocopy+part.length+1);

				s ~= hist.at(index)[0..bytestocopy];
				s ~= part;
				s ~= '\0';

				itemName = s[];
				itemName = itemName.ptr[0..itemName.length-1]; // null byte

				if (printjoin)
				{
					char[] histstr = hist.at(index)[0..bytestocopy];

					printf("joined: [%.*s] [%.*s]\n",
						bytestocopy, histstr.ptr,
						cast(int)part.length, part.ptr,
						);
				}
			}
			else
			{
				itemName = sbuf.ReadDString();
			}
		}

		/*
		 * read teh data
		 */
		ubyte[] itemData;
		if (sbuf.ReadOneBit())
		{
			if (st.userDataFixedSize)
			{
				itemData = sbuf.ReadDBitArray(st.userDataSizeBits);
			}
			else
			{
				uint bytes = sbuf.ReadUBitLong(MAX_USERDATA_BITS);
				itemData   = sbuf.ReadDByteArray(bytes);
			}
		}

		/*
		 * entry already exists?
		 */
		if (entryIndex < st.entries.length)
		{
			StringTableEntry* ste = st.entries.ptr[entryIndex];

			static if (print)
				bool printed;

			// update name
			if (hasName)
			{
				if (print)
				{
					if (ste.name != itemName)
					{
						printf("    %s[%u]: %s -> %s\n", st.name.ptr, entryIndex, ste.name.ptr, itemName.ptr);
						static if (print)
							printed = true;
					}
				}

				/*
				 * bug: this assert fails
				 * 
				 * https://developer.valvesoftware.com/wiki/Networking_Events_&_Messages#String_Tables
				 * > An entry string itself can't be changed any more once it has been added.
				 * 
				 * fails: demos/2022-07-18_16-03-15.dem
				 * 3 instances across all demos and it's always the same one
				 * [note: comment is old, may have more now]
				 * 
				 * ParticleEffectNames[3442]: contract_score_primary -> eotl_pyro_gas_pour2
				 * ParticleEffectNames[3479]: contract_score_primary -> eotl_pyro_gas_pour2
				 * ParticleEffectNames[3479]: contract_score_primary -> eotl_pyro_gas_pour2
				 * 
				 * "contract_score_primary" doesn't sound like a particle name...
				 * 
				 * (check what it is when the table is created, whether its neighboring ones look correct)
				 * ^ also compare with other demos
				 */
				//assert(ste.name == itemName);
				/*if (ste.name != itemName)
				{
					printf("*** BUG: string table entry name changed: %s[%u]: %s -> %s\n",
						st.name.ptr,
						entryIndex,
						ste.name.ptr,
						itemName.ptr,
						);
				}*/

				ste.name = itemName;
			}

			/*
			 * update data
			 * 
			 * (this is always assigned, e.g. player disconnect calls this
			 *  with no data but expects the value to be cleared)
			 */
			if (print && ste.data != itemData)
			{
				printf("    %s[%u]: data updated: %zu -> %zu bytes\n", st.name.ptr, entryIndex, ste.data.length, itemData.length);
				static if (print)
					printed = true;
			}
			ste.setData(itemData, st, entryIndex, StringTableSource.svcUpdateStringTable);

			static if (print)
			{
				if (!printed)
					printf("    %s[%u]: no change\n", st.name.ptr, entryIndex);
			}

			// use the old name for history
			if (!hasName)
				itemName = ste.name;
		}
		else
		{
			/*
			 * entry doesn't exist, create
			 */

			if (print)
				printf("    %s[%u]: new: %s\n", st.name.ptr, entryIndex, itemName.ptr);

			assert(entryIndex == st.entries.length);
			StringTableEntry* ste = new StringTableEntry(itemName);
			ste.setData(itemData, st, entryIndex, StringTableSource.svcUpdateStringTable);
			st.entries ~= ste;
		}

		hist.add(itemName);
	}

	st.check();
}

/**
 * optimized name history for updateStringTable()
 */
struct History(uint LEN = 32)
{
@nogc:
	char[][LEN] items;
	uint        idx;
	bool        wrap;

	char[] at(uint wantIdx)
	{
		return items[((wrap) ? (idx + wantIdx) : wantIdx) % LEN];
		// note: doesn't need mod with !wrap (assuming a valid index), but it removes the need for a bounds check
	}

	void add(char[] s)
	{
		items[idx % LEN] = s;
		if (++idx == LEN)
			wrap = true;
	}
}

unittest
{
	History!3 tmp;
	tmp.add(cast(char[])"a");
	assert(tmp.at(0) == "a");
	// .
	tmp.add(cast(char[])"b");
	assert(tmp.at(0) == "a");
	assert(tmp.at(1) == "b");
	// .
	tmp.add(cast(char[])"c");
	assert(tmp.at(0) == "a");
	assert(tmp.at(1) == "b");
	assert(tmp.at(2) == "c");
	// .
	tmp.add(cast(char[])"d");
	assert(tmp.at(0) == "b");
	assert(tmp.at(1) == "c");
	assert(tmp.at(2) == "d");
	// .
	tmp.add(cast(char[])"e");
	assert(tmp.at(0) == "c");
	assert(tmp.at(1) == "d");
	assert(tmp.at(2) == "e");
	// .
	tmp.add(cast(char[])"f");
	assert(tmp.at(0) == "d");
	assert(tmp.at(1) == "e");
	assert(tmp.at(2) == "f");
	// .
	tmp.add(cast(char[])"g");
	assert(tmp.at(0) == "e");
	assert(tmp.at(1) == "f");
	assert(tmp.at(2) == "g");
}
