/**
 * tracks player slots and players throughout the game
 */
module demoreader.player;

import core.stdc.stdio;
import core.stdc.stdlib;
import std.string;
import demoreader.dr : DemoReader;
import demoreader.globals : g_marks, g_printPlayerSteamIds, g_printPlayerUserIds, g_useColor;
import demoreader.jsonoutput;
import demoreader.stringtable;
import demoreader.ttycolor;
import demoreader.valve.demofiledump;

// cleanup todo: remove cases where it's passed as an argument now that this is a global
private Player.UserInfoSource stringTableUpdateSource(ref const(StringTables) stringTables)
{
	return stringTables.updateSource.toUserInfoSource;
}

struct Player
{
	const int      slotIndex;       /// 0-based slot number
	player_info_t* info;            /// player info struct from userinfo string table
	bool           hasSpawned;      /// we know this player has spawned
	bool           hasDisconnected; /// player has disconnected, slot free to reuse
	int            team;            /// team number (2 = RED, 3 = BLU, etc)
	bool           usedVoiceChat;

	int badPitchTick;
	int badPitchPrintCount;

	private
	{
		UserInfoSource userInfoSource; /// where .info came from
	}

	static
	{
		private Player*[] slots;

		/// all players seen throughout the game
		/// accountid -> Player
		private Player*[uint] seenPlayers;

		void reset()
		{
			foreach (sl; slots)
			{
				if (sl)
					sl.onRemoveEntry(RemoveReason.demoEnded, null);
			}
			slots = null;

			seenPlayers = null;
		}

		pragma(inline, true)
		static size_t maxPlayers()
		{
			return slots.length;
		}

		/// check all connected player slots for consistency
		void check()
		{
			foreach (self; slots)
			{
				if (!self || self.hasDisconnected)
					continue;

				foreach (other; slots)
				{
					if (!other || other.hasDisconnected || other == self)
						continue;

					checkNotSame(self, other);
				}
			}
		}

		/// check that it's ok to add this player (there are no pre-existing duplicates)
		void checkPlayerBeingAdded(Player* self)
		{
			debug assert(!self.hasDisconnected); // random sanity check

			foreach (other; slots)
			{
				if (!other || other.hasDisconnected)
					continue;

				debug assert(other != self); // shouldn't have been added to slots yet

				checkNotSame(self, other);
			}
		}

		private void checkNotSame(Player* self, Player* other)
		{
			// note: ignore guid check for bots (but the other properties should still be unique)
			if (
				self.info.userID == other.info.userID ||
				self.info.name   == other.info.name ||
				(self.info.guid  == other.info.guid && !self.isBot))
			{
				debug
				{
					printf("*** duplicate player\n");
					printf("-slot %u: <%u> %s %s\n", self.slotIndex,  self.info.userID,  self.info.guid.ptr,  self.ttyname);
					printf("-slot %u: <%u> %s %s\n", other.slotIndex, other.info.userID, other.info.guid.ptr, other.ttyname);
				}
				// 2022-10-10_06-47-32.dem
				// connection closing
				// new player comes in via connect message before there's any sign of them disconnecting!!!
				other.hasDisconnected = true;
			}
		}
	}

	this(int slotIndex_)
	{
		slotIndex = slotIndex_;
	}
	this(int slotIndex_, player_info_t* info_, UserInfoSource updateSource)
	{
		slotIndex = slotIndex_;
		setUserInfo(info_, updateSource);
	}

	/// true if this player is simulated by the server
	pragma(inline, true)
	bool isBot()
	{
		// note: there's also .fakeplayer, but it's not reliably set unlike guid
		// player_info_t.check() has an assert for this
		return info.guid[0] == 'B';
	}

	/// true if this is the player who's recording the demo
	bool isLocalPlayer()
	{
		debug import demoreader.dr : INVALID_PLAYER_SLOT;

		auto dr = DemoReader.get();

		// (redundant, ownPlayerSlot is given together with the slot count
		//  before any players are created)
		debug assert(dr.ownPlayerSlot != INVALID_PLAYER_SLOT);
		debug assert(dr.ownPlayerSlot < slots.length);

		if (slotIndex == dr.ownPlayerSlot)
		{
			// test: are these always the same?
			// i think a duplicate count could break it
			// if the header just has the value of "cvar.name" before joining?
			assert(nameEquals(dr.header.clientname.fromStringz)); // test

			return true;
		}
		else
		{
			return false;
		}
	}

