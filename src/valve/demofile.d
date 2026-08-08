module demoreader.valve.demofile;

import core.stdc.stdio;

// -----------------------------------------------------------------------------

/*
 * demofile.h
 * https://github.com/ValveSoftware/csgo-demoinfo/blob/571604c/demoinfogo/demofile.h
 */

enum DEMO_HEADER_ID = "HL2DEMO\0";
enum DEMO_PROTOCOL  = 3;
enum PROTOCOL_VERSION = 24;

enum MAX_OSPATH = 260;

enum
{
	dem_signon = 1,
	dem_packet,
	dem_synctick,
	dem_consolecmd,
	dem_usercmd,
	dem_datatables,
	dem_stop,
	dem_stringtables,
}

string demoMessageName(uint msg)
{
	final switch (msg)
	{
		case dem_signon:       return "dem_signon";
		case dem_packet:       return "dem_packet";
		case dem_synctick:     return "dem_synctick";
		case dem_consolecmd:   return "dem_consolecmd";
		case dem_usercmd:      return "dem_usercmd";
		case dem_datatables:   return "dem_datatables";
		case dem_stop:         return "dem_stop";
		case dem_stringtables: return "dem_stringtables";
	}
}

struct demoheader_t
{
	char[8]          demofilestamp = 0; /// Should be HL2DEMO
	int              demoprotocol;      /// Should be DEMO_PROTOCOL
	int              networkprotocol;   /// Should be PROTOCOL_VERSION
	char[MAX_OSPATH] servername = 0;    /// Name of server
	char[MAX_OSPATH] clientname = 0;    /// Name of client who recorded the game
	char[MAX_OSPATH] mapname = 0;       /// Name of map
	char[MAX_OSPATH] gamedirectory = 0; /// Name of game directory (com_gamedir)
	float            playback_time = 0; /// Time of track
	int              playback_ticks;    /// # of ticks in track
	int              playback_frames;   /// # of frames in track
	int              signonlength;      /// length of signondata in bytes

	/// demo file still being written by the game?
	bool isLive()
	{
		return playback_time is 0.0f && !playback_ticks && !playback_frames;
	}
	static assert(demoheader_t.init.isLive);

	void check()
	{
		assert(demofilestamp == DEMO_HEADER_ID);
		assert(demoprotocol == DEMO_PROTOCOL);

		assert(
			networkprotocol == 21 || // benchmark1.dem (it plays fine)
			networkprotocol == PROTOCOL_VERSION);

		assert(playback_time is playback_ticks*0.015f); // this is how it's calculated, i think
	}

	void print()
	{
		printf("demofilestamp     %s\n", demofilestamp.ptr);
		printf("demoprotocol      %d\n", demoprotocol);
		printf("networkprotocol   %d\n", networkprotocol);
		printf("servername        %s\n", servername.ptr);
		printf("clientname        %s\n", clientname.ptr);
		printf("mapname           %s\n", mapname.ptr);
		printf("gamedirectory     %s\n", gamedirectory.ptr);
		printf("playback_time     %f\n", playback_time);
		printf("playback_ticks    %d\n", playback_ticks);
		printf("playback_frames   %d\n", playback_frames);
		printf("signonlength      %d\n", signonlength);
	}
}

enum FDEMO_NORMAL      = 0;
enum FDEMO_USE_ORIGIN2 = 1 << 0;
enum FDEMO_USE_ANGLES2 = 1 << 1;
enum FDEMO_NOINTERP    = 1 << 2; /// don't interpolate between this and last view

enum MAX_SPLITSCREEN_CLIENTS = 1;

struct Vector
{
	float x = 0;
	float y = 0;
	float z = 0;

	void Init()
	{
		this.tupleof = this.init.tupleof;
	}

	void Init(float x, float y, float z)
	{
		this.tupleof = __traits(parameters);
	}

	pragma(inline, true)
	ref float opIndex(size_t i) return
	{
		return (i == 0) ? x : (i == 1) ? y : (i == 2) ? z : *cast(float*)null;
	}
}

struct QAngle
{
	float x = 0;
	float y = 0;
	float z = 0;

	void Init()
	{
		this.tupleof = this.init.tupleof;
	}

	void Init(float x, float y, float z)
	{
		this.tupleof = __traits(parameters);
	}

	pragma(inline, true)
	ref float opIndex(size_t i) return
	{
		return (i == 0) ? x : (i == 1) ? y : (i == 2) ? z : *cast(float*)null;
	}
}

struct democmdinfo_t
{
	static struct Split_t
	{
		int    flags = FDEMO_NORMAL;

		// original origin/viewangles
		Vector viewOrigin;
		QAngle viewAngles;
		QAngle localViewAngles;

		// Resampled origin/viewangles
		Vector viewOrigin2;
		QAngle viewAngles2;
		QAngle localViewAngles2;

		void Reset()
		{
			flags = FDEMO_NORMAL;
			viewOrigin2 = viewOrigin;
			viewAngles2 = viewAngles;
			localViewAngles2 = localViewAngles;
		}

		ref const(Vector) GetViewOrigin() return
		{
			if (flags & FDEMO_USE_ORIGIN2)
			{
				return viewOrigin2;
			}
			return viewOrigin;
		}

		ref const(QAngle) GetViewAngles() return
		{
			if (flags & FDEMO_USE_ANGLES2)
			{
				return viewAngles2;
			}
			return viewAngles;
		}

		ref const(QAngle) GetLocalViewAngles() return
		{
			if (flags & FDEMO_USE_ANGLES2)
			{
				return localViewAngles2;
			}
			return localViewAngles;
		}
	}

	Split_t[MAX_SPLITSCREEN_CLIENTS] u;

	void Reset()
	{
		foreach (ref split; u)
			split.Reset();
	}
}
