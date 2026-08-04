/**
 * globals used throughout the program
 * 
 * (thread-safe, only assigned at startup)
 */
module demoreader.globals;

__gshared
{
	bool g_useColor;
	bool g_printPlayerSteamIds; // print every user's steamid before their name
	bool g_printPlayerUserIds;  // print every user's userid before their name

	bool g_jsonFlag; // -json flag used (force writing json file)
	bool g_trace1;
	alias TRACE1 = g_trace1;

	bool g_forceLive;
	bool g_liveStat;
	bool g_noWait;

	bool g_playBrokenDemos;

	import demoreader.markfile;
	Mark*[string] g_marks;

	bool  g_sizeStatEnabled;
	real  g_sizeStatTotalDuration = 0;
	ulong g_sizeStatTotalSize;
}