	uint accountid()
	{
		if (!isBot)
		{
			// note: friendsID isn't always set
			// notenote: using the fallback is safe: player_info_t checks that
			//  they always have the same account id if both are present
			uint rv = info.friendsID;
			if (!rv)
				rv = atoi(&info.guid[+"[U:1:".length]);
			return rv;
		}
		else
		{
			return 0;
		}
	}

	/// something suggests that this player is on team `newteam`
	/// force: replace their old team instead of just checking that it's the same
	void impliedTeam(int newteam, bool force = false)
	{
		// valid and joinable teams only
		debug assert(newteam >= 1 && newteam <= 3);
		else  assert(newteam);

		if (team == newteam)
			return;

		if (!team || force)
		{
			// autobalance or manual team change
			//if (team && force)
			//	printf("-overriding team of %s: %d -> %d\n", ttyname, team, newteam);
			team = newteam;
		}
		else
		{
			debug printf("-team conflict: [%s] (%d) expected to be on team %d\n", ttyname, team, newteam);
			team = 0;
			assert(0, "team conflict");
		}
	}

	/// something suggests that these players are on the same team
	static void impliedSameTeam(Player* p1, Player* p2)
	{
		if (p1.team == p2.team) // already same (ethereal or physical team)
			return;

		// sort lower team to p2
		if (p1.team < p2.team)
		{
			Player* tmp = p1;
			p1 = p2;
			p2 = tmp;
		}

		if (p1.team && !p2.team) // one known, one unassigned
		{
			p2.team = p1.team;
		}
		else // players are on different teams
		{
			version(unittest) {} else
			debug printf("-team conflict: [%s] (%d) and [%s] (%d) expected to be on the same team\n",
				p1.ttyname, p1.team,
				p2.ttyname, p2.team);
			p1.team = 0;
			p2.team = 0;
			assert(0, "team conflict");
		}
	}
	unittest
	{
		Player pl1;
		Player pl2;
		bool thrown(int team1, int team2)
		{
			pl1.team = team1;
			pl2.team = team2;
			try
			{
				Player.impliedSameTeam(&pl1, &pl2);
				return false;
			}
			catch (Throwable)
				return true;
		}
		bool fixup(int newteam1, int newteam2)
		{
			return pl1.team == newteam1 && pl2.team == newteam2;
		}
		assert(!thrown(0, 0)); assert(fixup(0, 0));
		assert(!thrown(0, 1)); assert(fixup(1, 1));
		assert(!thrown(0, 2)); assert(fixup(2, 2));
		assert(!thrown(0, 3)); assert(fixup(3, 3));
		assert(!thrown(1, 0)); assert(fixup(1, 1));
		assert(!thrown(1, 1)); assert(fixup(1, 1));
		assert( thrown(1, 2));
		assert( thrown(1, 3));
		assert(!thrown(2, 0)); assert(fixup(2, 2));
		assert( thrown(2, 1));
		assert(!thrown(2, 2)); assert(fixup(2, 2));
		assert( thrown(2, 3));
		assert(!thrown(3, 0)); assert(fixup(3, 3));
		assert( thrown(3, 1));
		assert( thrown(3, 2));
		assert(!thrown(3, 3)); assert(fixup(3, 3));
	}

