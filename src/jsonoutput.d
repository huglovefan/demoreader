/**
 * writes details collected about the demo to a .json file
 */
module demoreader.jsonoutput;

import core.stdc.stdlib;
import std.algorithm.sorting;
import std.array;
import std.json;
import std.math.rounding;
import std.stdio;

private
{
	alias nothing_t = void[0];
	enum nothing = nothing_t.init;
}

struct JsonOutput
{
static:
	private
	{
		bool              active;

		// .author
		string            ownSteamId;
		string            ownName;

		// .demo
		double            duration;
		bool              isIncomplete; /// demo file was never finalized (game crashed while recording)

		// .engine
		uint              buildNumber;  /// game build number
		uint              demoProtocol;
		uint              networkProtocol;

		// .server
		string            serverIp;        /// ip + port string
		bool              serverDedicated; /// dedicated vs. listen server
		string            serverName;      /// server name when recording started
		uint              serverNumber;    /// number of times a map has been loaded without restarting the server
		string            serverOs;        /// linux or windows

		// .game, i think
		string            mapName;      /// filename of map without extension

		// .?
		nothing_t[string] seenSteamIds; /// every steamid seen during the game

		bool              ev_badPitch;
	}

	bool isActive() { return active; }

	void resetAndSetActive(bool b)
	{
		active = b;

		// .author
		ownName = null;
		ownSteamId = null;

		// .demo
		duration = 0;
		isIncomplete = false;
		seenSteamIds = null;

		// .engine
		buildNumber = 0;
		demoProtocol = 0;
		networkProtocol = 0;

		// .server
		serverIp = null;
		serverDedicated = false;
		mapName = null;
		serverName = null;
		serverNumber = 0;
		serverOs = null;

		ev_badPitch = false;
	}

	// ---

	void save(string filename)
	{
		if (!active)
			return;

		/*
		 * subkeys:
		 * - author  about the player who recorded the demo
		 * - engine  about the engine the demo was recorded on
		 * - demo    about the recording itself
		 * - server  about the server hosting the game
		 * - game    about the game/match being played
		 * 
		 * should map go under server? there's nothing else to put under "game"
		 * 
		 * ^^ want server to be (maybe)
		 * stuff that would be the same for all games on the server
		 * and game, stuff that might/usually changes
		 * 
		 * server for "things about the server that don't automatically change"?
		 * keep server name there, move spawn count and map to game?
		 * 
		 * === other stuff to possibly record ===
		 * 
		 * more server stuff
		 * - max players
		 * - query port thing (from string table)
		 * - steam id thing (from setconvar?)
		 * - motd, map rotation (useless on valve servers)
		 * - fastdl url (community servers)
		 * 
		 * - game duration until the demo started (first server tick)
		 * ^^ or make it ".demo.starttime"?
		 * 
		 * "things detected" for user
		 * - using mastercomfig
		 * - using cfgfs
		 * 
		 * counts of interesting events in the demo
		 * - votekick
		 * - chat_message
		 * 
		 * - whether it's a complete game -- or: "seen game start", "seen game end"
		 * 
		 * info for each player
		 * - name(s)
		 * - assigned team (if mp_forceautoteam)
		 * - chat messages
		 * - classes played
		 * - kills/deaths/playtime as each class
		 * - did things that require a premium account (text chat, voice chat, voice commands)
		 * - time connected
		 * 
		 * - local player spawned at least once
		 * 
		 * idea: players[steamid]
		 * for each, have
		 * - detections
		 *   - bad_pitch_ticks: number
		 * - time_alive
		 */

		JSONValue json;

		json["author"] = null;
		json["author"]["name"] = ownName;
		json["author"]["steamid"] = ownSteamId;

		json["demo"] = null;
		json["demo"]["duration"] = duration;
		json["demo"]["incomplete"] = isIncomplete;
		json["demo"]["players"] = seenSteamIds.byKey.array.sort!((s1, s2)
		{
			uint id1 = atoi(&s1["[U:1:".length]);
			uint id2 = atoi(&s2["[U:1:".length]);
			return id1 < id2;
		}).array;

		json["engine"] = null;
		json["engine"]["build"] = buildNumber;
		json["engine"]["demoprotocol"] = demoProtocol;
		json["engine"]["networkprotocol"] = networkProtocol;

		string[] events;
		if (ev_badPitch)
			events ~= "bad_pitch";
		json["events"] = events;

		json["server"] = null;
		json["server"]["address"] = serverIp;
		json["server"]["dedicated"] = serverDedicated;
		json["server"]["map"] = mapName; // BUG: should be under .game
		json["server"]["name"] = serverName;
		json["server"]["os"] = serverOs;
		json["server"]["spawncount"] = serverNumber;

		json
			.toJSON(/* pretty */ true, JSONOptions.doNotEscapeSlashes)
			.toFile(filename);
	}

	// ---

	private void setStringTpl(char[] s, ref string prop)
	{
		if (active)
			prop = s.idup;
	}

	// ---

	void steamIdSeen(char[] steamid)
	{
		if (!active)
			return;
		if (steamid == "BOT")
			return;

		if (steamid in seenSteamIds)
			return;
		else
			seenSteamIds[steamid.idup] = nothing;
	}

	void setMapName(char[] s)       { setStringTpl(s, mapName); }
	void setServerName(char[] s)    { setStringTpl(s, serverName); }
	void setServerIp(char[] s)      { setStringTpl(s, serverIp); }
	void setBuildNumber(uint n)     { buildNumber = n; }
	void setDemoProtocol(uint n)    { demoProtocol = n; }
	void setNetworkProtocol(uint n) { networkProtocol = n; }
	void setServerNumber(uint n)    { serverNumber = n; }
	void setServerDedicated(bool v) { serverDedicated = v; }
	void setIncomplete()            { isIncomplete = true; }

	void setOwnName(char[] s)    { setStringTpl(s, ownName); }
	void setOwnSteamId(char[] s) { setStringTpl(s, ownSteamId); }

	void setDemoDuration(float f)
	{
		// do this rounding thing to get the closest double to what the float is supposed to be
		// before: 43.154998779296875
		// after: 43.1550000000000011
		duration = (f*1000.0L).round/1000.0L;
	}

	void setServerOs(char c)
	{
		if (!active)
			return;

		final switch (c)
		{
			case 'l':
				serverOs = "linux";
				break;
			case 'w':
				serverOs = "windows";
				break;
		}
	}

	void setEvBadPitch() { ev_badPitch = true; }
}
