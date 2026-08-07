module demoreader.main;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.sys.posix.signal;
import core.sys.posix.unistd;
import core.time;
import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.process;
import std.string;
import std.stdio : File;
import demoreader.dr;
import demoreader.util.filewatch;
import demoreader.util.glob;
import demoreader.jsonoutput;
import demoreader.markfile;
import demoreader.globals;

// ex: --DRT-gcopt=profile:1
extern(C) __gshared bool rt_cmdline_enabled = true;

extern(C) __gshared string[] rt_options = [
	"gcopt=cleanup:none",
	//"gcopt=gc:precise",
	//"gcopt=profile:1",

	//"gcopt=initReserve:64",
	//"gcopt=minPoolSize:8",
	//"gcopt=maxPoolSize:128",
	//"gcopt=incPoolSize:8",
	"gcopt=heapSizeFactor:12",
];

// defaults:
// initReserve:N  - initial memory to reserve in MB (0B)
// minPoolSize:N  - initial and minimum pool size in MB (1M)
// maxPoolSize:N  - maximum pool size in MB (64M)
// incPoolSize:N  - pool size increment MB (3M)
// heapSizeFactor:N - targeted heap size to used memory ratio (2)

// comment:
// increasing heapSizeFactor seems to help, doesn't increase memory use as much as you'd expect
// others don't make a big enough difference to tell if they're good or not

version(Windows)
{
	int isatty(int) { return 1; }
}

struct DrMain
{
	bool keepgoing;
	bool listonly;
	bool verbose;
	bool pagerWrap;
	char rangetype = 0;
	int  rangenum;
	bool rangerest;
	string[] files;
	string[] searchDirs;

	ErrorInfo[] errordemos;
	bool lastDemoWasLive; /// true if the last demo in the loop was still being written
	uint demosReadCnt;    /// demos seen by the loop
	bool fatalError;      /// got an exception while reading
}

struct ErrorInfo
{
	string filename;
	string errfile;
	size_t errline;
	string errmsg;
}