	/// something suggests that these players are on opposite teams
	static void impliedOppositeTeams(Player* p1, Player* p2)
	{
		// sort lower team to p2
		if (p1.team < p2.team)
		{
			Player* tmp = p1;
			p1 = p2;
			p2 = tmp;
		}

		if (p1.team) // not both unassigned
		{
			if (p1.team > 1 && p2.team == 0) // one physical, one unassigned
			{
				p2.team = p1.team ^ 1; // swap 2 and 3
			}
			else if (p1.team == p2.team || p2.team <= 1)
			// 1. same team
			// 2. one ethereal, one spectator
			{
				version(unittest) {} else
				debug printf("-team conflict: [%s] (%d) and [%s] (%d) expected to be on opposite teams\n",
					p1.ttyname, p1.team,
					p2.ttyname, p2.team);
				p1.team = 0;
				p2.team = 0;
				assert(0, "team conflict");
			}
			else version(unittest) // already were on opposite teams
			{
				debug assert(p1.team == 2 || p1.team == 3);
				debug assert(p2.team == 2 || p2.team == 3);
				debug assert(p1.team != p2.team);
			}
		}
		else version(unittest) // both unassigned, assume we don't know their teams
		{
			debug assert(p1.team == 0);
			debug assert(p2.team == 0);
		}
	}
	unittest
	{
		Player pl1;
		Player pl2;
		bool thrown(int team1, int team2)
		{
			pl1.team = team1;
			pl2.team = team2;
			try
			{
				Player.impliedOppositeTeams(&pl1, &pl2);
				return false;
			}
			catch (Throwable)
				return true;
		}
		bool fixup(int newteam1, int newteam2)
		{
			return pl1.team == newteam1 && pl2.team == newteam2;
		}
		assert(!thrown(0, 0)); assert(fixup(0, 0));
		assert( thrown(0, 1));
		assert(!thrown(0, 2)); assert(fixup(3, 2));
		assert(!thrown(0, 3)); assert(fixup(2, 3));
		assert( thrown(1, 0));
		assert( thrown(1, 1));
		assert( thrown(1, 2));
		assert( thrown(1, 3));
		assert(!thrown(2, 0)); assert(fixup(2, 3));
		assert( thrown(2, 1));
		assert( thrown(2, 2));
		assert(!thrown(2, 3)); assert(fixup(2, 3));
		assert(!thrown(3, 0)); assert(fixup(3, 2));
		assert( thrown(3, 1));
		assert(!thrown(3, 2)); assert(fixup(3, 2));
		assert( thrown(3, 3));
	}

	/// colored and decorated name for printing
	const(char)* ttyname()
	{
		TempRotator!(char[128], 5) tr;
		auto ap = ASb(0, tr.get());

		string markname;
		string markcolor;
		if (auto mark = info.guid.fromStringz in g_marks)
		{
			markname = (*mark).name;
			markcolor = (*mark).color;
		}

		if (markname)
		{
			ap ~= "<BOT:";
			ap ~= markname;
			ap ~= "> ";
		}

		if (g_printPlayerSteamIds)
		{
			ap ~= info.guid.fromStringz;
			ap ~= ' ';
		}

		if (g_printPlayerUserIds)
		{
			ap ~= '<';
			char[32] buf = void;
			snprintf(buf.ptr, 32, "%d", info.userID);
			ap ~= buf.fromStringz;
			ap ~= "> ";
		}

		// start name color
		if (g_useColor)
		{
			ap ~= "\x1b[";
			ap ~= getteamcolor(team);
			if (markcolor)
			{
				ap ~= ';';
				ap ~= markcolor;
			}
			ap ~= 'm';
		}

		// name!
		ap ~= info.name.fromStringz;

		// end name color
		if (g_useColor)
			ap ~= "\x1b[0m";

		ap ~= '\0';

		return cast(char*)ap[].ptr;
	}

	/**
	 * called to set the player_info_t struct when it is created or updated
	 * 
	 * note: prefer to put asserts in player_info_t for ones that are possible
	 *  to check on that level (don't need any extra context from the player struct)
	 */
	enum UserInfoSource
	{
		svcCreateStringTable,               /// svc_createstringtable (early 1)
		demStringTables,                    /// dem_stringtables (early 2)
		svcUpdateStringTable,               /// svc_updatestringtable
		manuallyCreatedForConnectingPlayer, /// manually created
		none = -1,
	}
	void setUserInfo(player_info_t* newinfo, UserInfoSource source)
	{
		assert(newinfo);

		player_info_t* oldinfo = info;

		info           = newinfo;
		userInfoSource = source;

		// player just set their friendsName?
		if (newinfo.friendsName[0] && (!oldinfo || !oldinfo.friendsName[0]))
		{
			printf("-player has non-empty friendsName: %s %s\n", info.guid.ptr, ttyname);
		}

		// did not exist before (newly created)
		if (!oldinfo)
		{
			// is this the local player? JsonOutput wants to know their name
			if (JsonOutput.isActive && isLocalPlayer)
			{
				JsonOutput.setOwnName(info.name.fromStringz);
				JsonOutput.setOwnSteamId(info.guid.fromStringz);
			}
		}

		// existed before
		if (oldinfo)
		{
			// changed name?
			if (newinfo.name != oldinfo.name)
			{
				printf("-player changed name: %s -> %s\n", oldinfo.name.ptr, ttyname);

				// re-check: connected names are unique
				foreach (sl; slots)
				{
					if (sl && sl != &this && !sl.hasDisconnected)
						assert(sl.info.name != this.info.name);
				}
			}

			// changed custom files?
			// only happens during connect
			if (newinfo.customFiles != oldinfo.customFiles)
			{
				assert(!hasDisconnected); // can't change after disconnect

				bool lateChangeFalsePositive = (
					accountid == 231928243 && DemoReader.get().fileName == "2022-08-17_03-27-22.dem" ||
					accountid == 182322040 && DemoReader.get().fileName == "2022-10-10_06-47-32.dem" ||
					accountid == 835848658 && DemoReader.get().fileName == "2022-10-10_06-47-32.dem" ||
					accountid == 924280394 && DemoReader.get().fileName == "2022-10-10_06-47-32.dem" ||
					accountid == 965708965 && DemoReader.get().fileName == "2022-10-23_02-59-55.dem" ||
					accountid == 381822622 && DemoReader.get().fileName == "2022-10-23_03-55-49_2.dem" ||
					false);

				if (!lateChangeFalsePositive)
				{
					debug if (hasSpawned)
						printf("accountid=%u\n", accountid);
					assert(!hasSpawned); // can't change after spawning
				}

				// can change to different ones while connecting
				//assert(oldinfo.customFiles == [0, 0, 0, 0]);
			}
		}
	}

	/**
	 * called when we're sure the player has spawned, i.e. when they do
	 *  something that you can only do while spawned
	 * 
	 * (this is a crude way to detect when they're fully connected)
	 */
	void onSpawnedActivity()
	{
		if (hasDisconnected)
			assert(0); // shouldn't happen
		if (hasSpawned)
			return;

		hasSpawned = true;

		//printf("-player marked as spawned: %s\n", ttyname);

		/*
		 * check empty customFiles
		 * 
		 * catbots using "nullgraphics" have 0 instead of the default value for
		 *  the sound spray here because they block the game from reading sound files
		 * 
		 * source: https://github.com/nullworks/cathook/blob/master/src/hooks/nographics.cpp#L80
		 */
		if (info.customFiles == [0, 0, 0, 0] && !isBot)
		{
			switch (accountid)
			{
				// legitimate players with unset sound spray
				case 425473385:  // IncogFM
				case 1111200260: // loser36979
					break;

				default:
				{
					// false positive !!!FIXME!!!
					if (
						(accountid % 10000) == 8243 &&
						DemoReader.get().fileName == "2022-08-17_03-27-22.dem")
					{
						break;
					}

					printf("-player has empty customFiles: %s %s\n", info.guid.ptr, ttyname);
				}
			}
		}
	}

	/**
	 * called when the player shall be considered no longer connected
	 * 
	 * note: may be called multiple times for the different events
	 */
	enum DisconnectReason
	{
		userInfoRemoved,   /// entry removed from userinfo string table
		disconnectMessage, /// "<name> disconnected"

		/// "<name> joined the game" for the same player and slot index (means they're reconnecting)
		/// - the player will be destroyed and recreated after this
		/// - might get a `disconnectMessage` after this, or not
		reconnectMessage,

		ghostPlayer,
	}
	void setDisconnected(DisconnectReason reason)
	{
		hasDisconnected = true;
	}