void parseCommandLine(ref DrMain drm, ref string[] args)
{
	const origArgs = args;

	while (args.length > 1)
	{
		switch (args[1])
		{
			case "-color":
				g_useColor = true;
				break;
			version(Posix)
			case "-debug":
			{
				debug enum isDebug = true;
				else  enum isDebug = false;

				// stealthily recompile debug version
				if (!isDebug)
				{
					string exe = thisExePath;
					if (int rv = spawnProcess(["make", "-B", "-s", "debug=1"], null, Config.retainStdout|Config.retainStderr, thisExePath.dirName).wait())
						exit(rv);
					execvp(exe, origArgs);
					assert(0, "exec failed");
				}
				else
				{
					break;
				}
			}
			version(Posix)
			case "-pager":
			{
				import std.stdio : stdin, stdout, stderr; // need the D ones

				// ignore duplicate -pager
				if ("_DEMOREADER_IN_PAGER" in environment)
					break;

				// ignore if output is redirected
				if (!isatty(1))
					break;

				size_t argidx = (origArgs.length-args.length)+1;
				auto newargs = origArgs[0..argidx] ~ origArgs[argidx+1..$];

				// peep the remaining args for -wrap since we need it here
				// this way we get it regardless of order
				if (!drm.pagerWrap)
					foreach (arg; args[1..$])
						switch (arg)
						{
						case "-wrap":
							drm.pagerWrap = true;
							break;
						default:
							break;
						}

				string pagerCmd = environment.get("DEMOREADER_PAGER", drm.pagerWrap ? "less -R" : "less -RS");

				Pid dr, less;
				try
				{
					Pipe output = pipe();
					scope(exit)
						output.close();

					signal(SIGINT, SIG_IGN); // ignore: allow ^C to interrupt scrolling in less
					dr = spawnProcess(newargs, stdin, output.writeEnd, output.writeEnd, ["_DEMOREADER_IN_PAGER": "1"]);

					signal(SIGINT, SIG_DFL); // default
					less = spawnShell(pagerCmd, output.readEnd, stdout, stderr);
				}
				catch (Exception e)
				{
					import core.stdc.stdio : stderr; // C one again
					fprintf(stderr, "demoreader: failed to start pager: %.*s\n", cast(int)e.msg.length, e.msg.ptr);
					exit(1);
				}

				signal(SIGINT, SIG_IGN); // ignore: let the children handle it
				int rv = dr.wait();
				if (less.wait())
				{
					if (!rv)
						rv = 1;
				}

				exit(rv);
			}
			case "-json":
				g_jsonFlag = true;
				break;
			case "-keepgoing":
				drm.keepgoing = true;
				break;
			case "-l":
				drm.listonly = true;
				break;
			case "-live":
				g_forceLive = true;
				break;
			case "-livestat":
				g_liveStat = true;
				break;
			case "-nowait":
				g_noWait = true;
				break;
			case "-sizestat":
				g_sizeStatEnabled = true;
				break;
			case "-steamids":
				g_printPlayerSteamIds = true;
				break;
			case "-trace":
				g_trace1 = true;
				break;
			case "-userids":
				g_printPlayerUserIds = true;
				break;
			case "-v":
				drm.verbose = true;
				break;
			case "-wrap":
				drm.pagerWrap = true;
				break;
			default:
			{
				// looks like an option?
				if (args[1].length && (args[1][0] == '-' || args[1][0] == '+'))
				{
					// range thing?
					if (args[1].length >= 2 && args[1][1] >= '0' && args[1][1] <= '9')
					{
						drm.rangetype = args[1][0];

						if (args[1][$-1] == '-')
							drm.rangerest = true;

						drm.rangenum = atoi((args[1][1..$]~'\0').ptr);
						if (!drm.rangenum)
						{
							fprintf(stderr, "error: range thing is 1-based, 0 has no meaning\n");
							exit(1);
						}

						break;
					}

					// unknown option
					printf("error: unknown option '%.*s'\n", cast(int)args[1].length, args[1].ptr);
					exit(1);
				}
				else
				{
					// doesn't look like an option, so it's a file
					drm.files ~= args[1];
				}
			}
		}
		args = args[1..$];
	}
}

void readSearchDirsConfig(ref DrMain drm)
{
	if ((thisExePath.dirName~"/searchDirs.txt").exists)
	{
		foreach (line; File(thisExePath.dirName~"/searchDirs.txt").byLineCopy)
		{
			line = line.strip;
			if (!line.length || line.startsWith('#'))
				continue;
			if (line.exists)
				drm.searchDirs ~= line;
			else
				fprintf(stderr, "note: search directory does not exist: %.*s\n", cast(int)line.length, line.ptr);
		}
	}
}

void interpretFileArgs(ref DrMain drm)
{
	string[] newFiles;
	ubyte[string] seenFileNames;

	void addFile(string path)
	{
		// deduplicate based on filename
		if (!seenFileNames[path.baseName]++)
			newFiles ~= path;
	}

	size_t addDirContents(string path)
	{
		string[] demoFiles = path.dirEntries("*.dem", SpanMode.shallow).map!"a.name".array;
		demoFiles.each!addFile;
		return demoFiles.length;
	}

	size_t addFileOrDir(string path)
	{
		if (path.isDir)
		{
			return addDirContents(path);
		}
		else
		{
			addFile(path);
			return 1;
		}
	}

	foreach (file; drm.files)
	{
		/*
		 * path given directly
		 */
		if (file.exists)
		{
			if (!addFileOrDir(file))
				printf("demoreader: no demo files found in '%s'\n", file.toStringz);

			continue;
		}

		/*
		 * either a bare filename or a glob pattern
		 * 
		 * test it as a glob pattern in all search directories, then add all
		 *  files that match it
		 * 
		 * if this matches any directories, then files inside them that
		 *  match "*.dem" are added
		 * 
		 * it's easy to match other filetypes using this so the results are
		 *  filtered to just *.dem
		 */
		size_t addedCount;
		foreach (sd; drm.searchDirs)
		{
			// try the given pattern as-is
			if (string[] ms = sd.dirGlob(file))
			{
				foreach (match; ms)
				{
					if (match.extension == ".dem" || match.isDir)
						addedCount += addFileOrDir(match);
				}
				continue;
			}
			// try the given pattern with ".dem" added
			// this should match only files, so it doesn't check for directories
			if (string[] ms = sd.dirGlob(file~".dem"))
			{
				foreach (match; ms)
					addedCount += addFileOrDir(match);
				continue;
			}
		}

		// file doesn't exist / glob didn't match anything?
		if (!addedCount)
		{
			printf("error: demo file not found: '%.*s'\n", cast(int)file.length, file.ptr);
			exit(1);
		}
	}

	drm.files = newFiles;
}