	/**
	 * mark a disconnected player as not disconnected
	 * 
	 * this is used when we get a userinfo update for a "disconnected" player
	 * 
	 * some freak events can cause a connecting player to be marked as
	 *  disconnected too early (ctrl+f "funny sequence" in main.d)
	 * 
	 * when a userinfo is updated, we know it's safe to assume they haven't
	 *  disconnected yet - at least until they're removed from the string table
	 *  (which will cause them to be marked as disconnected again)
	 */
	private void assureNotDisconnectedDueToUserInfoUpdate()
	{
		//if (hasDisconnected)
		//	printf("-fixed \"funny sequence\" victim: %s\n", ttyname);

		debug assert(!hasSpawned); // random sanity check. shouldn't have been set, but would want this to be false too

		hasDisconnected = false;
	}

	/**
	 * called when the player is removed from the slots array (slot reused or demo ended)
	 * 
	 * this is something like a destructor for the Player struct
	 * 
	 * NOTE: this might come way after they've disconnected, e.g. when the player slot is reused
	 */
	enum RemoveReason
	{
		demoEnded,                 /// end of demo
		slotReusedSamePlayer,      /// same player reconnecting
		slotReusedDifferentPlayer, /// different player took the slot
	}
	void onRemoveEntry(RemoveReason reason, Player* replacedBy)
	{
		bool isOfficialServer = DemoReader.get().isOfficialServer;

		if (reason != RemoveReason.demoEnded)
			assert(hasDisconnected);
	}

	/**
	 * called by stringtable.d after
	 * 1. this player's userinfo was removed (slot became vacant)
	 * 2. this player's userinfo was replaced by a different player's
	 */
	void onStringTableEntryReplacedOrRemoved(Player* replacedBy, ref const(StringTables) stringTables)
	{
		// sanity
		assert(hasDisconnected);
		assert(replacedBy != &this);
		assert(!replacedBy || !replacedBy.hasDisconnected);

		/*
		 * detect players that are present in svc_createstringtable but
		 *  immediately removed in dem_stringtables (never to be seen after)
		 */
		if (
			userInfoSource == UserInfoSource.svcCreateStringTable &&
			stringTableUpdateSource(stringTables) == UserInfoSource.demStringTables)
		{
			if (replacedBy)
				printf("-ghost player: %s (replaced by %s)\n", ttyname, replacedBy.ttyname);
			else
				printf("-ghost player: %s (disappeared)\n", ttyname);

			// skip the disconnect message assert
			setDisconnected(DisconnectReason.ghostPlayer);
		}
		// theory: early string table is
		// - from when we joined the server?
		// - from a previous game?
		// - some stale stuff sent by the server?
		// le spooky... some of the players don't even appear in any other demos
		// a few mid-game demos have the same ghost players, so i'm thinking it's some stale data (but not sure what or from where/when)
	}

	/**
	 * called after creating the player struct, if we had one for that player before
	 */
	private void recreatedForSamePlayer(Player* oldPlayer)
	{
		bool isMatchMakingGame = DemoReader.get().isMatchMakingGame;

		assert(oldPlayer.accountid == this.accountid);
		assert(!isBot);

		// different name (usually just bots with different duplicate counts)
		if (!nameEquals(oldPlayer.info.name.fromStringz))
			printf("-player reconnecting with a different name: %s -> %s\n", oldPlayer.ttyname, ttyname);
	}

	/**
	 * proper name comparison
	 * 
	 * this avoids the hazard of accidentally ignoring the null byte
	 * e.g. `info.name[0..name.length] == name` would only check that it starts with that string
	 */
	bool nameEquals(const(char)[] name)
	{
		debug assert(name.length+1 <= info.name.length); // fits in buffer
		debug assert(name.ptr[name.length] == 0); // null-terminated

		return info.name.ptr[0..name.length+1] == name.ptr[0..name.length+1];
	}

	bool steamIdEquals(const(char)[] steamid)
	{
		debug assert(steamid.length+1 <= info.guid.length); // fits in buffer
		debug assert(steamid.ptr[steamid.length] == 0); // null-terminated

		return info.guid.ptr[0..steamid.length+1] == steamid.ptr[0..steamid.length+1];
	}

static:
	void createSlots(int maxplayers)
	{
		debug assert(!slots);
		slots = new Player*[maxplayers];
	}

	/**
	 * called when userinfo for this player has been created (different userID
	 *  from the previous one)
	 */
	Player* createForNewUserInfo(int slotIndex, player_info_t* info, UserInfoSource updateSource, ref const(StringTables) stringTables)
	{
		// get old player
		Player* old = slots[slotIndex];

		// already created by createForConnectingUser()?
		if (old && old.info.userID == info.userID)
		{
			assert(old.userInfoSource == UserInfoSource.manuallyCreatedForConnectingPlayer);

			// "funny sequence" fix (see function comment)
			old.assureNotDisconnectedDueToUserInfoUpdate();

			if (*info != *old.info)
			{
				old.setUserInfo(info, updateSource);
			}

			return old;
		}

		// checks
		if (old)
			assert(old.hasDisconnected); // should've been set

		Player* pl = new Player(slotIndex, info, updateSource);

		// tell old player they're being removed
		if (old)
		{
			if (old.steamIdEquals(info.guid.fromStringz))
				old.onRemoveEntry(RemoveReason.slotReusedSamePlayer, pl);
			else
				old.onRemoveEntry(RemoveReason.slotReusedDifferentPlayer, pl);
		}

		/*
		 * FIX 2022-08-03_10-31-46_4.dem (and others)
		 * 
		 * an early player changes slots, which causes them to appear twice for a moment
		 * 
		 * fix by finding the old player and marking it as disconnected
		 * 
		 * StringTable will do a consistency check after this so there won't be a duplicate remaining
		 * 
		 * current year comment: wouldn't a better fix be to mark all players in
		 *  the early string table as disconnected, then have it mark the new ones as connected again?
		 */
		if (stringTableUpdateSource(stringTables) == UserInfoSource.demStringTables)
		{
			foreach (sl; slots)
			{
				if (
					!sl ||
					sl.hasDisconnected ||
					sl.userInfoSource != UserInfoSource.svcCreateStringTable ||
					sl.isBot ||
					sl.info.guid != info.guid)
				{
					continue;
				}

				printf("-early player moved slots: %s (%u -> %u)\n", sl.ttyname, sl.slotIndex, pl.slotIndex);
				sl.setDisconnected(DisconnectReason.userInfoRemoved);
				break;
			}
		}

		Player.checkPlayerBeingAdded(pl);

		slots[slotIndex] = pl;
		recordSeenPlayer(pl);

		return pl;
	}

	/**
	 * create the Player for a connecting user
	 * 
	 * called by the player_connect_client GameEvent (it often comes before the
	 *  userinfo update)
	 */
	void createForConnectingUser(char[] name, uint index, int userid, char[] networkid)
	{
		player_info_t* info = new player_info_t;
		info.name[0..name.length] = name;
		info.name[   name.length] = 0;
		info.userID = userid;
		info.guid[0..networkid.length] = networkid;
		info.guid[   networkid.length] = 0;

		Player* pl = new Player(index, info, UserInfoSource.manuallyCreatedForConnectingPlayer);

		// remove slot's old player
		if (Player* old = slots[index])
		{
			assert(old.info.userID != userid); // shouldn't be the one being created

			assert(old.hasDisconnected); // should've been set

			if (old.steamIdEquals(networkid))
				old.onRemoveEntry(RemoveReason.slotReusedSamePlayer, pl);
			else
				old.onRemoveEntry(RemoveReason.slotReusedDifferentPlayer, pl);
		}

		Player.checkPlayerBeingAdded(pl);

		slots[index] = pl;
		recordSeenPlayer(pl);
	}