void loadAllDemos(ref DrMain drm)
{
	// no files, just load all demos we have

	ubyte[string] seenFileNames;

	void addFile(string path)
	{
		// deduplicate based on filename
		if (!seenFileNames[path.baseName]++)
			drm.files ~= path;
	}

	if (!drm.searchDirs.length)
	{
		fprintf(stderr, "demoreader: no file given, no search directories configured\n");
		exit(1);
	}

	bool foundAny;
	foreach (dir; drm.searchDirs)
	{
		foreach (s; dir.dirEntries("*.dem", SpanMode.shallow))
		{
			foundAny = true;
			addFile(s);
		}
	}
	if (!foundAny)
	{
		fprintf(stderr, "demoreader: no demos were found in the search directories\n");
		exit(1);
	}
}

void runFileLoop(ref DrMain drm)
{
fileloop:
	foreach (file; drm.files)
	{
		string jsonFile = file.setExtension(".json");

		if (drm.demosReadCnt++)
			putchar('\n');

		printf("Demo: %.*s\n", cast(int)file.length, file.ptr);

		scope dr = new DemoReader(file);

		drm.lastDemoWasLive = dr.isLive;

		// create json if: new demo, used -json, json doesn't exist, json is older than demo file
		JsonOutput.resetAndSetActive(
			dr.isLive ||
			g_jsonFlag ||
			!jsonFile.exists ||
			(jsonFile.timeLastModified < file.timeLastModified));

		// don't process new demos with -release (see comment)
		if (!canProcessNewDemos && JsonOutput.isActive)
		{
			// 1. live (can't have json)
			// 2. doesn't have json (= hasn't been successfully processed before)
			if (dr.isLive || !jsonFile.exists)
			{
				fprintf(stderr, "demoreader: skipping new demo %.*s due to release build\n", cast(int)file.length, file.ptr);
				continue;
			}
		}

		bool endReached;
		try
			endReached = dr.run();
		catch (Throwable e)
		{
			e.toString((in char[] s)
			{
				fprintf(stderr, "%.*s", cast(int)s.length, s.ptr);
			});
			putc('\n', stderr);

			fprintf(stderr, "Failing demo: %.*s\n", cast(int)file.length, file.ptr);

			if (!drm.keepgoing)
			{
				drm.fatalError = true;
				return;
			}
			else
			{
				// note: can't store the Throwable since it might get reused (asserts do this)
				drm.errordemos ~= ErrorInfo(file, e.file, e.line, e.msg);
				goto nextDemo;
			}
		}

		// write out json for complete demos
		if (endReached)
			JsonOutput.save(jsonFile);

nextDemo:
		if (drm.verbose)
			printf("Previous demo: %.*s\n", cast(int)file.length, file.ptr);
	}

	/*
	 * if:
	 * - new demos ok
	 * - output going in terminal
	 * - used "-1"
	 * - last demo was live (or forced with "-live")
	 * - last demo was automatically named
	 * then
	 * - wait for the next auto-named demo to pop in the same directory
	 * - resume live-reading from that demo
	 * end
	 * 
	 * a: should also disable waiting on live demos with other ranges like "-5-"
	 */
	if (
		canProcessNewDemos &&
		isatty(1) &&
		drm.rangetype == '-' &&
		drm.rangenum == 1 &&
		drm.lastDemoWasLive &&
		drm.files[$-1].isAutoNamedDemo)
	{
		string liveFile = drm.files[$-1];
		string liveDir = drm.files[$-1].dirName;

		MonoTime waitStart = MonoTime.currTime;

		auto dw = FileWatch(liveDir);

		for (;;)
		{
			enum datePartLength = "2022-07-18_16-03-15".length;
			string liveDatePart = liveFile.baseName[0..datePartLength];

			string[] newer = liveDir
				.dirEntries(autoNamedDemoPattern, SpanMode.shallow)
				// rough test to filter out the mass of old auto-named demos
				.filter!((p) => p.baseName[0..datePartLength] >= liveDatePart)
				// not less-than the old live demo (precise test)
				.filter!((p) => !demoNameCompareFn(p, liveFile))
				// not the demo we just played
				.filter!((p) => p.baseName != liveFile.baseName)
				.map!"a.name"
				.array
				// sort them (although normally there should be only one)
				.sort!demoNameCompareFn
				.array;

			if (newer.length)
			{
				Duration waitDur = MonoTime.currTime - waitStart;
				waitDur = msecs(waitDur.total!"msecs"); // round

				if (g_liveStat)
					printf("-live: got next demo after %s: %s\n", waitDur.toString().toStringz, newer[0].toStringz);

				drm.files = newer;
				break;
			}
			else
			{
				if (g_liveStat)
					printf("-live: waiting for next demo...\n");

				dw.waitChanged();
			}
		}

		goto fileloop;
	}
}