	/**
	 * called after creating a player
	 */
	private static void recordSeenPlayer(Player* pl)
	{
		assert(slots[pl.slotIndex] == pl); // properly created

		if (pl.isBot)
			return;

		/*
		 * call .recreatedForSamePlayer() if we had a player struct for this player before
		 */
		if (Player** oldp = pl.accountid in seenPlayers)
		{
			auto old = *oldp;

			assert(old != pl);                         // ?
			assert(old.info.userID != pl.info.userID); // can't happen
			assert(old.hasDisconnected);               // long dead corpse

			pl.recreatedForSamePlayer(old);
		}

		/*
		 * now record the new one in seenPlayers
		 */
		seenPlayers[pl.accountid] = pl;

		/*
		 * give JsonOutput their steamid
		 */
		JsonOutput.steamIdSeen(pl.info.guid.fromStringz);
	}

	Player* getBySlotIndex(int slotIndex, bool force = false)
	{
		assert(slots);
		Player* pl = slots[slotIndex];
		return (pl && (!pl.hasDisconnected || force)) ? pl : null;
	}

	Player* getByEntIndex(int entindex, bool force = false)
	{
		if (entindex >= 1 && entindex <= slots.length)
		{
			Player* pl = slots[entindex-1];
			return (pl && (!pl.hasDisconnected || force)) ? pl : null;
		}
		else
		{
			debug printf("-bad entindex %d\n", entindex);
			//assert(0);
			return null;
		}
	}

	Player* getByUserId(int userid, bool force = false)
	{
		assert(slots);
		foreach (sl; slots)
		{
			if (sl && (!sl.hasDisconnected || force) && sl.info.userID == userid)
				return sl;
		}
		return null;
	}

	Player* getByName(const(char)[] name, bool force = false)
	{
		assert(slots);
		if (!force)
		{
			foreach (sl; slots)
			{
				if (sl && !sl.hasDisconnected && sl.nameEquals(name))
					return sl;
			}
			return null;
		}
		else
		{
			/*
			 * consider also disconnected players, but prefer connected ones
			 */
			{
				Player*[2] foundPlayer;
				uint[2]    foundCount;
				foreach (sl; slots)
				{
					if (sl && sl.nameEquals(name))
					{
						uint type = !!sl.hasDisconnected;
						if (!foundPlayer[type] || sl.info.userID > foundPlayer[type].info.userID)
						{
							foundPlayer[type] = sl;
						}
						foundCount[type]++;
					}
				}
				if (foundCount[0])
				{
					debug assert(foundCount[0] <= 1); // connected names are unique, checked when adding players
					return foundPlayer[0];
				}
				if (foundCount[1])
				{
					// FIXED: now returns the higher userid
					// but is it guaranteed to be more recent?
					// should store and compare ticks instead?
					debug
					{
						if (foundCount[1] > 1)
						{
							printf("-note: more than one disconnected player matches '%s', returning higher userid\n", name.ptr);
						}
					}
					//assert(foundCount[1] <= 1, "found more than one matching player");
					return foundPlayer[1];
				}
			}

			/*
			 * search historical players in case their player slot was already recycled
			 */
			{
				Player* found;
				int     count;
				foreach (pl; seenPlayers)
				{
					if (pl.hasDisconnected && pl.nameEquals(name))
					{
						found = pl;
						count++;
					}
				}
				if (count)
				{
					assert(count <= 1, "found more than one matching player");
					return found;
				}
			}

			/*
			 * not found!!1
			 */
			return null;
		}
	}

	Player* getBySteamId(const(char)[] steamid)
	{
		assert(slots);
		foreach (sl; slots)
		{
			if (sl && !sl.hasDisconnected && sl.steamIdEquals(steamid))
				return sl;
		}
		return null;
	}
}

private:

struct ASb
{
	size_t length;
	char[] data;

	void opOpAssign(string op)(const(char)[] s) if (op == "~")
	{
		data[length..length+s.length] = s;
		length += s.length;
	}
	void opOpAssign(string op)(char c) if (op == "~")
	{
		data[length++] = c;
	}
	char[] opSlice()
	{
		return data[0..length];
	}
}

struct TempRotator(T, size_t count)
{
	static T[count] values = void;
	static size_t   i;
	ref T get() @property
	{
		T* p = &values[i];
		i = (i + 1) % count;
		return *p;
	}
}