int main(string[] args)
{
	DrMain drm;

	version(Posix)
	{
		if ("_DEMOREADER_IN_PAGER" in environment)
		{
			g_useColor = true;

			// consistency
			setvbuf(stdout, null, _IOLBF, 0);
			setvbuf(stderr, null, _IOLBF, 0);

			// ignore SIGPIPE (pager exited before all output was written)
			extern(C) static void handler(int)
			{
				_exit(0);
			}
			signal(SIGPIPE, &handler);
		}
		else
		{
			if (isatty(1))
				g_useColor = true;
			else
				g_useColor = false;
		}
	}
	else
	{
		g_useColor = false;
	}

	g_marks = parseMarks(thisExePath.dirName~"/marks.txt");

	parseCommandLine(drm, args);

	readSearchDirsConfig(drm);

	/*
	 * files given on the command line?
	 */
	if (drm.files.length)
	{
		interpretFileArgs(drm);
	}
	else
	{
		loadAllDemos(drm);
	}

	drm.files = drm.files
		.sort!demoNameCompareFn
		.array;

	/*
	 * apply range thing
	 */
	if (drm.rangetype)
	{
		if (drm.rangenum > drm.files.length)
			drm.rangenum = cast(int)drm.files.length;

		if (drm.rangetype == '-')
			drm.files = drm.files[$-drm.rangenum..$];
		else if (drm.rangetype == '+')
			drm.files = drm.files[drm.rangenum-1..$];

		if (!drm.rangerest && drm.files.length)
			drm.files = drm.files[0..1];
	}

	if (drm.listonly)
	{
		foreach (s; drm.files)
			printf("%.*s\n", cast(int)s.length, s.ptr);

		return 0;
	}

	runFileLoop(drm);

	if (g_sizeStatEnabled)
	{
		string commaize(ulong v)
		{
			char[64] buf;
			char *p = &buf[$-1];
			size_t i;
			if (v)
				do
				{
					*p-- = '0' + v % 10;
					v /= 10;
					if (v && i++ % 3 == 2) *p-- = ',';
				}
				while (v);
			else
				*p-- = '0';
			return buf[p-buf.ptr+1..$].idup;
		}

		printf("total %s bytes, %.3Lf seconds\n",
			commaize(g_sizeStatTotalSize).toStringz,
			g_sizeStatTotalDuration);
	}

	static if (SpaceTally.enabled)
	{
		SpaceTally.print();
	}

	if (drm.keepgoing && drm.errordemos)
	{
		printf("*** %zu/%zu of played demos had errors:\n", drm.errordemos.length, drm.files.length);

		foreach (file; drm.errordemos)
		{
			printf("%.*s\n", cast(int)file.filename.length, file.filename.ptr);

			printf("  %s(%llu): %s\n", file.errfile.toStringz, cast(ulong)file.errline, file.errmsg.toStringz);
		}
	}

	if (drm.fatalError)
		return 1;

	return 0;
}

/**
 * the compare function for sorting demo filenames
 * 
 * in most cases, this is a simple ascii byte comparison, but a special case
 *  exists for automatically named demos with a duplicate count above 9 (two
 *  digits, so ascii comparison wouldn't sort them right)
 * 
 * note: directory names aren't considered when sorting (should they be? maybe
 *  for non-automatically named demos only?)
 * 
 * i would like to thank whoever made "." sort before "_" in ascii
 */
bool demoNameCompareFn(string p1, string p2)
{
	p1 = p1.baseName;
	p2 = p2.baseName;

	enum autoDateLength = "2022-06-27_19-57-54".length;
	enum lengthWithDupeCount = "2022-06-27_19-57-54_1.dem".length;

	/*
	 * branch if both are true:
	 * 1. different length (might need manual sorting)
	 * 2. both are as long as an auto-named demo with a duplicate count
	 * 
	 * the exact case we're looking for is two automatically named demos with
	 *  duplicate counts that have different lengths (like "_2.dem" vs. "_10.dem")
	 * 
	 * the most common case (two auto-named demos without a duplicate count)
	 *  stops at the length comparison here
	 */

	if (
		p1.length != p2.length &&
		p1.length >= lengthWithDupeCount &&
		p2.length >= lengthWithDupeCount &&
		true)
	{
		/*
		 * compare the date portion first
		 * 
		 * we only need to compare duplicate counts for demos with the same date portion!!
		 */

		enum partBeforeDupeCountLength = "2022-06-27_19-57-54_".length;
		int cmpRes;
		if (!__ctfe)
			cmpRes = memcmp(p1.ptr, p2.ptr, partBeforeDupeCountLength);
		else
		{
			// can't call memcmp() at compile time, do it manually
			foreach (i; 0..partBeforeDupeCountLength)
			{
				if ((cmpRes = (p1[i] - p2[i])) != 0)
					break;
			}
		}
		if (cmpRes != 0)
			return cmpRes < 0;

		/*
		 * check duplicate count (if both have underscore + digit here)
		 */

		import std.ascii;
		if (
			p1.isAutoNamedDemo &&
			p2.isAutoNamedDemo &&
			p1[autoDateLength] == '_' && // p2 already compared same
			p1[autoDateLength+1].isDigit &&
			p2[autoDateLength+1].isDigit &&
			true)
		{
			if (!__ctfe)
				return atoi(&p1[autoDateLength+1]) < atoi(&p2[autoDateLength+1]);
			else
			{
				// can't call atoi() at compile time, do it manually
				int atoi(string s)
				{
					int n;
					for (; s.length && s[0].isDigit; s = s[1..$]) n = n*10 + (s[0]-'0');
					return n;
				}
				return atoi(p1[autoDateLength+1..$]) < atoi(p2[autoDateLength+1..$]);
			}
		}
	}

	/*
	 * compare as bytes
	 */

	return p1 < p2;
}
unittest
{
	enum someDemos = [
		"2.dem",
		"2022-06-24_16-46-31.dem",
		"2022-06-24_16-46-31_1.dem",
		"2022-06-24_16-46-31_2.dem",
		"2022-06-24_16-46-31_10.dem",
		"2022-06-24_16-46-31_30.dem",
		"2022-07-24_16-46-31.dem",
		"2022-07-24_16-46-31_1.dem",
		"2022-07-24_16-46-31_2.dem",
		"2022-07-24_16-46-31_10.dem",
		"2022-07-24_16-46-31_30.dem",
		"gruesome.dem",
	];
	assert(someDemos.reverse.sort!demoNameCompareFn.array == someDemos);
	foreach (i; 0..3)
		assert(imported!"std.random".randomShuffle(someDemos).array.sort!demoNameCompareFn.array == someDemos);
}
static assert(demoNameCompareFn("2022-07-24_16-46-31.dem", "2022-07-24_16-46-31_1.dem") == true); // (byte comparison)
static assert(demoNameCompareFn("2022-07-24_16-46-31_1.dem", "2022-07-24_16-46-31_2.dem") == true); // (byte comparison)
static assert(demoNameCompareFn("2022-07-24_16-46-31_1.dem", "2022-07-24_16-46-31_10.dem") == true); // (byte comparison)
static assert(demoNameCompareFn("2022-07-24_16-46-31_2.dem", "2022-07-24_16-46-31_10.dem") == true); // this needs the numeric comparison to work right
static assert(demoNameCompareFn("2022-07-24_16-46-31_10.dem", "2022-07-24_16-46-31_2.dem") == false); // this needs the numeric comparison to work right
static assert(demoNameCompareFn("2022-07-24_16-46-31_1.dem", "2022-07-24_16-46-31_xyz.dem") == true); // (byte comparison)
static assert(demoNameCompareFn("2022-08-24_16-46-31.dem",   "2022-07-24_16-46-31_1.dem") == false); // remember to check the date portion
static assert(demoNameCompareFn("2022-08-24_16-46-31_2.dem", "2022-07-24_16-46-31_10.dem") == false); // remember to check the date portion!!
static assert(demoNameCompareFn("2022-07-24_16-46-31.dem", "202.dem") == false); // no bounds error

/// pattern for dirEntries() to match automatically named demos
enum autoNamedDemoPattern = "20??-??-??_*.dem";

/// test if the path is an automatically named demo
bool isAutoNamedDemo(string path)
{
	string base = path.baseName;
	return
		base.length >= "2022-07-24_20-27-12.dem".length &&
		base[0] == '2' &&
		base[1] == '0' &&
		base[4] == '-' &&
		base[7] == '-' &&
		base[10] == '_' &&
		base.extension == ".dem";
}
static assert(isAutoNamedDemo("2022-07-24_16-46-31.dem"));
static assert(isAutoNamedDemo("2022-07-24_16-46-31_stuff.dem"));

// -----------------------------------------------------------------------------

/**
 * true if it's ok to process new demos that haven't been processed with
 *  demoreader before
 * 
 * this will be false if demoreader was built with -release (or with any of the
 *  safety flags manually disabled)
 * 
 * we don't want to process new demos with -release because it optimizes out
 *  sanity checks assuming they always hold - result is unsupported/untested
 *  demos potentially giving any kind of wrong output
 */
enum canProcessNewDemos = isSafeBuild;

enum isSafeBuild =
{
	bool ok = true;

	// uh, this doesn't seem to be used
	//version(D_Invariants) {}
	//else
	//	ok = false;

	version(D_PreConditions) {}
	else
		ok = false;

	version(D_PostConditions) {}
	else
		ok = false;

	version(D_NoBoundsChecks)
		ok = false;

	version(assert) {}
	else
		ok = false;

	return ok;
}();

//pragma(msg, "isSafeBuild = ", isSafeBuild);
