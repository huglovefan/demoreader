/**
 * it's named DR for [D]eads [R]emos
 * 
 * the main part of the program, everything related to demo reading that wasn't
 *  separated into its own module (yet)
 */
module demoreader.dr;

import core.stdc.stdarg;
import core.stdc.stdio;
import core.stdc.stdlib;
import core.time;
import std.algorithm;
import std.array;
import std.datetime.systime;
import std.digest.md;
import std.exception;
import std.file;
import std.math : log2;
import std.mmfile;
import std.path;
import std.stdio : File;
import std.string;
import demoreader.cdef.libsnappy;
import demoreader.entitystuff;
import demoreader.entitystuff.decode;
import demoreader.gameevent;
import demoreader.globals;
import demoreader.jsonoutput;
import demoreader.lzss;
import demoreader.player;
import demoreader.stringtable;
import demoreader.ttycolor;
import demoreader.util.bytereader;
import demoreader.util.filewatch;
import demoreader.util.sprint;
import demoreader.valve.bitbuf;
import demoreader.valve.demofile;
import demoreader.vote;

enum ubyte INVALID_PLAYER_SLOT = ubyte.max;

final class DemoReader
{
	private FileWatch    fw;
	private ByteReader   br;
	private Votes        votes;
	private StringTables stringTables;
	private Players      players;
	private GameEvents   gameEvents;

	string       filePath;    /// path to demo file
	demoheader_t header;      /// demo file header
	bool         isLive;      /// true if the demo is still being recorded
	bool         isIncomplete; /// live but too old file

	uint         demoTickNo;   /// tick number from the last parsed demo message
	uint         serverTickNo; /// tick number from net_tick

	uint         buildNumber; /// engine build number (svc_print)
	uint         ownPlayerSlot = INVALID_PLAYER_SLOT; /// 0-based player slot of local player (svc_serverinfo)
	int          signonState; /// (net_signonstate)

	/// true = valve server, safe to assume sane behavior
	/// false = possibly modded community server, tolerate some bugs and weird behavior
	bool         isOfficialServer;

	bool         isMatchMakingGame; /// server has teams decided in advance (valve casual or competitive)

	bool         isLocalListenServer; /// listen server hosted by local player

	bool         isFriendlyFireEnabled;

	/**
	 * set force=true on implied team events to skip the assert for team conflicts
	 * 
	 * some modded community servers let players change teams somehow without
	 *  firing the player_team event, leading to conflicts when the teams don't
	 *  match what we have on record
	 */
	bool         serverNeedsForcedImpliedTeamsWorkaround;

	/// reading a specific type of broken demo that's missing dem_datatables
	/// this makes entity parsing impossible since we don't get class data
	bool         isBrokenDemoMissingDataTables;

	bool serverAllowsSpectators()         { return !isOfficialServer; }
	bool serverAllowsBots()               { return !isOfficialServer; }
	bool serverAllowsTeamChange()         { return !isMatchMakingGame; }
	bool serverAllowsNameChange()         { return !isOfficialServer; }
	bool serverAllowsHalfLifeTelevision() { return !isOfficialServer; }
	bool serverAllowsCustomFileDownload() { return !isOfficialServer; }

	string fileName()
	{
		return filePath.baseName;
	}

	const(char)[] mapName()
	{
		return header.mapname.fromStringz;
	}

	static private DemoReader instance;

	static DemoReader get()
	{
		debug assert(instance);
		return instance;
	}
	static private void setInstance(DemoReader dr)
	{
		instance = dr;
	}

	this(string filename)
	{
		fw = FileWatch(filename); // set before reading so hasChanged doesn't miss anything
		filePath = filename;

		// default to mmap unless we know it's going to be a live demo
		bool openFirstWithMmap = true;
		if (g_forceLive)
			openFirstWithMmap = false;

		for (;;)
		{
			br = ByteReader(filename, /* useMmap */ openFirstWithMmap);
			if (br.data.length >= demoheader_t.sizeof)
				break;

			// file too short but used -live -> wait for it to grow
			if (g_forceLive)
			{
				while (fw.currentSize < demoheader_t.sizeof)
					fw.waitChanged();

				continue;
			}

			// file too short but didn't use -live -> signal error
			enforce(br.data.length, "file is empty: "~filename);
			enforce(br.data.length >= demoheader_t.sizeof, "file too small to be a valid demo: "~filename);
			assert(0); // unreachable
		}

		header = br.read!demoheader_t();
		enforce(header.demofilestamp == DEMO_HEADER_ID, "not a demo file: "~filename~" (wrong header stamp)");
		header.check();

		if (g_forceLive)
			isLive = true;
		else if (header.isLive)
		{
			// header hasn't had the duration written to it, so it's probably a live demo
			// either that or the game crashed while writing it so it was never finalized
			// detect this so we don't wait for a demo to be completed that never will be
			SysTime mtime = filename.timeLastModified;
			Duration age = (Clock.currTime - mtime);
			// use a low cutoff: normally it should be continuously updated as the game writes more data
			// inb4 this is broken by daylight saving time
			if (age <= 5.minutes)
				isLive = true;
			else
			{
				isIncomplete = true;
				printf("-demo header has no duration but the file is too old to be a live demo\n");
			}
		}

		// can't use mmap for live demos, "reopen" as non-mmap
		// (reason: we need to unmap and remap it to read more data, which will
		//  invalidate any pointers to the old mapping. there probably shouldn't
		//  be any, but i'm not 1000% sure so the safer option wins)
		// also, live stuff isn't performance-critical unlike the case of batch
		//  reading complete demos from storage
		if (isLive && openFirstWithMmap)
		{
			size_t offset = demoheader_t.sizeof;
			br = ByteReader(filename, offset, /* useMmap */ false);
		}
	}

	alias printTick = serverTickNo; // which tick to print
	//alias printTick = demoTickNo; // which tick to print
	private enum stampAsSeconds = true;
	private enum collateStamp = 1;
	static if (collateStamp)
		private uint stampPrintedTick;
	void logStamp()
	{
		static if (!collateStamp)
		{
			static if (stampAsSeconds)
				printf("[%10.3f] ", cast(double)printTick/(1000.0/15.0));
			else
				printf("[%10u] ", printTick);
		}
		else static if (collateStamp == 1)
		{
			if (stampPrintedTick != printTick)
			{
				static if (stampAsSeconds)
					printf("[%10.3f] ", cast(double)printTick/(1000.0/15.0));
				else
					printf("[%10u] ", printTick);
			}
			else
				printf("             ");

			stampPrintedTick = printTick;
		}
	}

	void log(A...)(const(char)* fmt, A args)
	{
		logStamp();
		printf(fmt, args);
		putchar('\n');
	}

	/**
	 * read that demo
	 */
	bool run()
	{
		setInstance(this);
		scope(exit)
			setInstance(null);

		scope(exit)
		{
			gameEvents.reset();
			stringTables.reset();
			players.reset();
			votes.reset();
			demoreader.entitystuff.gameState.reset();
		}

		if (TRACE1)
		{
			putchar('\n');
			header.print();
			putchar('\n');
		}

		JsonOutput.setDemoProtocol(header.demoprotocol);
		JsonOutput.setNetworkProtocol(header.networkprotocol);
		JsonOutput.setServerIp(header.servername.fromStringz);
		if (isIncomplete)
			JsonOutput.setIncomplete();
		if (!header.isLive)
		{
			JsonOutput.setDemoDuration(header.playback_time);

			// detect listenserver/2022-08-18_22-34-05_3.dem
			if (header.playback_time < 0 || header.playback_ticks < 0)
				printf("-demo header has a negative duration: %d ticks, %f seconds\n",
					header.playback_ticks, header.playback_time);
		}

		alias PRINT = g_liveStat;

		bool demoEndReached;
		ulong statTotalRead;

		debug assert(br.offset == demoheader_t.sizeof);

		retryloop:
		for (;;)
		{
			uint runLoopBeginTick = demoTickNo;
			ulong runLoopBeginOffset = br.offset;

			// "successfully parsed until"
			// like br.offset but only updated after a successful run() (so it
			//  doesn't include bytes from partially read messages)
			ulong parsedUntilOffset = br.offset;

			// tick count is wrong until we get dem_synctick
			bool correctTickCount = (signonState >= 5);

			/// print stats for the message reading loop
			void printRunLoopStat()
			{
				ulong sizeParsed = parsedUntilOffset-runLoopBeginOffset;

				statTotalRead += sizeParsed;

				if (!PRINT)
					return;

				float dur = (demoTickNo-runLoopBeginTick) / (1000.0/15.0);

				if (correctTickCount)
					printf("-live: parsed %llu byte(s), %.3f second(s) of content\n", sizeParsed, dur);
				else
					printf("-live: parsed %llu byte(s)\n", sizeParsed);
			}

			try
			{
				runloop:
				for (;;)
				{
					bool keepGoing = runOne();
					parsedUntilOffset = br.offset;
					if (keepGoing)
						continue runloop;
					else
					{
						demoEndReached = true;
						printRunLoopStat();
						break retryloop;
					}
				}
			}
			catch (ByteReaderRangeException e)
			{
				printRunLoopStat();

				// demo that was never finalized (2022-10-31_06-56-50_3.dem)
				if (isIncomplete)
				{
					demoEndReached = true;
					break;
				}

				// only live demos should normally get here
				if (!isLive)
					throw e;

				// incomplete live demo but used -nowait
				if (g_noWait)
					break;

				/*
				 * wait for the file to grow
				 * (and print some stuff)
				 */

				if (PRINT)
					printf("-live: waiting for more data\n");
				MonoTime start = MonoTime.currTime;

				// note: fw's size might be outdated (lower than br.totalSize)
				// just wait until it's bigger

				while (!(fw.currentSize > br.totalSize))
					fw.waitChanged();

				/*
				 * restart reading at the previous position
				 */

				ulong oldTotalSize = br.totalSize;
				br = ByteReader(filePath, parsedUntilOffset, /* useMmap */ false);
				assert(br.totalSize > oldTotalSize); // didn't just restart for nothing

				Duration dur = MonoTime.currTime - start;
				dur = msecs(dur.total!"msecs"); // round
				if (PRINT)
					printf("-live: demo grew by %lld byte(s) in %s\n", br.totalSize-oldTotalSize, dur.toString().toStringz);
			}
		}

		// entire file was read?
		if (demoEndReached && isIncomplete)
		{
			// incomplete demos skip most of the other stuff
			JsonOutput.setDemoDuration(getFinishedDuration);
		}
		else if (demoEndReached)
		{
			assert(!br.data.length);
			assert(br.offset == statTotalRead+demoheader_t.sizeof); // stats were accurate

			/*
			 * get the final header for live demos that became completed
			 */
			if (header.isLive)
			{
				for (;;)
				{
					*cast(void[header.sizeof]*)&header = std.file.read(filePath, header.sizeof);
					header.check();
					if (!header.isLive)
						break;
					fw.waitChanged();
				}

				JsonOutput.setDemoDuration(header.playback_time);

				// (re-check this)
				if (header.playback_time < 0 || header.playback_ticks < 0)
					printf("-demo header has a negative duration: %d ticks, %f seconds\n",
						header.playback_ticks, header.playback_time);
			}

			// check server type for negative-duration demos
			if (header.playback_time < 0 || header.playback_ticks < 0)
				assert(isLocalListenServer);

			/*
			 * get a proper duration for some weird listen server demos
			 * 
			 * ex: 2022-08-18_22-34-05_3.dem
			 */
			if (header.playback_ticks != getFinishedDurationTicks)
			{
				// test: only seen with this configuration so far
				bool knownCase = isLocalListenServer && header.playback_time < 0 && header.playback_ticks < 0;

				// not interesting to print
				if (!knownCase || TRACE1)
					printf("-duration mismatch: header says %dt/%.3fs, we got %ut/%.3Lfs (isLocal %u)\n",
						header.playback_ticks, header.playback_time,
						getFinishedDurationTicks, getFinishedDuration,
						isLocalListenServer);

				JsonOutput.setDemoDuration(getFinishedDuration);

				assert(knownCase);
			}
		}

		if (g_sizeStatEnabled)
		{
			g_sizeStatTotalSize += br.offset;
			g_sizeStatTotalDuration += getFinishedDuration;
		}

		return demoEndReached;
	}

private:

	uint getFinishedDurationTicks()
	{
		if (signonState < 5)
			return 0;
		else
			return demoTickNo;
	}
	real getFinishedDuration()
	{
		if (signonState < 5)
			return 0;
		else
			return demoTickNo * 0.015L;
	}

	uint readMessage()
	{
		uint cmd = br.read!ubyte();
		uint tick;

		/*
		 * now read the tick count
		 * 
		 * bug: dem_stop's is missing the last byte (would become non-zero after 70 hours)
		 */

		if (cmd == dem_stop)
		{
			ubyte[3] rest = br.read!(ubyte[3])();
			tick = rest[0]
			/**/ | rest[1]<<8
			/**/ | rest[2]<<16
			/**/ | demoTickNo&0xff000000;
		}
		else
		{
			tick = br.read!uint();
		}

		// "data remaining" == "not dem_stop"
		// * except when reading live demos, they can naturally pause at the
		//    message boundary until more data is written
		debug
		{
			if (cmd == dem_stop)
				assert(!br.remaining);
			else
				assert(br.remaining || isLive);
		}

		/*
		 * assign the demo tick, but check that it's reasonable first
		 * 
		 * this is mainly done so that we can calculate a correct duration for
		 *  the demo (for json and -livestat)
		 * 
		 * funny ticks usually happen:
		 * - during signon when the tick is wrong anyway
		 * - in some listen server demos near the end (quit or map change)
		 * - possibly for some lag spikes?
		 *   - 12.96 sec jump in skial/2022-04-30_13-39-10.dem
		 *   - 13.275 sec jump in listenserver/2022-08-01_00-05-39.dem
		 *   - 14.775 sec jump in listenserver/2022-08-01_01-17-42.dem
		 *   - 14.805 sec jump in listenserver/2022-08-01_01-17-42_2.dem
		 *   - 33 sec jump in 2022-11-20_00-39-51_2.dem at changelevel
		 *   - i think the listen server ones might be caused by backgrounding
		 *      the game window
		 */

		if (tick >= demoTickNo)
		{
			uint diff = tick - demoTickNo;
			enum maxJump = cast(uint)(30 / 0.015); // seconds / tick rate

			// 1. normal and reasonable adjustment
			// 2. first set of tick count
			// 3. actually, let's just trust the tick count always if it's a
			//     non-listen server. i'm thinking it's listen servers that are
			//     the weird case that needs special handling here. since you're
			//     the host, lag spikes (alt tabbing) can actually warp time on
			//     the server. that's not the case if you're just a connected
			//     client. time warps are what we want to detect and skip here.
			if (diff <= maxJump || (!signonState && !demoTickNo) || !isLocalListenServer)
			{
				if (TRACE1)
					printf("* assign tick %u -> %u (diff %u, signonState %u)\n", demoTickNo, tick, diff, signonState);
				demoTickNo = tick;
			}
			else
			{
				// not interesting to print
				if (TRACE1)
					printf("-demo tick jump: %ut/%.1fs -> %ut/%.1fs (diff %ut/%.1fs, signonState %u)\n",
						demoTickNo, demoTickNo*0.015,
						tick, tick*0.015,
						diff, diff*0.015,
						signonState);
			}
		}
		else
		{
			// synctick normally jumps backwards
			if (cmd == dem_synctick)
				demoTickNo = tick;
			else
				assert(isLocalListenServer && cmd == dem_stop);
		}

		return cmd;
	}

	bool runOne()
	{
		uint cmd = readMessage();

		/+
		 + total counts
		 + 
		 . 14237505 dem_usercmd
		 . 13823324 dem_packet
		 .  1230126 dem_consolecmd
		 .     1937 dem_signon
		 .      451 dem_datatables
		 .      451 dem_stop
		 .      451 dem_stringtables
		 .      451 dem_synctick
		 +/

		/+
		 + total sizes (in bytes)
		 + 
		 . 4,734,146,460 dem_packet
		 .   521,931,301 dem_usercmd
		 .   298,599,393 dem_stringtables
		 .    69,064,679 dem_signon
		 .    66,414,056 dem_datatables
		 .    27,173,313 dem_consolecmd
		 .         2,390 dem_stop
		 .         2,390 dem_synctick
		 +/

		// for -live: print this only after reading the entire message
		void tracePrint()
		{
			if (TRACE1)
			{
				// highlight synctick (end of signon process)
				if (cmd == dem_synctick && g_useColor)
					printf(" \x1b[1m%s\x1b[0m (t=%u)\n", cmd.demoMessageName.ptr, demoTickNo);
				else
					printf(" %s (t=%u)\n", cmd.demoMessageName.ptr, demoTickNo);
			}
		}

		static if (SpaceTally.enabled)
		{
			ulong startOffset = br.offset;
			scope(success)
			{
				ulong readSize = br.offset - startOffset;
				SpaceTally.countDemoMessage(cmd.demoMessageName, readSize);
			}
		}

		final switch (cmd)
		{
			case dem_usercmd:
			{
				uint    ucmd = br.read!uint();
				uint    size = br.read!uint();
				ubyte[] data = br.read!(ubyte[])(size);

				tracePrint();
				handleUserCmd(ucmd, data);

				break;
			}

			case dem_packet:
			{
				democmdinfo_t packetInfo  = br.read!democmdinfo_t();
				uint          inSequence  = br.read!uint();
				uint          outSequence = br.read!uint();
				uint          size        = br.read!uint();
				ubyte[]       data        = br.read!(ubyte[])(size);

				tracePrint();
				handlePacket(data);

				// did we get any entity updates this packet?
				if (auto snap = demoreader.entitystuff.gameState.snapshotForTick(serverTickNo))
				{
					for (int i = 1; i <= players.maxPlayers; i++)
					{
						auto ent = snap.entities[i];

						if (!ent)
							continue;

						if (!ent.inPvs)
							continue;

						int lifestate = ent.prop!int("m_lifeState", -1);

						// this happens
						if (lifestate != /* alive */ 0)
						{
							//printf("-pl has bad pitch but they're dead - (pitch=%f yaw=%f) lifestate=%d %s\n", 
							//	pitch,
							//	ent.prop!float("tfnonlocaldata.m_angEyeAngles[1]"),
							//	lifestate,
							//	pl.ttyname);
							continue;
						}

						float pitch = ent.prop!float("tfnonlocaldata.m_angEyeAngles[0]");

						if (
							pitch > 0x1.652d2cp+6 ||
							pitch < -0x1.652d3p+6)
						{
							// force: they might've just disconnected (2022-07-31_06-58-54.dem)
							Player *pl = players.getByEntIndex(i, /* force */ true);
							assert(pl);

							if (!pl.badPitchTick || serverTickNo >= pl.badPitchTick+66)
							{
								pl.badPitchTick = serverTickNo;

								if (++pl.badPitchPrintCount <= 5)
								{
									printf("-player has bad pitch: (pitch=%f yaw=%f) - %s %s\n",
										pitch,
										ent.prop!float("tfnonlocaldata.m_angEyeAngles[1]"),
										pl.info.guid.ptr, pl.ttyname);
									JsonOutput.setEvBadPitch();
								}
							}
						}
					}

					// TEST
					static if (0)
					for (int i = 1; i <= players.maxPlayers; i++)
					{
						auto ent = demoreader.entitystuff.gameState.entities[i];

						if (!ent)
							continue;

						if (i != 11) continue; // TEST

						if (!ent.inPvs)
						{
							printf("...\n");
							continue;
						}

						int lifestate = ent.prop!int("m_lifeState", -1);

						if (lifestate != /* alive */ 0)
						{
							printf("...\n");
							continue;
						}

						auto groundEntity = ent.prop!int("localdata.m_hGroundEntity");
						auto flags = ent.prop!int("m_fFlags");

						enum FL_ONGROUND = 1;

						auto jumpingByGe = ((groundEntity & 0x7ff) == 2047);
						auto jumpingByFlags = !(flags & FL_ONGROUND);
						auto jumpingByBool = ent.prop!int("m_Shared.m_bJumping");

						printf("-jumping by: ge=%d flags=%d bool=%d\n",
							jumpingByGe,
							jumpingByFlags,
							jumpingByBool,
							);

						if (jumpingByGe != jumpingByFlags)
						{
							printf("-bad ent1 %d\n", i);
							//printf("ground ent = %d\n", groundEntity & 0x7ff);
							//assert(0);
						}
						if (jumpingByBool != jumpingByFlags)
						{
							printf("-bad ent2 %d\n", i);
							//assert(0);
						}
					}
				}

				break;
			}

			case dem_consolecmd:
			{
				uint    size = br.read!uint();
				ubyte[] data = br.read!(ubyte[])(size);

				tracePrint();
				handleConsoleCmd(data);

				break;
			}

			case dem_signon:
				goto case dem_packet;

			case dem_datatables:
			{
				uint    size = br.read!uint();
				ubyte[] data = br.read!(ubyte[])(size);

				tracePrint();
				assert(!isBrokenDemoMissingDataTables);
				handleDataTables(data);

				break;
			}

			case dem_stop:
			{
				// end of time
				tracePrint();
				if (g_htmlOut)
					htmlSimpleRow("End of demo.");
				break;
			}

			case dem_stringtables:
			{
				uint    size = br.read!uint();
				ubyte[] data = br.read!(ubyte[])(size);

				tracePrint();
				handleStringTables(data);

				break;
			}

			case dem_synctick:
			{
				tracePrint();

				if (signonState != 5)
					printf("-broken demo: got dem_synctick at signonState %u\n", signonState);

				switch (signonState)
				{
				case 3:
					// these demos are missing dem_datatables so we lack classes, can't parse baselines
					assert(!gameState.classes.length);
					assert(!gameState.baseLines.baselines.length);
					isBrokenDemoMissingDataTables = true;
					break;
				case 4:
				case 5:
					assert(gameState.classes.length);
					assert(gameState.baseLines.baselines.length);
					break;
				default:
					assert(0); // haven't seen
				}

				// Let's craft.
				if (signonState == 3 || signonState == 4)
					signonState = 5;

				break;
			}
		}

		return cmd != dem_stop;
	}

	void handleUserCmd(uint ucmd, ubyte[] data)
	{
		scope buf = new bf_read(data);

		if (TRACE1)
			printf("  ucmd=%d\n", ucmd);

		if (buf.ReadOneBit())
		{
			uint commandNumber = buf.ReadUBitLong(32);
			if (TRACE1)
				printf("  commandNumber=%d\n", commandNumber);
		}

		if (buf.ReadOneBit())
		{
			uint tickCount = buf.ReadUBitLong(32);
			if (TRACE1)
				printf("  tickCount=%d\n", tickCount);
		}

		if (buf.ReadOneBit())
		{
			float ang1 = buf.ReadBitFloat();
			if (TRACE1)
				printf("  ang1=%f\n", ang1);
		}

		if (buf.ReadOneBit())
		{
			float ang2 = buf.ReadBitFloat();
			if (TRACE1)
				printf("  ang2=%f\n", ang2);
		}

		if (buf.ReadOneBit())
		{
			float ang3 = buf.ReadBitFloat();
			if (TRACE1)
				printf("  ang3=%f\n", ang3);
		}

		if (buf.ReadOneBit())
		{
			float forwardMove = buf.ReadBitFloat();
			if (TRACE1)
				printf("  forwardMove=%f\n", forwardMove);
		}

		if (buf.ReadOneBit())
		{
			float sideMove = buf.ReadBitFloat();
			if (TRACE1)
				printf("  sideMove=%f\n", sideMove);
		}

		if (buf.ReadOneBit())
		{
			float upMove = buf.ReadBitFloat();
			if (TRACE1)
				printf("  upMove=%f\n", upMove);
		}

		if (buf.ReadOneBit())
		{
			uint buttons = buf.ReadUBitLong(32);
			if (TRACE1)
				printf("  buttons=0x%x\n", buttons);
		}

		if (buf.ReadOneBit())
		{
			uint impulse = buf.ReadUBitLong(8);
			if (TRACE1)
				printf("  impulse=%d\n", impulse);
		}

		if (buf.ReadOneBit())
		{
			int weaponSelect = buf.ReadUBitLong(11);
			if (TRACE1)
				printf("  weaponSelect=%d\n", weaponSelect);

			if (buf.ReadOneBit())
			{
				int weaponSubType = buf.ReadUBitLong(6);
				if (TRACE1)
					printf("  weaponSubType=%d\n", weaponSubType);
			}
		}

		if (buf.ReadOneBit())
		{
			uint mouseDx = buf.ReadShort();
			if (TRACE1)
				printf("  mouseDx=%d\n", mouseDx);
		}

		if (buf.ReadOneBit())
		{
			uint mouseDy = buf.ReadShort();
			if (TRACE1)
				printf("  mouseDy=%d\n", mouseDy);
		}

		assert(!buf.GetNumBytesLeft()); // byte-aligned
	}

	void handlePacket(ubyte[] packetData)
	{
		scope buf = new bf_read(packetData);

		/+
		 + total counts
		 + 
		 . 13822487 net_tick
		 . -------- 35%
		 . 13821585 svc_packetentities
		 . -------- 69%
		 .  4638492 svc_sounds
		 . -------- 81%
		 .  4104214 net_nop
		 . -------- 90%
		 .  1304310 svc_tempentities
		 .  1112099 svc_gameevent
		 .   418018 svc_prefetch
		 . -------- 98%
		 .   306977 svc_updatestringtable
		 .   114913 svc_usermessage
		 . -------- 99%
		 .   108857 svc_voicedata
		 .   105775 svc_fixangle
		 .    38985 svc_entitymessage
		 .    15809 svc_print
		 .     9020 svc_createstringtable
		 .     3125 net_file
		 .     2817 net_stringcmd
		 .     1964 svc_bspdecal
		 .     1524 net_signonstate
		 .      765 svc_setview
		 .      559 net_setconvar
		 .      451 svc_classinfo
		 .      451 svc_gameeventlist
		 .      451 svc_serverinfo
		 .      451 svc_voiceinit
		 .        0 svc_getcvarvalue
		 +/

		/+
		 + total sizes (in bytes)
		 + 
		 . 2,997,727,260 svc_packetentities
		 .   127,587,180 net_tick
		 .    89,286,166 svc_sounds
		 .    62,740,563 svc_updatestringtable
		 .    60,603,648 svc_createstringtable
		 .    36,319,694 svc_voicedata
		 .    33,258,024 svc_tempentities
		 .    19,004,380 svc_gameevent
		 .     7,883,874 svc_gameeventlist
		 .     3,181,535 net_nop
		 .     1,921,695 svc_usermessage
		 .     1,189,640 svc_print
		 .     1,128,610 svc_prefetch
		 .       731,184 svc_fixangle
		 .       236,054 svc_entitymessage
		 .       151,854 net_setconvar
		 .       115,688 net_file
		 .        59,581 svc_serverinfo
		 .        45,325 net_stringcmd
		 .        20,941 svc_bspdecal
		 .         9,258 net_signonstate
		 .         4,661 svc_voiceinit
		 .         1,739 svc_setview
		 .         1,375 svc_classinfo
		 +/

		enum packetNumberBits = 6;

		while (buf.GetNumBitsLeft() >= packetNumberBits)
		{
			uint msg = buf.ReadUBitLong(packetNumberBits);

			if (TRACE1)
				printf("  %s\n", packetName(msg).ptr);

			static if (SpaceTally.enabled)
			{
				ulong startBit = buf.GetNumBitsRead();
				scope(success)
				{
					ulong bitsRead = buf.GetNumBitsRead() - startBit;
					SpaceTally.countPacketBits(packetName(msg), bitsRead);
				}
			}

			final switch (msg)
			{
				case net_tick:
				{
					enum NET_TICK_SCALEUP = 100000.0;

					uint   tick_                     = buf.ReadLong();
					double hostFrameTime             = buf.ReadUBitLong(16) / NET_TICK_SCALEUP;
					double hostFrameTimeStdDeviation = buf.ReadUBitLong(16) / NET_TICK_SCALEUP;

					serverTickNo = tick_;
					demoreader.entitystuff.gameState.serverTick = tick_;

					if (TRACE1)
					{
						printf("   tick=%u\n", tick_);
						printf("   hostFrameTime=%f\n", hostFrameTime);
						printf("   hostFrameTimeStdDev=%f\n", hostFrameTimeStdDeviation);
					}

					break;
				}

				case svc_packetentities:
				{
					bool shouldParse = !(g_skipPacketEntities || isBrokenDemoMissingDataTables);
					demoreader.entitystuff.parseSvcPacketEntities(buf, !shouldParse);
					break;
				}

				case svc_sounds:
				{
					enum MAX_EDICT_BITS = 11;

					uint    reliableSound = buf.ReadOneBit();
					uint    numSounds     = (!reliableSound)
					/**/                  ? buf.ReadUBitLong(8)
					/**/                  : 1;
					uint    length        = (reliableSound)
					/**/                  ? buf.ReadUBitLong(8)
					/**/                  : buf.ReadUBitLong(16);
					scope sbuf = new bf_read(buf, length);

					// todo: delta thing, need to store previous sounds

					foreach (_; 0..numSounds)
					{
						/*
						 * entindex
						 */

						int entindex;
						if (!sbuf.ReadOneBit())
							entindex = -1; // get it from the soundinfo_t
						else
						{
							if (sbuf.ReadOneBit())
								entindex = sbuf.ReadUBitLong(5);
							else
								entindex = sbuf.ReadUBitLong(MAX_EDICT_BITS);
						}
						if (TRACE1)
						{
							Player* pl;
							if (entindex >= 1 && entindex < 1+players.maxPlayers)
								pl = players.getByEntIndex(entindex);

							int classid = -1;
							int pvs = -1;
							if (entindex >= 1 && entindex < 2048 && demoreader.entitystuff.gameState.entities[entindex])
							{
								classid = demoreader.entitystuff.gameState.entities[entindex].classid;
								pvs = demoreader.entitystuff.gameState.entities[entindex].inPvs;
							}

							string classname;
							if (classid != -1)
								classname = demoreader.entitystuff.gameState.classes[classid].name;

							if (pl)
								printf("   entindex=%d (%s pvs=%d)\n", entindex, pl.ttyname, pvs);
							else
								printf("   entindex=%d (%s pvs=%d)\n", entindex, classname.ptr, pvs);
						}

						/*
						 * soundNum
						 */

						int soundNum = -1;
						if (header.networkprotocol > 22)
						{
							enum MAX_SOUND_INDEX_BITS = 14;
							if (sbuf.ReadOneBit())
								soundNum = sbuf.ReadUBitLong(MAX_SOUND_INDEX_BITS);
						}
						else
						{
							if (sbuf.ReadOneBit())
								soundNum = sbuf.ReadUBitLong(13);
						}

						const(char)[] soundname;
						if (StringTable* st = stringTables.get("soundprecache"))
						{
							if (soundNum >= 0 && soundNum < st.entries.length)
							{
								soundname = st.entries[soundNum].name;
							}
						}

						// sound by a player? check if it's a noise maker
						// 2022-08-16_19-13-21_4.dem
						if (soundname)
						if (entindex >= 1 && entindex <= players.maxPlayers)
						if (Player* pl = players.getByEntIndex(entindex))
						{
							// https://wiki.teamfortress.com/wiki/Noise_Maker
							// https://github.com/SteamDatabase/GameTracking-TF2/blob/master/tf/tf2_misc_dir/scripts/game_sounds_player.txt
							switch (soundname)
							{
								// halloween
								case "items/halloween/banshee01.wav":
								case "items/halloween/banshee02.wav":
								case "items/halloween/banshee03.wav":
								case "items/halloween/cat01.wav":
								case "items/halloween/cat02.wav":
								case "items/halloween/cat03.wav":
								case "items/halloween/crazy01.wav":
								case "items/halloween/crazy02.wav":
								case "items/halloween/crazy03.wav":
								case "items/halloween/gremlin01.wav":
								case "items/halloween/gremlin02.wav":
								case "items/halloween/gremlin03.wav":
								case "items/halloween/stabby.wav":
								case "items/halloween/werewolf01.wav":
								case "items/halloween/werewolf02.wav":
								case "items/halloween/werewolf03.wav":
								case "items/halloween/witch01.wav":
								case "items/halloween/witch02.wav":
								case "items/halloween/witch03.wav":
								// shogun pack
								case `)items\samurai\TF_samurai_noisemaker_setB_01.wav`:
								case `)items\samurai\TF_samurai_noisemaker_setB_02.wav`:
								case `)items\samurai\TF_samurai_noisemaker_setB_03.wav`:
								// ja`an charity
								case `)items\japan_fundraiser\TF_zen_bell_01.wav`:
								case `)items\japan_fundraiser\TF_zen_bell_02.wav`:
								case `)items\japan_fundraiser\TF_zen_bell_03.wav`:
								case `)items\japan_fundraiser\TF_zen_bell_04.wav`:
								case `)items\japan_fundraiser\TF_zen_bell_05.wav`:
								case `)items\japan_fundraiser\TF_zen_tingsha_01.wav`:
								case `)items\japan_fundraiser\TF_zen_tingsha_02.wav`:
								case `)items\japan_fundraiser\TF_zen_tingsha_03.wav`:
								case `)items\japan_fundraiser\TF_zen_tingsha_04.wav`:
								case `)items\japan_fundraiser\TF_zen_tingsha_05.wav`:
								case `)items\japan_fundraiser\TF_zen_tingsha_06.wav`:
								// summer
								case `)items/summer/summer_fireworks1.wav`:
								case `)items/summer/summer_fireworks2.wav`:
								case `)items/summer/summer_fireworks3.wav`:
								case `)items/summer/summer_fireworks4.wav`:
								// manniversary
								case `)items\football_manager\vuvezela_01.wav`:
								case `)items\football_manager\vuvezela_02.wav`:
								case `)items\football_manager\vuvezela_03.wav`:
								case `)items\football_manager\vuvezela_04.wav`:
								case `)items\football_manager\vuvezela_05.wav`:
								case `)items\football_manager\vuvezela_06.wav`:
								case `)items\football_manager\vuvezela_07.wav`:
								case `)items\football_manager\vuvezela_08.wav`:
								case `)items\football_manager\vuvezela_09.wav`:
								case `)items\football_manager\vuvezela_11.wav`:
								case `)items\football_manager\vuvezela_12.wav`:
								case `)items\football_manager\vuvezela_13.wav`:
								case `)items\football_manager\vuvezela_14.wav`:
								case `)items\football_manager\vuvezela_15.wav`:
								case `)items\football_manager\vuvezela_16.wav`:
								case `)items\football_manager\vuvezela_17.wav`:
								{
									printf("-player used noise maker '%s': %s\n", soundname.ptr, pl.ttyname);
									break;
								}
								default:
									break;
							}
						}

						if (TRACE1)
						{
							if (soundname)
							{
								printf("   soundNum=%d <%s>\n", soundNum, soundname.ptr);
							}
							else
							{
								printf("   soundNum=%d <?>\n", soundNum);
							}
						}

						/*
						 * flags
						 */

						int flags;
						if (header.networkprotocol > 18)
						{
							enum SND_FLAG_BITS_ENCODE = 11;
							if (sbuf.ReadOneBit())
								flags = sbuf.ReadUBitLong(SND_FLAG_BITS_ENCODE);
						}
						else
						{
							if (sbuf.ReadOneBit())
								flags = sbuf.ReadUBitLong(9);
						}
						if (TRACE1)
							printf("   flags=%d\n", flags);

						/*
						 * channel
						 */

						int channel = -1;
						if (sbuf.ReadOneBit())
							channel = sbuf.ReadUBitLong(3);
						if (TRACE1)
							printf("   channel=%d\n", channel);

						/*
						 * isAmbient
						 */

						bool isAmbient = !!sbuf.ReadOneBit();
						if (TRACE1)
							printf("   isAmbient=%d\n", isAmbient);

						/*
						 * isSentence
						 */

						bool isSentence = !!sbuf.ReadOneBit();
						if (TRACE1)
							printf("   isSentence=%d\n", isSentence);

						enum SND_STOP = 1<<2;
						if (flags != SND_STOP)
						{
							/*
							 * sequenceNumber
							 */

							int sequenceNumber;
							if (sbuf.ReadOneBit())
							{
								sequenceNumber = -1;
							}
							else if (sbuf.ReadOneBit())
							{
								sequenceNumber = -1;
							}
							else
							{
								enum SOUND_SEQNUMBER_BITS = 10;
								sequenceNumber = sbuf.ReadUBitLong(SOUND_SEQNUMBER_BITS);
							}
							if (TRACE1)
								printf("   sequenceNumber=%d\n", sequenceNumber);

							/*
							 * volume
							 */

							float volume = float.nan;
							if (sbuf.ReadOneBit())
							{
								volume = cast(float)sbuf.ReadUBitLong(7)/127.0f;
							}
							if (TRACE1)
								printf("   volume=%f\n", volume);

							/*
							 * soundLevel
							 */

							int soundLevel;
							if (sbuf.ReadOneBit())
							{
								enum MAX_SNDLVL_BITS = 9;
								soundLevel = sbuf.ReadUBitLong(MAX_SNDLVL_BITS);
							}
							if (TRACE1)
								printf("   soundLevel=%d\n", soundLevel);

							/*
							 * pitch
							 */

							int pitch;
							if (sbuf.ReadOneBit())
								pitch = sbuf.ReadUBitLong(8);
							if (TRACE1)
								printf("   pitch=%d\n", pitch);

							/*
							 * specialDsp
							 */

							int specialDsp;
							if (header.networkprotocol > 21)
							{
								if (sbuf.ReadOneBit())
									specialDsp = sbuf.ReadUBitLong(8);
							}
							if (TRACE1)
								printf("   specialDsp=%d\n", specialDsp);

							/*
							 * delay
							 */

							float delay = float.nan;
							if (sbuf.ReadOneBit())
							{
								enum MAX_SOUND_DELAY_MSEC_ENCODE_BITS = 13;
								delay = sbuf.ReadUBitLong(MAX_SOUND_DELAY_MSEC_ENCODE_BITS) / 1000.0f;
								if (delay < 0)
									delay *= 10.0f;
							}
							if (TRACE1)
								printf("   delay=%f\n", delay);

							/*
							 * origin
							 */

							enum COORD_INTEGER_BITS = 14;
							Vector origin;
							if (sbuf.ReadOneBit())
								origin.x = sbuf.ReadSBitLong(COORD_INTEGER_BITS-2) * 8.0f;
							if (sbuf.ReadOneBit())
								origin.y = sbuf.ReadSBitLong(COORD_INTEGER_BITS-2) * 8.0f;
							if (sbuf.ReadOneBit())
								origin.z = sbuf.ReadSBitLong(COORD_INTEGER_BITS-2) * 8.0f;
							if (TRACE1)
								printf("   origin=(%.1f %.1f %.1f)\n", origin.x, origin.y, origin.z);

							/*
							 * speakerEntity
							 */

							int speakerEntity = -1;
							if (sbuf.ReadOneBit())
								speakerEntity = sbuf.ReadSBitLong(MAX_EDICT_BITS+1);
							if (TRACE1)
								printf("   speakerEntity=%d\n", speakerEntity);
						}
					}

					assert(!sbuf.GetNumBitsLeft()); // bit array

					break;
				}

				case net_nop:
				{
					break;
				}

				case svc_tempentities:
				{
					enum EVENT_INDEX_BITS = 8;
					enum NET_MAX_PAYLOAD_BITS_V23 = 17;

					uint numEntries = buf.ReadUBitLong(EVENT_INDEX_BITS);
					uint length     = (header.networkprotocol > 23)
					/**/            ? buf.ReadVarInt32()
					/**/            : buf.ReadUBitLong(NET_MAX_PAYLOAD_BITS_V23);
					scope sbuf = new bf_read(buf, length);

					Entity ent;

					if (!numEntries)
					{
						numEntries = 1;

						if (TRACE1)
							printf("   reliable=true\n");
					}

					if (!gameState.baseLines.baselines.length)
					{
						assert(isBrokenDemoMissingDataTables);
						break;
					}

					// test demos with sprays:
					// listenserver/2022-10-08_05-10-56.dem
					// listenserver/2022-10-08_05-18-24.dem

					void doneWithEnt(Entity ent)
					{
						if (gameState.classes[ent.classid].name == "CTEPlayerDecal")
						{
							Player* pl = players.getByEntIndex(ent.prop!int("m_nPlayer"));

							if (pl)
								printf("-player used spray: %s\n", pl.ttyname);
						}
					}

					foreach (_; 0..numEntries)
					{
						float delay = 0.0f;

						if (sbuf.ReadOneBit())
						{
							delay = sbuf.ReadSBitLong(8) / 100.0f;
						}

						if (sbuf.ReadOneBit())
						{
							int classid = sbuf.ReadUBitLong(9)-1;

							// these don't seem to have anything in the baseline
							assert(!gameState.baseLines.baselines[classid].properties.length);

							if (ent)
								doneWithEnt(ent);

							ent = gameState.baseLines.createTempEntity(classid);

							if (TRACE1)
								printf("   %s\n", gameState.classes[classid].name.ptr);

							readEntProps(sbuf, ent.props, gameState.classes[classid].flattenedProps);
						}
						else
						{
							assert(ent);

							if (TRACE1)
								printf("   %s (delta)\n", gameState.classes[ent.classid].name.ptr);

							readEntProps(sbuf, ent.props, gameState.classes[ent.classid].flattenedProps);
						}
					}

					if (ent)
						doneWithEnt(ent);

					assert(!sbuf.GetNumBitsLeft()); // bit array

					break;
				}

				case svc_gameevent:
				{
					enum NETMSG_LENGTH_BITS = 11;

					uint length = buf.ReadUBitLong(NETMSG_LENGTH_BITS);
					scope sbuf = new bf_read(buf, length);

					if (handleGameEvent(sbuf))
						assert(!sbuf.GetNumBitsLeft()); // bit array

					break;
				}

				case svc_prefetch:
				{
					enum MAX_SOUND_INDEX_BITS = 14;

					uint soundIndex = (header.networkprotocol > 22)
					/**/            ? buf.ReadUBitLong(MAX_SOUND_INDEX_BITS)
					/**/            : buf.ReadUBitLong(13);

					StringTable* st = stringTables.get("soundprecache");
					assert(st);

					if (soundIndex < st.entries.length)
					{
						if (TRACE1)
							printf("   soundIndex=%u <%s>\n", soundIndex, st.entries[soundIndex].name.ptr);
					}
					else
					{
						// why does this happen?
						// example: 2022-07-18_15-49-40.dem
						//printf("-bad soundIndex in svc_prefetch: have 0-%zu, accessed %u\n", st.entries.length-1, soundIndex);

						if (TRACE1)
							printf("   soundIndex=%u <?>\n", soundIndex);
					}

					break;
				}

				case svc_updatestringtable:
				{
					uint    tableId        = buf.ReadUBitLong(5);
					uint    changedEntries = (buf.ReadOneBit())
					/**/                   ? buf.ReadWord()
					/**/                   : 1;
					uint    length         = buf.ReadUBitLong(20);

					scope sbuf = new bf_read(buf, length);

					StringTable* st = stringTables.get(tableId);
					assert(st);

					updateStringTable(sbuf, st, changedEntries, players, stringTables);

					assert(!sbuf.GetNumBitsLeft()); // bit array

					break;
				}

				case svc_usermessage:
				{
					enum NETMSG_LENGTH_BITS = 11;

					uint msgType = buf.ReadByte();
					uint length  = buf.ReadUBitLong(NETMSG_LENGTH_BITS);

					scope sbuf = new bf_read(buf, length);

					if (handleUserMessage(sbuf, msgType))
						assert(!sbuf.GetNumBitsLeft()); // bit array

					break;
				}

				case svc_voicedata:
				{
					uint    fromClient = buf.ReadByte();
					uint    proximity  = buf.ReadByte();
					uint    length     = buf.ReadWord();
					ubyte[] data       = buf.ReadDBitArray(length);

					// force: this might come after they disconnect, see 2022-07-31_05-55-35.dem
					Player* pl = players.getBySlotIndex(fromClient, /* force */ true);
					assert(pl);

					if (!pl.usedVoiceChat)
					{
						pl.usedVoiceChat = true;
						log("%s used voice chat", pl.ttyname);
					}

					if (TRACE1)
					{
						printf("   client=%u (%s)\n", fromClient, pl ? pl.ttyname : "?".ptr);
						printf("   proximity=%u\n", proximity);
						printf("   data=<%zu bytes>\n", data.length);
					}

					break;
				}

				case svc_fixangle:
				{
					uint  relative = buf.ReadOneBit();
					float x        = buf.ReadBitAngle(16);
					float y        = buf.ReadBitAngle(16);
					float z        = buf.ReadBitAngle(16);

					if (TRACE1)
					{
						printf("   relative=%s\n", relative ? "true".ptr : "false".ptr);
						printf("   x=%f\n", x);
						printf("   y=%f\n", y);
						printf("   z=%f\n", z);
					}

					break;
				}

				case svc_entitymessage:
				{
					enum MAX_EDICT_BITS = 11;
					enum MAX_SERVER_CLASS_BITS = 9;
					enum NETMSG_LENGTH_BITS = 11;

					uint    entindex = buf.ReadUBitLong(MAX_EDICT_BITS);
					uint    classid  = buf.ReadUBitLong(MAX_SERVER_CLASS_BITS);
					uint    length   = buf.ReadUBitLong(NETMSG_LENGTH_BITS);

					scope sbuf = new bf_read(buf, length);

					if (TRACE1)
					{
						printf("   entity=%u\n", entindex);
						printf("   class=%u (%s)\n", classid, demoreader.entitystuff.gameState.classes[classid].name.ptr);
						printf("   data=");
						sbuf.PrintBytes();
					}

					if (!demoreader.entitystuff.gameState.classes.length)
					{
						assert(isBrokenDemoMissingDataTables);
						break;
					}

					string classname = demoreader.entitystuff.gameState.classes[classid].name;

					// 2022-11-10_02-13-31_2.dem - bug or feature?
					if (!demoreader.entitystuff.gameState.entities[entindex])
					{
						//printf("-entity message for nonexistent entity %u (%s)\n", entindex, classname.ptr);
						break;
					}

					switch (classname)
					{
						case "CTFPlayer":
						{
							Player* pl = players.getByEntIndex(entindex);
							assert(pl);

							int type = sbuf.ReadByte();

							enum PLAY_PLAYER_JINGLE = 1;

							final switch (type)
							{
								// 2022-10-07_07-31-51.dem
								case PLAY_PLAYER_JINGLE:
									assert(!sbuf.GetNumBitsLeft());
									printf("-player used sound spray: %s\n", pl.ttyname);
									break;
							}

							break;
						}

						case "CBaseAnimating":
						{
							int type = sbuf.ReadByte();

							enum BASEENTITY_MSG_REMOVE_DECALS = 1;

							final switch (type)
							{
								// boring
								case BASEENTITY_MSG_REMOVE_DECALS:
									assert(!sbuf.GetNumBitsLeft());
									break;
							}

							break;
						}

						/*
						 * contracker?
						 * 
						 * 2022-11-10_02-13-31_2.dem
						 * 
						 * ah, is there a demo that has "* has completed a contract and received ____"
						 * one of those demos might have this in them too
						 * and doesn't that make a sound effect
						 * it might be this?
						 */
						case "CTFWearableCampaignItem":
						{
							int value = sbuf.ReadByte();

							auto ent = demoreader.entitystuff.gameState.entities[entindex];
							assert(ent);

							Player* owner;
							if (ent)
							{
								auto ownerent = ent.prop!int("m_hOwnerEntity", -1);
								owner = players.getByEntIndex(ownerent & 0x7ff);
							}

							//printf("-unknown CTFWearableCampaignItem entity message: value=%d m_nState=%d entindex=%d owner=%s\n",
							//	value,
							//	ent.prop!int("m_nState", -999),
							//	entindex,
							//	owner ? owner.ttyname : null
							//	);

							assert(!sbuf.GetNumBitsLeft());

							break;
						}

						// tr_walkway todo
						case "CTesla":
							break;

						default:
							printf("-unknown entity message: class=%s\n", classname.ptr);
							assert(0);
					}

					break;
				}

				case svc_print:
				{
					char[] text = buf.ReadDString();

					// server info thing
					if (text.length && text[0] == '\n')
					{
						enum buildColon = "\nBuild: ";
						size_t i = text.indexOf(buildColon);
						assert(i != -1);
						buildNumber = atoi(&text[i+buildColon.length]);
						assert(buildNumber);
						JsonOutput.setBuildNumber(buildNumber);

						if (g_htmlOut)
						{
							// trim, the hard way
							while (text.length && text[0] == '\n')
								text = text[1..$];
							while (text.length && text[$-1] == '\n')
							{
								text[$-1] = 0;
								text = text[0..$-1];
							}
							htmlSimpleRow("<pre>%s</pre>", htmlspecialchars(text).ptr);
						}
						else
							printf("%s", text.ptr);
					}
					else
					{
						enum printit = 1;
						enum recognized = 2;
						uint status;

						enum printping = 0;
						uint printstatus = !!TRACE1;

						if (0) {}

						// ping command output
						else if (text == "Client ping times:\n")
							status |= recognized|printping;
						else if (text.canFind(" ms : ") && text.endsWith('\n'))
							status |= recognized|printping;

						// status command output
						else if (
							text.startsWith("hostname: ") ||
							text.startsWith("version : ") ||
							text.startsWith("udp/ip  : ") ||
							text.startsWith("steamid : ") ||
							text.startsWith("account : ") ||
							text.startsWith("map     : ") ||
							text.startsWith("tags    : ") ||
							text.startsWith("players : ") ||
							text.startsWith("edicts  : "))
							status |= recognized|printstatus;
						else if (text.startsWith("# userid"))
							status |= recognized|printstatus;
						else if (text.startsWith("# ") && text.canFind("[U:1:"))
							status |= recognized|printstatus;

						if (isOfficialServer)
						{
							if (status & printit)
							{
								if (g_useColor)
									printf("\x1b[2m%.*s\x1b[0m", cast(int)text.length, text.ptr);
								else
									printf("%.*s", cast(int)text.length, text.ptr);
							}
						}
						else
						{
							// just print it, whatever
							// some plugin messages use this
							text = text.strip();
							log("%.*s", cast(int)text.length, text.ptr);
							break;
						}


						assert(status & recognized);
					}

					break;
				}

				case svc_createstringtable:
				{
					enum NET_MAX_PAYLOAD_BITS_V23 = 17;

					char[]  tableName         = buf.ReadDString();
					uint    maxEntries        = buf.ReadWord();
					uint    numEntries        = buf.ReadUBitLong(cast(int)log2(double(maxEntries))+1);
					uint    length            = (header.networkprotocol > 23)
					/**/                      ? buf.ReadVarInt32()
					/**/                      : buf.ReadUBitLong(NET_MAX_PAYLOAD_BITS_V23 + 3);
					uint    userDataFixedSize = buf.ReadOneBit();
					uint    userDataSize      = (userDataFixedSize)
					/**/                      ? buf.ReadUBitLong(12)
					/**/                      : 0;
					uint    userDataSizeBits  = (userDataFixedSize)
					/**/                      ? buf.ReadUBitLong(4)
					/**/                      : 0;
					uint    dataCompressed    = (header.networkprotocol > 14)
					/**/                      ? buf.ReadOneBit()
					/**/                      : false;
					ubyte[] data              = buf.ReadDBitArray(length);

					if (TRACE1)
					{
						printf("   name=%.*s\n", cast(int)tableName.length, tableName.ptr);
						printf("   maxEntries=%u\n", maxEntries);
						printf("   numEntries=%u\n", numEntries);
						printf("   length=%u\n", length);
						printf("   userDataFixedSize=%u\n", userDataFixedSize);
						printf("   userDataSizeBits=%u\n", userDataSizeBits);
						printf("   dataCompressed=%u\n", dataCompressed);
					}

					// wasn't already created
					assert(!stringTables.get(tableName));

					StringTable* st      = new StringTable();
					st.name              = tableName;
					st.maxEntries        = maxEntries;
					st.userDataFixedSize = !!userDataFixedSize;
					st.userDataSizeBits  = userDataSizeBits;
					stringTables.defs   ~= st;

					scope sbuf = new bf_read(data, length);

					if (dataCompressed)
					{
						uint    usize  = *cast(uint*)data[0..4].ptr; data = data[4..$];
						uint    csize  = *cast(uint*)data[0..4].ptr; data = data[4..$];
						char[4] method = *cast(char[4]*)data[0..4].ptr; data = data[4..$];

						if (method == "SNAP")
						{
							ubyte[] comp = data;
							ubyte[] decomp = uninitializedArray!(ubyte[])(usize);

							size_t decomplen = decomp.length;
							auto status = snappy_uncompress(
								comp.ptr, comp.length,
								decomp.ptr, &decomplen);
							assert(status == SNAPPY_OK, "string table decompression failed: library reported error");
							assert(decomplen == usize, "string table decompression failed: result has wrong length");

							sbuf.StartReading(decomp);
						}
						else if (method == "LZSS")
						{
							ubyte[] comp = data;
							ubyte[] decomp = uninitializedArray!(ubyte[])(usize);

							decomp = LZSS_Uncompress(comp, decomp);
							assert(decomp.length == usize);

							sbuf.StartReading(decomp);
						}
						else
						{
							assert(0, "unknown string table compression method '"~method~"'");
						}
					}

					readCreateStringTable(sbuf, st, numEntries, players, stringTables);

					break;
				}

				case net_file:
				{
					uint   transferId = buf.ReadUBitLong(32);
					char[] filename   = buf.ReadDString();
					uint   unk1       = buf.ReadOneBit(); // what was this?

					if (TRACE1)
					{
						printf("   id=%u\n", transferId);
						printf("   filename=%s\n", filename.ptr);
						printf("   (unknown)=%s\n", unk1 ? "true".ptr : "false".ptr);
					}

					break;
				}

				case net_stringcmd:
				{
					char[] command = buf.ReadDString();

					if (TRACE1)
						printf("   %s\n", command.strip.toStringz);

					switch (command)
					{
						case "cl_spec_mode 4":
						case "cl_spec_mode 5":
						case "cl_spec_mode 6":
						case "cl_spec_mode 7":
						case "dsp_player 0\n":
							break;
						default:
						{
							// map commands come here
							// point_servercommand or something
							if (mapName == "tr_walkway_rc2")
								break;

							debug log("net_stringcmd [%s]", command.ptr);
							assert(0);
						}
					}

					break;
				}

				case svc_bspdecal:
				{
					enum MAX_DECAL_INDEX_BITS = 9;
					enum MAX_EDICT_BITS = 11;
					enum SP_MODEL_INDEX_BITS = 13;

					Vector pos;                buf.ReadBitVec3Coord(pos);
					uint   decalTextureIndex = buf.ReadUBitLong(MAX_DECAL_INDEX_BITS);
					uint   unk1              = buf.ReadOneBit(); // any better name?
					uint   entityIndex       = (unk1)
					/**/                     ? buf.ReadUBitLong(MAX_EDICT_BITS)
					/**/                     : 0;
					uint   modelIndex        = (unk1)
					/**/                     ? buf.ReadUBitLong(SP_MODEL_INDEX_BITS)
					/**/                     : 0;
					uint   lowPriority       = buf.ReadOneBit();

					StringTable* st = stringTables.get("decalprecache");
					assert(st);

					const(char)[] textureName;
					if (decalTextureIndex < st.entries.length)
						textureName = st.entries[decalTextureIndex].name;

					if (TRACE1)
					{
						printf("   pos=(%f %f %f)\n", pos.x, pos.y, pos.x);

						if (textureName)
							printf("   texture=%u <%s>\n", decalTextureIndex, textureName.ptr);
						else
							printf("   texture=%u <?>\n", decalTextureIndex);

						if (unk1) printf("   entity=%u\n", entityIndex);
						if (unk1) printf("   model=%u\n", modelIndex);

						printf("   lowPriority=%s\n", lowPriority ? "true".ptr : "false".ptr);
					}

					break;
				}

				case net_signonstate:
				{
					uint state      = buf.ReadByte();
					int  spawnCount = buf.ReadLong();

					if (TRACE1)
					{
						printf("   state=%u\n", state);
						printf("   spawnCount=%d\n", spawnCount);
					}

					assert(state >= 1 && state <= 7);

					signonState = state;

					break;
				}

				case svc_setview:
				{
					enum MAX_EDICT_BITS = 11;

					uint entity = buf.ReadUBitLong(MAX_EDICT_BITS);

					if (TRACE1)
					{
						printf("   entity=%u\n", entity);
						if (entity >= 1 && entity <= players.maxPlayers)
						{
							if (Player* pl = players.getByEntIndex(entity))
								printf("   %s %s\n", pl.info.guid.ptr, pl.ttyname);
						}
					}

					// seems to be used with the local player only
					assert(entity == ownPlayerSlot+1);

					break;
				}

				/*
				 * net_setconvar
				 * https://nekz.me/dem/classes/netsvc/netsetconvar.html
				 * 
				 * see: NET_SetConVar::ReadFromBuffer in common/netmessages.cpp
				 */
				case net_setconvar:
				{
					uint numvars = buf.ReadByte();

					foreach (_; 0..numvars)
					{
						char[] name  = buf.ReadDString();
						char[] value = buf.ReadDString();

						if (TRACE1)
							printf("   %s \"%s\"\n", name.ptr, value.ptr);
					}

					break;
				}

				/*
				 * svc_classinfo
				 * https://nekz.me/dem/classes/netsvc/svcclassinfo.html
				 * 
				 * see: SVC_ClassInfo::ReadFromBuffer in common/netmessages.cpp
				 */
				case svc_classinfo:
				{
					uint numServerClasses = buf.ReadShort();
					uint createOnClient   = buf.ReadOneBit();

					if (TRACE1)
					{
						printf("   numServerClasses=%u\n", numServerClasses);
						printf("   createOnClient=%s\n", createOnClient ? "true".ptr : "false".ptr);
					}

					if (createOnClient)
					{
						// nothing to do here
					}
					else
					{
						assert(0, "unimplemented");
					}

					break;
				}

				/*
				 * svc_gameeventlist
				 * https://nekz.me/dem/classes/netsvc/svcgameeventlist.html
				 * 
				 * see: SVC_GameEventList::ReadFromBuffer in common/netmessages.cpp
				 */
				case svc_gameeventlist:
				{
					enum MAX_EVENT_BITS = 9;

					uint    numEvents = buf.ReadUBitLong(MAX_EVENT_BITS);
					uint    length    = buf.ReadUBitLong(20);
					ubyte[] data      = buf.ReadDBitArray(length);

					handleGameEventList(data);

					assert(gameEvents.defs.length == numEvents);

					break;
				}

				/*
				 * svc_serverinfo
				 * https://nekz.me/dem/classes/netsvc/svcserverinfo.html
				 * 
				 * see: SVC_ServerInfo::ReadFromBuffer in common/netmessages.cpp
				 */
				case svc_serverinfo:
				{
					enum MD5_DIGEST_LENGTH = 16;

					uint    protocol     = buf.ReadShort();
					uint    serverCount  = buf.ReadLong();
					uint    isHltv       = buf.ReadOneBit();
					uint    isDedicated  = buf.ReadOneBit();
					uint    clientCrc    = buf.ReadLong();
					uint    maxClasses   = buf.ReadWord();
					ubyte[] mapMd5       = buf.ReadDByteArray(MD5_DIGEST_LENGTH);
					uint    playerSlot   = buf.ReadByte();
					uint    maxClients   = buf.ReadByte();
					float   tickInterval = buf.ReadBitFloat();
					uint    os           = buf.ReadChar();
					char[]  gameDir      = buf.ReadDString();
					char[]  mapName      = buf.ReadDString();
					char[]  skyName      = buf.ReadDString();
					char[]  hostName     = buf.ReadDString();
					uint    isReplay     = buf.ReadOneBit();

					if (TRACE1)
					{
						printf("   protocol=%u\n",     protocol);
						printf("   serverCount=%u\n",  serverCount);
						printf("   isHltv=%u\n",       isHltv);
						printf("   isDedicated=%u\n",  isDedicated);
						printf("   clientCrc=%08x\n",  clientCrc);
						printf("   maxClasses=%u\n",   maxClasses);
						//printf("   mapMd5=%llx %llx\n", *cast(ulong*)mapMd5.ptr, *cast(ulong*)(mapMd5.ptr + 8));
						// uh, what's the right byte order for printing this?
						// (can't verify because it doesn't seem to match my map files. maybe it's a hash of something else)
						printf("   mapMd5=");
						foreach (b; mapMd5)
							printf("%02x", b);
						putchar('\n');
						printf("   playerSlot=%u\n",   playerSlot);
						printf("   maxClients=%u\n",   maxClients);
						printf("   tickInterval=%f\n", tickInterval);
						printf("   os=%c\n",           os);
						printf("   gameDir=%s\n",      gameDir.ptr);
						printf("   mapName=%s\n",      mapName.ptr);
						printf("   skyName=%s\n",      skyName.ptr);
						printf("   hostName=%s\n",     hostName.ptr);
						printf("   isReplay=%u\n",     isReplay);
					}

					ownPlayerSlot = playerSlot;
					assert(playerSlot >= 0 && ownPlayerSlot < maxClients);

					players.createSlots(maxClients);

					JsonOutput.setMapName(mapName);

					JsonOutput.setServerDedicated(!!isDedicated);
					JsonOutput.setServerName(hostName);
					JsonOutput.setServerNumber(serverCount);
					JsonOutput.setServerOs(cast(char)os);

					isOfficialServer = hostName.canFind("Valve");

					// note: casual and comp ones seem to be named the same
					// comp screenshot from 2016: https://i.imgur.com/qs8HFl4.jpg
					isMatchMakingGame = hostName.canFind("Valve Matchmaking Server");

					if (!isDedicated)
					{
						// my demos have "localhost" here, also check 127.* for good measure
						// concern: won't catch 192.168.*.* with your LAN IP (but does that happen?)
						// also, i suspect it might be looking up some address to get
						//  "localhost" here - meaning the name might not always be "localhost"
						isLocalListenServer =
							header.servername.fromStringz.startsWith("localhost:") ||
							header.servername.fromStringz.startsWith("127.");
					}

					if (!isOfficialServer)
					{
						serverNeedsForcedImpliedTeamsWorkaround =
							hostName.canFind("jumpacademy.tf") ||
							hostName.canFind("skial.com") ||
							hostName.canFind("Panda-Community.com") || // 2022-09-25_22-17-33.dem
							false;
						if (serverNeedsForcedImpliedTeamsWorkaround)
							printf("-workaround: forcing implicit team changes\n");
					}

					// known values for valve servers
					if (isOfficialServer)
					{
						assert(protocol == PROTOCOL_VERSION);
						assert(serverCount >= 1);
						assert(!isHltv);
						assert(isDedicated);
						assert(clientCrc == -1);
						//if (buildNumber > 4193938)
						//	assert(maxClasses == 362);
						assert(playerSlot < maxClients);
						assert(maxClients == 32);
						assert(tickInterval is 0.015f);
						assert(os == 'l');
						assert(gameDir == "tf");
						assert(mapName);
						assert(skyName);
						assert(hostName);
						assert(!isReplay);
					}

					break;
				}

				/*
				 * svc_voiceinit
				 * https://nekz.me/dem/classes/netsvc/svcvoiceinit.html
				 * 
				 * see: SVC_VoiceInit::ReadFromBuffer in common/netmessages.cpp
				 */
				case svc_voiceinit:
				{
					char[] codec         = buf.ReadDString();
					uint   legacyQuality = buf.ReadByte();
					uint   sampleRate    = (legacyQuality == 255)
					/**/                 ? buf.ReadShort()
					/**/                 : 0;

					if (TRACE1)
					{
						printf("   codec=%s\n", codec.ptr);
						printf("   quality=%u\n", legacyQuality);
						if (legacyQuality == 255)
							printf("   rate=%u\n", sampleRate);
					}

					break;
				}

				/*
				 * svc_getcvarvalue
				 * https://nekz.me/dem/classes/netsvc/svcgetcvarvalue.html
				 * 
				 * valve servers don't use this, but some skial demos have it
				 * 
				 * used by SMAC ConVar Checker
				 * https://github.com/Silenci0/SMAC/blob/master/addons/sourcemod/scripting/smac_cvars.sp
				 */
				case svc_getcvarvalue:
				{
					uint   cookie   = buf.ReadUBitLong(32);
					char[] cvarname = buf.ReadDString();

					if (TRACE1)
					{
						printf("   cookie=%08x\n", cookie);
						printf("   cvar=%s\n", cvarname.ptr);
					}

					assert(!isOfficialServer); // not used on valve servers

					break;
				}
			}
		}

		assert(!buf.GetNumBytesLeft()); // byte-aligned
	}

	void handleConsoleCmd(ubyte[] data)
	{
		// size includes null byte
		assert(data[$-1] == 0);
		data = data[0..$-1];

		// CFGFS(tm) reliable print protocol
		if (data.startsWith("echo\"") && data.endsWith('\x7f'))
		{
			data = data[5..$-1];
			if (g_useColor)
				printf("\x1b[2m%.*s\x1b[0m\n", cast(int)data.length, data.ptr);
			else
				printf("%.*s\n", cast(int)data.length, data.ptr);
		}
		else
		{
			/*
			 * too much to print it all
			 * 
			 * includes
			 * - some (sound-related) cvars set at startup
			 * - commands executed by the game UI
			 * - contents of configs
			 * - contents of all pressed keybinds
			 */

			//printf("ConsoleCmd %.*s\n", cast(int)data.length, data.ptr);

			if (TRACE1)
				printf("  %.*s\n", cast(int)data.length, data.ptr);
		}
	}

	void handleDataTables(ubyte[] data)
	{
		scope buf = new bf_read(data);
		demoreader.entitystuff.parseDataTables(buf, stringTables);
		assert(!buf.GetNumBytesLeft()); // byte-aligned
	}

	void handleStringTables(ubyte[] data)
	{
		scope buf = new bf_read(data);

		readDemoStringTables(buf, players, stringTables);

		assert(!buf.GetNumBytesLeft()); // byte-aligned
	}

	bool handleUserMessage(bf_read msgbuf, uint msgType)
	{
		if (TRACE1)
			printf("   %s <%u>\n", userMessageToString[cast(UserMessage)msgType].ptr, msgType);

		if (TRACE1)
		{
			printf("    ");
			msgbuf.PrintBytes();
		}

		/+
		 . 20406 * VoiceSubtitle
		 . 12702   VGUIMenu
		 . 10610 * SayText2
		 . 10511   Damage
		 .  9493   MVMResetPlayerStats
		 .  7974   HudNotify
		 .  7803 * TextMsg
		 .  7436   Rumble
		 .  4568   VoiceMask
		 .  2929   ResetHUD
		 .  2929   Train
		 .  2786   PlayerLoadoutUpdated
		 .  2336   Fade
		 .  2105   AchievementEvent
		 .  1859   Geiger
		 .  1856   PlayerTauntSoundLoopStart
		 .  1770   PlayerTauntSoundLoopEnd
		 .  1507 * CallVoteFailed
		 .  1439   MapStatsUpdate
		 .  1439   PlayerStatsUpdate
		 .  1391   Shake
		 .  1153   CheapBreakModel
		 .   788   ItemPickup
		 .   632 * VoteStart
		 .   573   PlayerIgnited
		 .   387 * VotePass
		 .   245 * VoteFailed
		 .   231   BreakModel
		 .   117   PlayerExtinguished
		 .   114   PlayerTeleportHomeEffect
		 .    65   SpawnFlyingBird
		 .    51   PlayerJarated
		 .    41   PlayerPickupWeapon
		 .    34   RequestState
		 .    32   PlayerJaratedFade
		 .    28   PlayerBonusPoints
		 .    25   UpdateAchievement
		 .    20   VoteSetup
		 .    12   HudNotifyCustom
		 .     4   PlayerGodRayEffect
		 .     1   PlayerShieldBlocked
		 +/

		bool parsed = true;

		switch (msgType)
		{
			case UserMessage.VoiceSubtitle:
			{
				uint client = msgbuf.ReadByte();
				uint menu   = msgbuf.ReadByte();
				uint item   = msgbuf.ReadByte();

				Player* pl = players.getByEntIndex(client);
				assert(pl);
				//pl.onSpawnedActivity(); // might be a spy?

				// why does this happen?
				// sometimes we get voice commands from the enemy team
				Player* localPlayer = players.getBySlotIndex(ownPlayerSlot);
				assert(localPlayer);
				if (pl.team && localPlayer.team && pl.team != localPlayer.team)
				{
					//printf("-enemy voice command\n");
				}

				string msg;
				switch (menu*10 + item)
				{
					case  0: msg = "MEDIC!";           break;
					case  1: msg = "Thanks!";          break;
					case  2: msg = "Go Go Go!";        break;
					case  3: msg = "Move Up!";         break;
					case  4: msg = "Go Left!";         break;
					case  5: msg = "Go Right!";        break;
					case  6: msg = "Yes";              break;
					case  7: msg = "No";               break;
					case 10: msg = "Incoming";         break;
					case 11: msg = "Spy!";             break;
					case 12: msg = "Sentry Ahead!";    break;
					case 16: msg = "Activate Charge!"; break;
					case 20: msg = "Help!";            break;
					default:
						break;
				}

				if (msg)
				{
					if (g_htmlOut)
						htmlSimpleRow(
							"<span data-team=\"%s\">(Voice)</span>"~
							" %s"~
							"<nobr style=\"white-space: pre;\"> :  </nobr>"~
							"<span class=\"saytext\">%s</span>",
							playerToTeamName(pl).ptr,
							htmlPlayerName(pl).ptr,
							htmlspecialchars(msg).ptr,
							);
					else
						log("%s %s: %s", "(Voice)".teamcolorize(pl.team), pl.ttyname, msg.ptr.teamcolorize);
				}

				break;
			}

			/*
			 * see: CHudChat::MsgFunc_SayText2 in game/client/hud_chat.cpp
			 * see: CBaseHudChat::MsgFunc_SayText2 in game/client/hud_basechat.cpp
			 */
			case UserMessage.SayText2:
			{
				uint   client      = msgbuf.ReadByte(); // 1-based player slot
				uint   wantsToChat = msgbuf.ReadByte(); // (always 1?)
				char[] channel     = msgbuf.ReadDString(); // TF_Chat_*
				if (!msgbuf.GetNumBitsLeft()) // print thing on modded servers
				{
					char[] text = channel;

					assert(!isOfficialServer);
					assert(wantsToChat == 0 || wantsToChat == 1); // ?

					// client is valid
					// "system" messages have the local player here
					Player* pl = players.getByEntIndex(client);
					assert(pl);

					logStamp();
					if (g_htmlOut)
						htmlSimpleRow("<b dir=\"auto\" lang>%s</b>", htmlSourceModColoredText(text).ptr);
					else
						printSourceModColoredText(text);
					putchar('\n');

					break;
				}
				char[] user        = msgbuf.ReadDString();
				char[] text        = msgbuf.ReadDString();
				char[] l1          = msgbuf.ReadDString(); // (always empty?)
				char[] l2          = msgbuf.ReadDString(); // (always empty?)

				// force: fix demos/2022-07-21_18-16-42.dem
				Player* pl = players.getByEntIndex(client, /* force */ true);
				assert(pl);

				if (channel.canFind("Spec"))
					pl.impliedTeam(1, /* force */ serverNeedsForcedImpliedTeamsWorkaround);

				// fixme: properly support
				if (channel == "#TF_Name_Change")
					break;
				if (channel == "#TF_Halloween_Underworld")
					break;
				if (channel == "#TF_Halloween_Loot_Island")
					break;
				if (channel == "#TF_Halloween_Skull_Island_Escape")
					break;
				if (channel == "#TF_Halloween_Merasmus_Killers")
					break;
				if (channel == "#TF_Halloween_Boss_Killers")
					break;

				switch (channel)
				{
					case "TF_Chat_All":
					case "TF_Chat_AllDead":
					case "TF_Chat_Team":
					case "TF_Chat_Team_Dead":
						break;
					case "TF_Chat_AllSpec":
					case "TF_Chat_Spec":
						assert(serverAllowsSpectators);
						break;
					default:
						debug printf("bad channel: [%s]\n", channel.ptr);
						assert(0);
				}
				assert(wantsToChat == 1);
				assert(pl.nameEquals(user));
				assert(l1 is null);
				assert(l2 is null);

				if (g_htmlOut)
				{
					bool printed;

					htmlBeginRow();

					if (channel.canFind("Dead"))
					{
						fprintf(g_htmlOut, "<span class=\"chatchannel\">*DEAD*</span>");
						printed = true;
					}
					if (channel.canFind("Spec"))
					{
						fprintf(g_htmlOut, "<span class=\"chatchannel\">*SPEC*</span>");
						printed = true;
					}
					if (channel.canFind("Team"))
					{
						fprintf(g_htmlOut, "<span class=\"chatchannel\">(TEAM)</span>");
						printed = true;
					}
					if (printed)
						fprintf(g_htmlOut, " ");

					fprintf(g_htmlOut,
						"%s"~
						"<nobr style=\"white-space: pre;\"> :  </nobr>"~
						"<span class=\"saytext\">%s</span>",
						htmlPlayerName(pl).ptr,
						htmlUserText(text).ptr,
						);

					htmlEndRow();
				}
				else
				{
					logStamp();

					bool sp;
					if (channel.canFind("Dead"))
						{ printf("%s", "*DEAD*".teamcolorize); sp = true; }
					if (channel.canFind("Spec"))
						{ printf("%s", "*SPEC*".teamcolorize); sp = true; }
					if (channel.canFind("Team"))
						{ printf("%s", "(TEAM)".teamcolorize); sp = true; }
					if (sp)
						printf(" ");

					printf("%s :  %s\n", pl.ttyname, text.ptr.teamcolorize);
				}

				switch (channel)
				{
					// not dead
					case "TF_Chat_All":
					case "TF_Chat_Team":
						if (!pl.hasDisconnected)
							pl.onSpawnedActivity();
						break;
					default:
						break;
				}

				break;
			}

			/*
			 * see: CHudChat::MsgFunc_TextMsg in game/client/hud_chat.cpp
			 * see: CBaseHudChat::MsgFunc_TextMsg in game/client/hud_basechat.cpp
			 * see: CHudChat::MsgFunc_TextMsg in game/client/sdk/sdk_hud_chat.cpp
			 */
			case UserMessage.TextMsg:
			{
				enum Dest
				{
					notify = 1,  // ?
					console = 2, // console (duh)
					talk = 3,    // chat
					center = 4,  // ?
				}
				uint   msgDest = msgbuf.ReadByte();

				char[] msgText;
				char[] arg1;
				char[] arg2;
				char[] arg3;
				char[] arg4;

				if (buildNumber <= 4769)
				{
					// fixme: what were these two bytes?
					msgbuf.ReadByte();
					msgbuf.ReadByte();
					msgText = msgbuf.ReadDString();
				}
				else
				{
					msgText = msgbuf.ReadDString();
					arg1    = msgbuf.ReadDString();
					arg2    = msgbuf.ReadDString();
					arg3    = msgbuf.ReadDString();
					arg4    = msgbuf.ReadDString();
				}

				switch (msgText)
				{
					/*
					 * note: this is the console message, it comes after the
					 *  "<name> has joined the game" chat message
					 */
					case "#Game_connected":
					{
						// force: fix 2022-07-24_15-50-15.dem
						// this might come after userinfo is removed if they're being kicked
						Player* pl = players.getByName(arg1, /* force */ true);
						if (isOfficialServer)
							assert(pl);
						if (!pl) // skial/sus.dem
							printf("-no userinfo for connecting player %s\n", arg1.ptr.teamcolorize);
						log("%s connected", pl ? pl.ttyname : arg1.ptr.teamcolorize);
						break;
					}

					case "#game_idle_kick":
					{
						// force: fix 2022-07-18_18-04-16.dem
						Player* pl = players.getByName(arg1, /* force */ true);
						assert(pl);
						if (g_htmlOut)
							htmlSimpleRow(
								"%s has been idle for too long and has been kicked",
								htmlPlayerName(pl).ptr,
								);
						else
							log("%s has been idle for too long and has been kicked", pl.ttyname);
						break;
					}

					case "#game_player_was_team_balanced":
					{
						Player* pl = players.getByName(arg1);
						assert(pl);
						if (g_htmlOut)
							htmlSimpleRow(
								"%s was moved to the other team for game balance",
								htmlPlayerName(pl).ptr,
								);
						else
							log("%s was moved to the other team for game balance", pl.ttyname);
						break;
					}

					case "#game_respawn_as":
					case "#game_spawn_as":
					case "#GameUI_vote_failed_vote_in_progress":
					case "#Spectator_Mode_Unknown":
					case "#TF_Autobalance_TeamChangeDone_Match":
					case "#TF_Autobalance_TeamChangePending":
					case "#TF_HALLOWEEN_BOSS_ANNOUNCE_TAG":
					case "#TF_HALLOWEEN_BOSS_LOST_AGGRO":
					case "#TF_HALLOWEEN_BOSS_WARN_VICTIM":
					case "#TF_HALLOWEEN_MERASMUS_YOU_ARE_BOMB":
					case "#TF_Ladder_NoTeamChange":
					case "#TF_TeamsSwitched":
						break;

					case "#TF_Competitive_GameOver":
						log("Game will end in %s seconds. It is safe to leave.", arg1.ptr);
						break;

					case "noclip OFF\n":
					case "noclip ON\n":
						break;

					case "":
					{
						// ignore empty messages from server plugins
						if (arg1 is null && arg2 is null && arg3 is null && arg4 is null)
							break;

						goto default;
					}

					default:
					{
						if (msgDest == Dest.console)
						{
							if (msgText.startsWith("Unknown command: ") && msgText.endsWith('\n'))
								break;

							if (msgText.canFind(" vel ")) // playerperf output
								break;
							if (msgText.endsWith(" 0\n")) // playerperf output
								break;
						}

						if (isOfficialServer)
						{
							fprintf(stderr, "-unknown TextMsg: [%s]\n", msgText.ptr);
							assert(0);
						}
						else
						{
							// plugin messages use this
							foreach (line; msgText.lineSplitter)
							{
								if (msgDest == Dest.talk)
								{
									if (g_htmlOut)
										htmlSimpleRow("<b dir=\"auto\" lang>%s</b>", htmlSourceModColoredText(line).ptr);
									else
									{
										logStamp();
										printSourceModColoredText(line);
										putchar('\n');
									}
								}
								else
								{
									log("%.*s", cast(int)line.length, line.ptr);
								}
							}
						}

						break;
					}
				}

				break;
			}

			/*
			 * see: CHudVote::MsgFunc_CallVoteFailed in game/client/hud_vote.cpp
			 * 
			 * reason:
			 *   2  = rate exceeded
			 *   11 = player not found
			 *   22 = vote already running
			 * 
			 * time = cooldown, seconds until you can vote again (if reason=2)
			 */
			case UserMessage.CallVoteFailed:
			{
				uint reason = msgbuf.ReadByte();
				uint time   = msgbuf.ReadShort();

				//log("svc_usermessage CallVoteFailed reason=%hhu time=%hd",
				//	reason, time);

				break;
			}

			/*
			 * see: CHudVote::MsgFunc_VoteStart in game/client/hud_vote.cpp
			 * see: CVoteController::CreateVote in game/server/vote_controller.cpp
			 */
			case UserMessage.VoteStart:
			{
				if (!msgbuf.GetNumBitsLeft())
					break;

				uint   voteTeamIndex = msgbuf.ReadByte();
				int    voteIndex     = (buildNumber > 7182415)
				/**/                 ? msgbuf.ReadLong()
				/**/                 : 0;
				uint   caller        = msgbuf.ReadByte();
				char[] issue         = msgbuf.ReadDString();
				char[] param1        = msgbuf.ReadDString();
				uint   unk2          = msgbuf.ReadOneBit();
				uint   targetEntIdx  = msgbuf.GetNumBitsLeft() ? msgbuf.ReadByte() : 0;

				Player* issuer;
				if (caller >= 1 && caller < 1+32)
				{
					issuer = players.getByEntIndex(caller);
					assert(issuer);
					issuer.onSpawnedActivity();
				}

				Player* target;
				if (targetEntIdx)
				{
					target = players.getByEntIndex(targetEntIdx);
					assert(target);
					assert(target.nameEquals(param1));
					target.onSpawnedActivity();
				}

				if (issuer && target)
					players.impliedSameTeam(issuer, target);

				switch (issue)
				{
					case "#TF_vote_kick_player_cheating":
					case "#TF_vote_kick_player_idle":
					case "#TF_vote_kick_player_other":
					case "#TF_vote_kick_player_scamming":
					{
						assert(issuer && target);
						if (g_htmlOut)
							htmlSimpleRow(
								"<strong>Vote:</strong> %s wants to kick %s with reason: %s",
								htmlPlayerName(issuer).ptr,
								htmlPlayerName(target).ptr,
								htmlspecialchars(issue).ptr,
								);
						else
							log("Vote: %s wants to kick %s with reason: %s",
								issuer.ttyname,
								target.ttyname,
								issue.ptr,
								);
						break;
					}

					case "#TF_playerid_noteam": // huh? what was this (FIXME)
					{
						log("Vote: %s",
							param1.ptr,
							);
						break;
					}

					case "#TF_vote_nextlevel_choices":
					{
						assert(param1 is null);
						log("Vote: %s",
							issue.ptr,
							);
						break;
					}

					case "#TF_vote_eternaween":
					{
						assert(param1 is null);
						log("Vote: %s",
							issue.ptr,
							);
						break;
					}

					default:
					{
						debug fprintf(stderr, "unknown vote issue: %s\n", issue.ptr);
						assert(0, "unknown vote issue");
					}
				}

				break;
			}

			/*
			 * see: CHudVote::MsgFunc_VotePass in game/client/hud_vote.cpp
			 */
			case UserMessage.VotePass:
			{
				uint    voteTeamIndex = msgbuf.ReadByte();
				int     voteIndex     = (buildNumber > 7182415)
				/**/                  ? msgbuf.ReadLong()
				/**/                  : 0;
				uint    unk1          = msgbuf.ReadByte(); // always 0x23?
				char[]  result        = msgbuf.ReadDString();
				char[]  detail        = msgbuf.ReadDString();

				switch (result)
				{
					case "TF_vote_passed_nextlevel":
					{
						char[] mapName = detail;
						log("Vote: Vote finished, next map: %s", mapName.ptr);
						break;
					}

					case "TF_vote_passed_ban_player":
					{
						char[] playerName = detail;
						Player* pl = players.getByName(playerName, /* force */ true);
						if (g_htmlOut)
							htmlSimpleRow(
								"<strong>Vote:</strong> Vote passed, banning player: %s",
								pl ? htmlPlayerName(pl).ptr : htmlUserText(playerName).ptr,
								);
						else
							log("Vote: Vote passed, banning player: %s", pl ? pl.ttyname : playerName.ptr.teamcolorize);
						break;
					}

					// huh? 2022-11-16_01-25-23_2.dem
					// item server was down, maybe it failed to ban them because of that?
					case "TF_vote_passed_kick_player":
					{
						char[] playerName = detail;
						Player* pl = players.getByName(playerName, /* force */ true);
						if (g_htmlOut)
							htmlSimpleRow(
								"<strong>Vote:</strong> Vote passed, kicking player: %s",
								pl ? htmlPlayerName(pl).ptr : htmlUserText(playerName).ptr,
								);
						else
							log("Vote: Vote passed, kicking player: %s", pl ? pl.ttyname : playerName.ptr.teamcolorize);
						break;
					}

					case "TF_vote_passed_eternaween":
					{
						assert(detail is null);
						log("Vote: #TF_vote_passed_eternaween");
						break;
					}

					default:
						debug
						{
							printf("result=%s\n", result.ptr);
							printf("detail=%s\n", detail.ptr);
						}
						assert(0, "unknown vote result");
						
				}

				votes.remove(voteIndex);

				assert(unk1 == 0x23);

				break;
			}

			/*
			 * see: CHudVote::MsgFunc_VoteFailed in game/client/hud_vote.cpp
			 */
			case UserMessage.VoteFailed:
			{
				uint voteTeamIndex = msgbuf.ReadByte();
				int  voteIndex     = (buildNumber > 7182415)
				/**/               ? msgbuf.ReadLong()
				/**/               : 0;
				uint reason        = msgbuf.ReadByte();

				// ?
				if (voteTeamIndex == 0 && reason == 0)
					break;

				if (g_htmlOut)
					htmlSimpleRow("<strong>Vote:</strong> Vote failed");
				else
					log("Vote: Vote failed");

				votes.remove(voteIndex);

				assert(voteTeamIndex == 0 || voteTeamIndex == 2 || voteTeamIndex == 3);
				assert(reason == 3);

				break;
			}

			default:
			{
				parsed = false;
				break;
			}
		}

		return parsed;
	}

	/**
	 * game eventz
	 * 
	 * http://wiki.sourcepython.com/developing/events/tf.html
	 * https://wiki.alliedmods.net/Team_Fortress_2_Events
	 * 
	 * returns true if the event was fully parsed
	 */
	bool handleGameEvent(bf_read evbuf)
	{
		if (!gameEvents.defs.length)
		{
			if (!tryLoadGameEventListFromDisk())
			{
				printf("-got an early GameEvent but have no definitions saved for game build %d\n", buildNumber);
				return false;
			}
		}

		GameEvent* ge = gameEvents.get(evbuf.ReadUBitLong(9));
		assert(ge);

		auto args = ge.parse(evbuf);

		if (TRACE1)
		{
			printf("   %s\n", ge.name.ptr);
			foreach (p; ge.params)
			{
				alias Param = GameEventParam;
				final switch (p.type)
				{
					case Param.Type.String:
						printf("    %s=%s\n", p.name.ptr, args.get!(char[])(p.name, gameEvents).ptr);
						break;
					case Param.Type.Float:
						printf("    %s=%f\n", p.name.ptr, args.get!float(p.name, gameEvents));
						break;
					case Param.Type.Long:
						printf("    %s=%d\n", p.name.ptr, args.get!int(p.name, gameEvents));
						break;
					case Param.Type.Short:
						printf("    %s=%d\n", p.name.ptr, args.get!short(p.name, gameEvents));
						break;
					case Param.Type.Byte:
						printf("    %s=%u\n", p.name.ptr, args.get!ubyte(p.name, gameEvents));
						break;
					case Param.Type.Bool:
						printf("    %s=%s\n", p.name.ptr, args.get!bool(p.name, gameEvents) ? "true".ptr : "false".ptr);
						break;
				}
			}
		}

		switch (ge.name)
		{
			case "achievement_earned":
			{
				int  achievement = args.get!short("achievement", gameEvents);
				uint player      = args.get!ubyte("player", gameEvents);

				Player* pl = players.getByEntIndex(player);
				assert(pl);
				log("%s earned achievement %d", pl.ttyname, achievement);

				/*
				 * https://github.com/nullworks/cathook/blob/master/src/hooks/SendNetMsg.cpp
				 * 
				 * (doesn't actually work)
				 */
				assert(achievement != 0xca7);
				assert(achievement != 0xca8);

				break;
			}

			// sadly patched but 2021-01-11_11-12-40.dem has a player do this
			// https://github.com/nullworks/cathook/blob/285e22a/src/hooks/SendNetMsg.cpp#L36
			case "cl_drawline":
			{
				uint  line   = args.get!ubyte("line", gameEvents);
				uint  panel  = args.get!ubyte("panel", gameEvents);
				uint  player = args.get!ubyte("player", gameEvents);
				float x      = args.get!float("x", gameEvents);
				float y      = args.get!float("y", gameEvents);

				assert(line == 0);
				assert(panel == 2);
				assert(x == 0xca7);
				assert(y == 1234567);

				Player* pl = players.getByEntIndex(player);
				assert(pl);
				printf("-player used cl_drawline: %s\n", pl.ttyname);

				break;
			}

			case "ctf_flag_captured":
			{
				int team = args.get!short("capping_team", gameEvents);

				string teamname =
					team == 2 ? "RED" :
					team == 3 ? "BLU" :
					null;

				assert(teamname);

				log("%s has CAPTURED the intelligence!", teamname.ptr);

				break;
			}

			/*
			 * fired when the player decides they're a different class, but
			 *  possibly before they spawn as it
			 */
			case "player_changeclass":
			{
				int class_ = args.get!short("class", gameEvents);
				int userid = args.get!short("userid", gameEvents);

				static immutable classNames = [
					null,
					"scout",
					"sniper",
					"soldier",
					"demoman",
					"medic",
					"heavy",
					"pyro",
					"spy",
					"engineer",
				];
				assert(class_ >= 1 && class_ < classNames.length);

				// force: this might come after they disconnect for "Processing time exceeded"
				// see 2022-07-24_21-23-50.dem
				Player* pl = players.getByUserId(userid, /* force */ true);
				//assert(pl);
				if (pl) // fixme: 2022-10-10_16-45-07.dem
				{
					log("%s changed class to %s", pl.ttyname, classNames[class_].ptr);
					if (!pl.hasDisconnected)
						pl.onSpawnedActivity();
				}

				break;
			}

			case "teamplay_flag_event":
			{
				int type   = args.get!short("eventtype", gameEvents);
				int player = args.get!short("player", gameEvents);

				enum
				{
					captured = 2,
				}

				Player* pl = players.getByEntIndex(player);

				if (g_htmlOut)
				if (pl && type == captured)
					htmlSimpleRow("<strong>%s has CAPTURED the intelligence!</strong>", htmlPlayerName(pl).ptr);

				break;
			}

			case "teamplay_round_active":
			{
				// teamplay_round_start: players teleported to spawn and frozen, countdown starts
				// ^ might happen more than once if the countdown resets

				// teamplay_round_active: round officially started

				if (g_htmlOut)
					htmlSimpleRow("--- Round Start ---");

				break;
			}

			case "teamplay_game_over":
			{
				if (g_htmlOut)
					htmlSimpleRow("--- Game Over ---");

				break;
			}

			/*
			 * "joined the game" message in the chat, the first (visible) sign
			 *  that a player is connecting
			 */
			case "player_connect_client":
			{
				char[] name      = args.get!(char[])("name", gameEvents);
				uint   index     = args.get!ubyte("index", gameEvents);
				int    userid    = args.get!short("userid", gameEvents);
				char[] networkid = args.get!(char[])("networkid", gameEvents);

				/*
				 * note: this is the chat message, it comes before the
				 *  "<name> connected" console message
				 * 
				 * this event comes before userinfo about 90% of the time
				 */

				/*
				 * slot already filled? (could be another player)
				 * 
				 * force: get the slot even if the player is disconnected
				 */
				if (Player* pl = players.getBySlotIndex(index, /* force */ true))
				{
					bool sameUserId = (pl.info.userID == userid);
					bool sameSteamId = pl.steamIdEquals(networkid);

					if (sameUserId)
					{
						// ok, already got the userinfo update
						// check that these match the join message
						assert(pl.nameEquals(name));
						assert(sameSteamId);

						/*
						 * userid can't have disconnected yet
						 * 
						 * this had to be assigned here in the past,
						 *  but it seems to work without now
						 *  (probably fixed it somewhere else)
						 */
						/// old comment:
						/*
						 * if the struct was already created/updated, make
						 *  sure it's marked as non-disconnected
						 * 
						 * demo 2022-07-18_18-04-16.dem has this funny sequence:
						 * 
						 * 1. "joined the game" message
						 * 2. userinfo created normally
						 * (connection hiccup!)
						 * 3. userinfo is updated to only change the userid
						 * 4. "left the game" message (connection closing)
						 * 5. "joined the game" message
						 * 6. ("connected" message, player enters game)
						 * 
						 * here 3. creates the userinfo and 4. marks it as
						 *  disconnected. to fix this, 5. (you are here)
						 *  needs to mark it as non-disconnected again
						 * 
						 * another instance of it: 2022-07-24_16-14-16.dem
						 */
						//assert(!pl.hasDisconnected);
						//if (pl.hasDisconnected)
						//	printf("-cut here\n");
						pl.hasDisconnected = false;
						// ^ fixme: 2022-10-27_12-00-03_2.dem -> tick 35255
						// (3)name has joined the game
						// (3)name left the game (Client Disconnect)
						// commented out the assert and uncommented the old fix, but does it make sense?
					}
					else
					{
						// 1. corpse of a disconnected user
						// 2. corpse of this user before they reconnected
						// compare steamid to find out which it is
						if (sameSteamId)
						{
							// same steamid, so they're probably reconnecting
							// make sure the old one is marked as disconnected
							pl.setDisconnected(Player.DisconnectReason.reconnectMessage);
						}
						players.createForConnectingUser(name, index, userid, networkid);
					}
				}
				else
				{
					// ok, slot has no player in it yet
					players.createForConnectingUser(name, index, userid, networkid);
				}
				debug players.check(); // consistency

				// it's created now
				Player* pl = players.getBySlotIndex(index);
				assert(pl);
				assert(pl.info.userID == userid);

				if (g_htmlOut)
					htmlSimpleRow("%s has joined the game", htmlPlayerName(pl).ptr);
				else
					log("%s has joined the game", pl.ttyname);

				break;
			}

			/*
			 * http://wiki.sourcepython.com/developing/events/tf.html#player-death
			 */
			case "player_death":
			{
				int    userid    = args.get!short("userid", gameEvents);
				int    attacker  = args.get!short("attacker", gameEvents);
				char[] weapon    = args.get!(char[])("weapon_logclassname", gameEvents);
				int    crit_type = args.get!short("crit_type", 0, gameEvents);

				bool isCrit = (crit_type == 2); // 1 = mini, 2 = proper

				// killer, if there is one
				Player* killer;
				if (attacker)
				{
					killer = players.getByUserId(attacker);
					assert(killer);
					killer.onSpawnedActivity();
				}

				// victim
				Player* victim = players.getByUserId(userid);
				assert(victim);
				victim.onSpawnedActivity();

				/*
				 * s*icide
				 * weapon is either "world" or any weapon capable of killing its user
				 */
				if (killer == victim)
				{
					if (weapon == "world")
					{
						// normal s*uicide
						if (g_htmlOut)
							htmlSimpleRow(
								"%s suicided.%s",
								htmlPlayerName(victim).ptr,
								isCrit ? " (crit)".ptr : "".ptr,
								);
						else
							log("%s suicided.%s",
								victim.ttyname,
								isCrit ? " (crit)".ptr : "".ptr,
								);
					}
					else
					{
						// weapon-assisted
						if (g_htmlOut)
							htmlSimpleRow(
								"%s suicided.%s (%s)",
								htmlPlayerName(victim).ptr,
								isCrit ? " (crit)".ptr : "".ptr,
								weapon.ptr,
								);
						else
							log("%s suicided.%s (%s)",
								victim.ttyname,
								isCrit ? " (crit)".ptr : "".ptr,
								weapon.ptr,
								);
					}

					break;
				}

				/*
				 * environmental death (killed by map entity)
				 */
				if (!killer)
				{
					if (g_htmlOut)
						htmlSimpleRow(
							"%s died.%s (%s)",
							htmlPlayerName(victim).ptr,
							isCrit ? " (crit)".ptr : "".ptr,
							weapon.ptr,
							);
					else
						log("%s died.%s (%s)",
							victim.ttyname,
							isCrit ? " (crit)".ptr : "".ptr,
							weapon.ptr,
							);

					switch (weapon)
					{
						// - train on ctf_well (sometimes?)
						case "tracktrain":
							break;

						// - train on ctf_well (sometimes?)
						// - ravine on ctf_doublecross, others
						case "trigger_hurt":
							break;

						// - drowning
						// - fall damage
						case "worldspawn":
							break;

						// (monoculus?)
						case "eyeball_boss":
						case "eyeball_rocket":
							break;

						// (seen on skial, does this not happen normally?)
						case "obj_sentrygun2":
							break;

						// (custom map entity?)
						case "door":
							break;

						// etc etc
						default:
							break;
					}

					break;
				}

				// fix up teams
				// NOTE: ignore "finished off" because it can happen when the player is autobalanced
				if (weapon != "player" && !isFriendlyFireEnabled)
					players.impliedOppositeTeams(killer, victim);

				if (g_htmlOut)
					htmlSimpleRow(
						"%s killed %s with <span class=\"weaponname\">%s</span>.%s",
						htmlPlayerName(killer).ptr,
						htmlPlayerName(victim).ptr,
						htmlspecialchars(weapon).ptr,
						isCrit ? " (crit)".ptr : "".ptr,
						);
				else
					log("%s killed %s with %s.%s",
						killer.ttyname,
						victim.ttyname,
						weapon.ptr.teamcolorize,
						isCrit ? " (crit)".ptr : "".ptr,
						);

				break;
			}

			case "player_disconnect":
			{
				char[] name   = args.get!(char[])("name", gameEvents);
				char[] reason = args.get!(char[])("reason", gameEvents);
				int    userid = args.get!short("userid", gameEvents);

				/*
				 * force: they might already be disconnected
				 * 
				 * also, the same userid might not exist anymore if they
				 *  reconnected while connecting (userinfo slot reused instantly)
				 */
				Player* pl = players.getByUserId(userid, /* force */ true);
				if (pl)
					pl.setDisconnected(Player.DisconnectReason.disconnectMessage);

				// end the reason string at the first newline
				const(char)[] shortreason = reason;
				foreach (i, c; shortreason)
				{
					if (c == '\n')
					{
						shortreason = shortreason[0..i];
						break;
					}
				}

				if (g_htmlOut)
				{
					// idle kicks have a dedicated message
					if (reason != "#TF_Idle_kicked")
						htmlSimpleRow("%s left the game (%s)",
							htmlPlayerName(pl).ptr,
							htmlUserText(shortreason).ptr,
							);
				}
				else
					log("%s left the game (%.*s)",
						(pl) ? pl.ttyname : name.ptr.teamcolorize,
						cast(int)shortreason.length, shortreason.ptr);

				/+
				 . 3118  Client Disconnect
				 .  700  #TF_MM_Generic_Kicked
				 .  124  <name> timed out
				 .   83  #TF_Idle_kicked
				 .   71  Processing time exceeded
				 .   38  Connection closing
				 .   27  Client left game (Steam auth ticket has been canceled)
				 .    9  An issue with your computer is blocking the VAC system. You cannot play on secure servers.
				 .    4  VAC banned from secure server
				 .    2  Client not connected to Steam
				 .    2  Invalid STEAM UserID Ticket
				 .    1  #GameUI_Disconnect_TooManyCommands
				 .    1  " #TF_Vote_kicked
				 +/

				switch (reason)
				{
					case "Client Disconnect":
					case "#TF_MM_Generic_Kicked":
					case "#TF_Idle_kicked":
					case "Processing time exceeded":
					case "Connection closing":
					case "Client left game (Steam auth ticket has been canceled)\n":
					case "An issue with your computer is blocking the VAC system. You cannot play on secure servers.\n\nhttps://support.steampowered.com/kb_article.php?ref=2117-ILZV-2837":
					case "VAC banned from secure server\n": // 2022-08-13_20-34-00_3.dem
					case "Client not connected to Steam\n":
					case "Invalid STEAM UserID Ticket\n":
					case "#GameUI_Disconnect_TooManyCommands":
					case "\" #TF_Vote_kicked": // 2022-08-06_19-11-28.dem - retry during kick vote
					case "This Steam account does not own this game. \nPlease login to the correct Steam account":
						break;

					case "Kicked from server":
						break;

					case "Disconnect by user.": // old demos
						break;

					// custom disconnect reasons (test_2.dem-)
					case "l\x7fia\ndcmmoxy".frobnicate:
					case "VGhpcyBpcyBub3QgYSBsaW5rIHhkT2NOWWEwTDlj":
						if (pl)
							printf("-player used custom disconnect reason: %s %s\n", pl.info.guid.ptr, pl.ttyname);
						break;

					default:
					{
						enum timedOut = " timed out";
						if (
							reason.length == name.length+timedOut.length &&
							reason.startsWith(name) &&
							reason.endsWith(timedOut))
						{
							break;
						}

						debug
							printf("[%s]\n", reason.ptr);

						assert(0); // unknown disconnect reason
					}
				}

				break;
			}

			/*
			 * fired:
			 * 1. before "connected" message (class=0 team=0)
			 * 2. on any kind of spawning, including user-initiated ones due to loadout changing
			 */
			case "player_spawn":
			{
				int class_ = args.get!short("class", gameEvents);
				int team   = args.get!short("team", gameEvents);
				int userid = args.get!short("userid", gameEvents);

				bool isPreConnect = (team == 0 && class_ == 0);

				static immutable classNames = [
					null,
					"scout",
					"sniper",
					"soldier",
					"demoman",
					"medic",
					"heavy",
					"pyro",
					"spy",
					"engineer",
				];

				if (!team)
					assert(!class_);
				else
				{
					if (team == 1) // spectator
					{
						assert(serverAllowsSpectators);
						// note: class is sometimes non-zero in skial demos (why?)
					}
					else
					{
						assert(team == 2 || team == 3);
						assert(class_ >= 1 && class_ <= 9);
					}
				}

				if (Player* pl = players.getByUserId(userid))
				{
					if (!isPreConnect)
					{
						pl.impliedTeam(team, /* force */ serverNeedsForcedImpliedTeamsWorkaround);
						log("%s spawned as %s", pl.ttyname, classNames[class_].ptr);
						pl.onSpawnedActivity();
					}
				}
				else
				{
					if (isOfficialServer)
					{
						// burst at start of demo:
						//  2022-07-19_14-42-58.dem
						// processing time exceeded:
						//  2022-07-24_15-50-15.dem team=0 class=0
						//  2022-10-05_20-45-19.dem team=2 class=6
						if (!isPreConnect)
							printf("-bug: player_spawn for nonexistent userid %d (team=%d class=%d)\n", userid, team, class_);
					}
					else
					{
						// seems to happen for bots before their userinfo is created? (blankit2_skial.dem)
						// check that the userid is nonexistent, not just disconnected
						// !!!FIXME!!! check why this fails in 2022-09-04_20-01-46.dem
						// another: 2022-09-25_22-17-33.dem
						if (Player* pl = players.getByUserId(userid, true))
						{
							//if (filePath.baseName != "2022-09-04_20-01-46.dem")
							//	assert(0);
						}
						printf("-bug: player_spawn for nonexistent userid %d (team=%d class=%d)\n", userid, team, class_);
					}
				}

				break;
			}

			case "player_team":
			{
				uint   autoteam   = args.get!bool("autoteam", gameEvents);
				uint   disconnect = args.get!bool("disconnect", gameEvents);
				char[] name       = args.get!(char[])("name", gameEvents);
				uint   oldteam    = args.get!ubyte("oldteam", gameEvents);
				uint   team       = args.get!ubyte("team", gameEvents);
				int    userid     = args.get!short("userid", gameEvents);

				// some disconnects fire this (why not all?)
				if (disconnect)
					break;

				bool getDisconnected;
				if (fileName == "2022-10-14_20-10-56_2.dem") // fixme
					getDisconnected = true;

				Player* pl = players.getByUserId(userid, /* force */ getDisconnected);
				assert(pl);
				pl.impliedTeam(team, /* force */ true); // override old team

				string teamname =
					team == 1 ? "SPECTATORS" :
					team == 2 ? "RED" :
					team == 3 ? "BLU" :
					null;

				assert(teamname);

				string middle;
				if (autoteam)
					middle = "was automatically assigned to team";
				else
					middle = "joined team";

				if (g_htmlOut)
					htmlSimpleRow("%s %s %s",
						htmlPlayerName(pl).ptr,
						middle.ptr,
						teamname.ptr,
						);
				else
					log("%s %s %s", pl.ttyname, middle.ptr, teamname.ptr);

				/*
				 * valve servers auto-assign you a team without showing the
				 *  selection screen, so anyone manually joining is either using
				 * 
				 * 1. jointeam in console
				 * 2. feature of some cheat? (2022-08-02_03-15-37.dem has a real cheater do it)
				 */
				if (
					(!oldteam && team) &&
					!autoteam &&
					isOfficialServer &&
					!pl.isLocalPlayer)
				{
					printf("-player manually joined a team: %s %s\n", pl.info.guid.ptr, pl.ttyname);
				}

				break;
			}

			case "vote_cast":
			{
				int  entityid    = args.get!int("entityid", gameEvents);
				int  team        = args.get!short("team", gameEvents);
				uint vote_option = args.get!ubyte("vote_option", gameEvents);
				int  voteidx     = (buildNumber > 7182415)
				/**/             ? args.get!int("voteidx", gameEvents)
				/**/             : 0;

				Player* pl = players.getByEntIndex(entityid);
				assert(pl);
				if (team) // skial
					pl.impliedTeam(team);

				if (g_htmlOut)
					htmlSimpleRow("<strong>Vote:</strong> %s voted %s",
						htmlPlayerName(pl).ptr,
						htmlspecialchars(votes.get(voteidx).optionName(vote_option).fromStringz).ptr,
						);
				else
					log("Vote: %s voted %s", pl.ttyname, votes.get(voteidx).optionName(vote_option));

				break;
			}

			case "vote_options":
			{
				uint count   = args.get!ubyte("count", gameEvents);
				int  voteidx = (buildNumber > 7182415)
				/**/         ? args.get!int("voteidx", gameEvents)
				/**/         : 0;

				// skial hack:
				// this comes with idx=-1, vote_cast comes with idx=0 or idx=1
				if (!isOfficialServer && voteidx == -1)
					voteidx = 0;

				Vote* v = votes.get(voteidx);

				v.options = new char[][count];
				foreach (i; 0..count)
				{
					char[16] buf = void;
					snprintf(buf.ptr, buf.length, "option%u", i+1);
					v.options[i] = args.get!(char[])(buf.fromStringz, gameEvents);
				}

				break;
			}

			// these seem unused, so we're not handling them
			// if they become used, we'd like to know about it
			case "vote_changed":
			case "vote_ended":
			case "vote_failed":
			case "vote_maps_changed":
			case "vote_passed":
			case "vote_started":
			{
				printf("-fixme: unhandled vote event %s\n", ge.name.ptr);
				assert(0, "unhandled vote event");
			}

			// server cvar change that's announced in the chat (e.g. sv_cheats)
			case "server_cvar":
			{
				char[] name  = args.get!(char[])("cvarname", gameEvents);
				char[] value = args.get!(char[])("cvarvalue", gameEvents);
				log("Server cvar '%s' changed to %s", name.ptr, value.ptr);
				if (name == "mp_friendlyfire")
					isFriendlyFireEnabled = !!atoi(value.ptr);
				break;
			}

			case "item_found":
			{
				uint  isStrange  = args.get!ubyte("isstrange", gameEvents);
				uint  isUnusual  = args.get!ubyte("isunusual", gameEvents);
				int   itemdef    = args.get!int("itemdef", gameEvents);
				uint  method     = args.get!ubyte("method", gameEvents);
				uint  playerSlot = args.get!ubyte("player", gameEvents);
				uint  quality    = args.get!ubyte("quality", gameEvents);
				float wear       = args.get!float("wear", gameEvents);

				Player* pl = players.getByEntIndex(playerSlot);
				assert(pl);

				static immutable const(char)*[256] hasWhat = [
					0: "found",
					1: "crafted",
					2: "traded for",
					4: "unboxed",
					255: "found", // achievement item
				];

				if (const(char)* methodStr = hasWhat[method])
				{
					log("%s has %s: %d",
						pl.ttyname,
						methodStr,
						itemdef,
						);
				}
				else
				{
					log("%s has acquired by method %u: %d",
						pl.ttyname,
						method,
						itemdef,
						);
				}

				break;
			}

			default:
				break;
		}

		return args.parsed;
	}

	/*
	 * see: CGameEventManager::ParseEventList in engine/GameEventManager.cpp
	 */
	void handleGameEventList(ubyte[] data)
	{
		enum MAX_EVENT_BITS = 9;

		enum print = false;

		// write defs to disk
		saveGameEventList(data);

		/*
		 * if we already loaded them early from the file, do nothing
		 * 
		 * this assumes that the file contents really match what we got here
		 *  (saveGameEventList() checks this with debug=1)
		 */
		if (gameEvents.defs.length)
			return;

		scope evbuf = new bf_read(data);

		auto ges = appender!(GameEvent*[])();
		enum reserveNumber = 403; // build 7370160
		ges.reserve(reserveNumber);

		while (evbuf.GetNumBitsLeft() >= MAX_EVENT_BITS+8)
		{
			uint   eventNo   = evbuf.ReadUBitLong(MAX_EVENT_BITS);
			char[] eventName = evbuf.ReadDString();

			if (print)
				printf("*** event %u = %s\n", eventNo, eventName.ptr);

			GameEvent* ge = new GameEvent(eventNo, eventName);
			ges ~= ge;

			auto ps = appender!(GameEvent.Param[])();

			for (;;)
			{
				uint argType = evbuf.ReadUBitLong(3);
				if (!argType)
					break;

				char[] argName = evbuf.ReadDString();

				if (print)
					printf("    %-7s %s\n", GameEvent.Param.typeName(argType).ptr, argName.ptr);

				assert(argType >= GameEvent.Param.Type.min && argType <= GameEvent.Param.Type.max);
				ps ~= GameEvent.Param(argName, cast(GameEvent.Param.Type)argType);
			}

			ge.params = ps[];
		}

		gameEvents.defs = ges[];

		assert(!evbuf.GetNumBytesLeft()); // byte-aligned
	}

	/*
	 * writes the GameEventList for this engine build to disk
	 */
	void saveGameEventList(ubyte[] data)
	{
		if (!isOfficialServer)
			return; // 不要 (do not want)

		string dataDir = thisExePath.dirName~"/data";
		char[] filename = printf_tmp("%s/gameevents_%u.bin", dataDir.toStringz, buildNumber).fromStringz;

		/*
		 * check if defs are already saved (they probably are)
		 */

		// if it already exists, just check that the copy in this demo is identical
		// debug only (this is slightly slow)
		if (filename.exists)
		{
			debug
			{
				scope mm = new MmFile(filename.idup);
				assert(mm[] == data);
			}
			return;
		}

		/*
		 * create the directory if it doesn't exist
		 * if it does, get the list of old files
		 */

		string[] olderDefs; // all pre-existing defs older than this engine build

		if (!dataDir.exists)
		{
			dataDir.mkdirRecurse();
		}
		else
		{
			olderDefs = dataDir
				.dirEntries("gameevents_*.bin", SpanMode.shallow)
				.map!"a.name"
				.filter!((s) // lower build number than the current demo
				{
					uint n = atoi(&s.baseName["gameevents_".length]);
					return n < buildNumber;
				})
				.array
				.sort!((s1, s2)
				{
					uint n1 = atoi(&s1.baseName["gameevents_".length]);
					uint n2 = atoi(&s2.baseName["gameevents_".length]);
					return n1 < n2;
				})
				.array;
		}

		/*
		 * check if the new build's defs are identical to the previous build's
		 */

		string identicalExistingFile;
		if (olderDefs.length)
		{
			string lastFile = olderDefs[$-1];

			scope lastMm = new MmFile(lastFile);
			ubyte[] lastData = cast(ubyte[])lastMm[];

			if (data == lastData)
				identicalExistingFile = lastFile;
		}

		/*
		 * write file, or just symlink to the identical copy
		 */

		if (!identicalExistingFile)
		{
			File(filename, "w").rawWrite(data);
		}
		else
		{
			version(Posix)
				symlink(identicalExistingFile.baseName, filename);
			else
				File(filename, "w").rawWrite(data);
		}
	}

	/*
	 * tries to load a saved copy of GameEventList for this engine build
	 */
	bool tryLoadGameEventListFromDisk()
	{
		/*
		 * demos that have no svc_gameeventlist at all:
		 * 2022-07-24_12-50-12.dem
		 * 2022-07-24_13-06-09.dem
		 * 2022-07-24_13-30-07.dem
		 * 
		 * demos that just get some events early:
		 * 2022-07-19_14-42-58.dem
		 * 2022-07-24_16-46-31.dem
		 * 2022-07-31_03-10-35_2.dem
		 * 2022-08-02_03-04-29_2.dem
		 * (etc. many such cases!)
		 */

		string dataDir = thisExePath.dirName~"/data";
		char[] filename = printf_tmp("%s/gameevents_%u.bin", dataDir.toStringz, buildNumber).fromStringz;

		if (!filename.exists)
			return false;

		scope mm = new MmFile(filename.assumeUnique);
		handleGameEventList(cast(ubyte[])mm[]);
		return true;
	}

	void htmlBeginRow()
	{
		assert(g_htmlOut);
		fprintf(g_htmlOut, "<tr><td>%.3f</td><td>", serverTickNo * 0.015);
	}

	pragma(printf)
	extern(C)
	void htmlSimpleRow(const(char)* fmt, ...)
	{
		va_list ap;
		htmlBeginRow();
		va_start(ap, fmt);
		vfprintf(g_htmlOut, fmt, ap);
		va_end(ap);
		htmlEndRow();
	}

	void htmlEndRow()
	{
		assert(g_htmlOut);
		fprintf(g_htmlOut, "</td></tr>\n");
		fflush(g_htmlOut);
	}
}

enum : uint
{
	net_nop = 0,
	net_file = 2,
	net_tick = 3,
	net_stringcmd = 4,
	net_setconvar = 5,
	net_signonstate = 6,
	svc_print = 7,
	svc_serverinfo = 8,
	svc_classinfo = 10,
	svc_createstringtable = 12,
	svc_updatestringtable = 13,
	svc_voiceinit = 14,
	svc_voicedata = 15,
	svc_sounds = 17,
	svc_setview = 18,
	svc_fixangle = 19,
	svc_bspdecal = 21,
	svc_usermessage = 23,
	svc_entitymessage = 24,
	svc_gameevent = 25,
	svc_packetentities = 26,
	svc_tempentities = 27,
	svc_prefetch = 28,
	svc_gameeventlist = 30,
	svc_getcvarvalue = 31,
}

string packetName(uint msg)
{
	final switch (msg)
	{
		case net_nop:               return "net_nop";
		case net_file:              return "net_file";
		case net_tick:              return "net_tick";
		case net_stringcmd:         return "net_stringcmd";
		case net_setconvar:         return "net_setconvar";
		case net_signonstate:       return "net_signonstate";
		case svc_print:             return "svc_print";
		case svc_serverinfo:        return "svc_serverinfo";
		case svc_classinfo:         return "svc_classinfo";
		case svc_createstringtable: return "svc_createstringtable";
		case svc_updatestringtable: return "svc_updatestringtable";
		case svc_voiceinit:         return "svc_voiceinit";
		case svc_voicedata:         return "svc_voicedata";
		case svc_sounds:            return "svc_sounds";
		case svc_setview:           return "svc_setview";
		case svc_fixangle:          return "svc_fixangle";
		case svc_bspdecal:          return "svc_bspdecal";
		case svc_usermessage:       return "svc_usermessage";
		case svc_entitymessage:     return "svc_entitymessage";
		case svc_gameevent:         return "svc_gameevent";
		case svc_packetentities:    return "svc_packetentities";
		case svc_tempentities:      return "svc_tempentities";
		case svc_prefetch:          return "svc_prefetch";
		case svc_gameeventlist:     return "svc_gameeventlist";
		case svc_getcvarvalue:      return "svc_getcvarvalue";
	}
}

/*
 * https://wiki.alliedmods.net/User_Messages#Team_Fortress_2_User_Messages
 * 
 * (ubyte for compactness in userMessageToString. should probably change to uint)
 */
enum UserMessage : ubyte
{
	Geiger = 0,
	Train = 1,
	HudText = 2,
	SayText = 3,
	SayText2 = 4,
	TextMsg = 5,
	ResetHUD = 6,
	GameTitle = 7,
	ItemPickup = 8,
	ShowMenu = 9,
	Shake = 10,
	Fade = 11,
	VGUIMenu = 12,
	Rumble = 13,
	CloseCaption = 14,
	SendAudio = 15,
	VoiceMask = 16,
	RequestState = 17,
	Damage = 18,
	HintText = 19,
	KeyHintText = 20,
	HudMsg = 21,
	AmmoDenied = 22,
	AchievementEvent = 23,
	UpdateRadar = 24,
	VoiceSubtitle = 25,
	HudNotify = 26,
	HudNotifyCustom = 27,
	PlayerStatsUpdate = 28,
	MapStatsUpdate = 29,
	PlayerIgnited = 30,
	PlayerIgnitedInv = 31,
	HudArenaNotify = 32,
	UpdateAchievement = 33,
	TrainingMsg = 34,
	TrainingObjective = 35,
	DamageDodged = 36,
	PlayerJarated = 37,
	PlayerExtinguished = 38,
	PlayerJaratedFade = 39,
	PlayerShieldBlocked = 40,
	BreakModel = 41,
	CheapBreakModel = 42,
	BreakModel_Pumpkin = 43,
	BreakModelRocketDud = 44,
	CallVoteFailed = 45,
	VoteStart = 46,
	VotePass = 47,
	VoteFailed = 48,
	VoteSetup = 49, /// local player opened vote menu, not interesting to parse
	PlayerBonusPoints = 50,
	RDTeamPointsChanged = 51,
	SpawnFlyingBird = 52,
	PlayerGodRayEffect = 53,
	PlayerTeleportHomeEffect = 54,
	MVMStatsReset = 55,
	MVMPlayerEvent = 56,
	MVMResetPlayerStats = 57,
	MVMWaveFailed = 58,
	MVMAnnouncement = 59,
	MVMPlayerUpgradedEvent = 60,
	MVMVictory = 61,
	MVMWaveChange = 62,
	MVMLocalPlayerUpgradesClear = 63,
	MVMLocalPlayerUpgradesValue = 64,
	MVMResetPlayerWaveSpendingStats = 65,
	MVMLocalPlayerWaveSpendingValue = 66,
	MVMResetPlayerUpgradeSpending = 67,
	MVMServerKickTimeUpdate = 68,
	PlayerLoadoutUpdated = 69,
	PlayerTauntSoundLoopStart = 70,
	PlayerTauntSoundLoopEnd = 71,
	ForcePlayerViewAngles = 72,
	BonusDucks = 73,
	EOTLDuckEvent = 74,
	PlayerPickupWeapon = 75,
	QuestObjectiveCompleted = 76,
	SPHapWeapEvent = 77,
	HapDmg = 78,
	HapPunch = 79,
	HapSetDrag = 80,
	HapSetConst = 81,
	HapMeleeContact = 82,
}

static immutable string[UserMessage] userMessageToString;

shared static this() // todo: see if switch would be better
{
	struct KV { string key; UserMessage value; }
	static immutable t = {
		KV[__traits(allMembers, UserMessage).length] t = void;
		foreach (i, k; __traits(allMembers, UserMessage))
			t[i] = KV(k, __traits(getMember, UserMessage, k));
		return t;
	}();
	foreach (kv; t)
		userMessageToString[kv.value] = kv.key;
}

/// https://www.man7.org/linux/man-pages/man3/memfrob.3.html
string frobnicate(string s) pure
{
	char[] rv = uninitializedArray!(char[])(s.length);
	foreach (i, c; s)
		rv.ptr[i] = c ^ 42;
	return rv.assumeUnique;
}

struct SpaceTally
{
	enum enabled = false;

static if (enabled):
static:
	ulong[string] demoMessageSizes;
	ulong[string] packetSizesBits;

	void countDemoMessage(string name, ulong dataSize)
	{
		enum demoMessageNumberSize = 1;
		enum demoTickCountSize = 4;
		demoMessageSizes[name] += demoMessageNumberSize+demoTickCountSize+dataSize;
	}

	void countPacketBits(string name, ulong dataSizeBits)
	{
		enum packetNumberSizeBits = 6;
		packetSizesBits[name] += packetNumberSizeBits+dataSizeBits;
	}

	void print()
	{
		printf("Demo messages:\n");
		foreach (p; demoMessageSizes.byPair.array.sort!((p1, p2)
		{
			if (p1.value != p2.value)
				return p1.value > p2.value;
			return p1.key < p2.key;
		}))
		{
			printf("%9llu %s\n", p.value, p.key.ptr);
		}

		printf("Packets:\n");
		foreach (p; packetSizesBits.byPair.array.sort!((p1, p2)
		{
			if (p1.value != p2.value)
				return p1.value > p2.value;
			return p1.key < p2.key;
		}))
		{
			printf("%9llu %s\n", p.value / 8 + !!(p.value % 8), p.key.ptr);
		}
	}

	void reset()
	{
		demoMessageSizes = null;
		packetSizesBits = null;
	}
}

// unused, but this is how the map md5 in svc_serverinfo is calculated
ubyte[16] getMapChecksum(string path)
{
	static struct BspLump
	{
		int     fileofs;
		int     filelen;
		int     version_;
		char[4] fourCC;

		const(ubyte)[] getData(ref ByteReader reader)
		{
			return reader.data[fileofs..fileofs+filelen];
		}
	}

	static struct BspHeader
	{
		int ident;
		int version_;
		BspLump[64] lumps;
		int mapRevision;
	}

	auto mapreader = ByteReader(path);

	auto bspheader = mapreader.read!BspHeader();

	auto md5 = makeDigest!MD5();

	foreach (i, ref lump; bspheader.lumps)
	{
		if (i != 0)
			md5.put(lump.getData(mapreader));
	}

	return md5.finish();
}

// todo: convert unicode to entities
const(char)[] htmlspecialchars(const(char)[] s)
{
	size_t pos = -1;
loop:
	foreach (i, c; s)
	{
		switch (c)
		{
		case '&':
		case '"':
		case '<':
		case '>':
			pos = i;
			break loop;
		case '\0':
			assert(0); // test
			break;
		default:
			break;
		}
	}
	if (pos == -1)
		return s;
	auto ap = appender!string;
	ap.reserve(s.length + 3 + 1); // "gt;" + "\0"
	ap ~= s[0..pos];
	foreach (c; s[pos..$])
	{
		switch (c)
		{
		case '\0':
			assert(0); // test
			break;
		case '&':
			ap ~= "&amp;";
			break;
		case '"':
			ap ~= "&quot;";
			break;
		case '<':
			ap ~= "&lt;";
			break;
		case '>':
			ap ~= "&gt;";
			break;
		default:
			ap ~= c;
			break;
		}
	}
	ap ~= '\0';
	return ap[][0..$-1];
}

unittest
{
	assert(htmlspecialchars("hi") == "hi");
	assert(htmlspecialchars("rock & roll") == "rock &amp; roll");
	assert(htmlspecialchars("rock && roll") == "rock &amp;&amp; roll");
	assert(htmlspecialchars(" & \" < > ") == " &amp; &quot; &lt; &gt; ");
	assert(htmlspecialchars(">") == "&gt;");
}

string playerToTeamName(Player* pl)
{
	if (pl)
	{
		if (pl.team == 2)
			return "red";
		if (pl.team == 3)
			return "blu";
	}
	return "unassigned";
}

/**
 * used by:
 * - SayText2 user message
 * - TextMsg user message
 */
const(char)[] htmlSourceModColoredText(const(char)[] s)
{
	size_t skipuntil;
	int inColor;
	auto ap = appender!string;

	foreach (i, c; s)
	{
		if (c == 1 || c == 3 || c == 4)
		{
			// not sure what 3 is
			// it appears in player chat messages but not system messages
			// 4 appears in rtd messages before the number of seconds
			if (inColor)
			{
				ap ~= "</span>";
				inColor--;
			}
			continue;
		}

		if (c == 7)
		{
			const(char)[] color = s[i+1..i+7]; // RRGGBB
			uint r, g, b;
			sscanf(color.ptr, "%02x%02x%02x", &r, &g, &b);

			char[16] buf;
			snprintf(buf.ptr, buf.length, "%02x%02x%02x", r, g, b);
			ap ~= "<span style=\"color: #";
			ap ~= buf.fromStringz;
			ap ~= "\">";
			skipuntil = i + 7;
			inColor++;
			continue;
		}

		if (c < ' ' && c != '\n') assert(0, "unknown control character");

		if (i >= skipuntil)
			switch (c)
			{
			case '&':
				ap ~= "&amp;";
				break;
			case '"':
				ap ~= "&quot;";
				break;
			case '<':
				ap ~= "&lt;";
				break;
			case '>':
				ap ~= "&gt;";
				break;
			default:
				ap ~= c;
				break;
			}
	}

	while (inColor --> 0) ap ~= "</span>";

	ap ~= '\0';
	return ap[][0..$-1];
}

const(char)[] htmlPlayerName(Player* pl)
{
	auto ap = appender!string;

	char[32] buf = void;
	snprintf(buf.ptr, buf.length, "%u", pl.info.friendsID);
	ap ~= "<span class=\"playername\" data-accountid=\"";
	ap ~= buf.fromStringz;
	ap ~= "\" data-mark=\"";
	if (auto mark = pl.info.guid.fromStringz in g_marks)
		ap ~= htmlspecialchars((*mark).name);
	ap ~= "\" data-team=\"";
	ap ~= playerToTeamName(pl);
	ap ~= "\" dir=\"auto\" lang>";
	ap ~= htmlspecialchars(pl.info.name.fromStringz);
	ap ~= "</span>";

	ap ~= '\0';
	return ap[][0..$-1];
}

const(char)[] htmlUserText(const(char)[] s)
{
	auto ap = appender!string;

	ap ~= "<span class=\"usertext\" dir=\"auto\" lang>";
	ap ~= htmlspecialchars(s);
	ap ~= "</span>";

	ap ~= '\0';
	return ap[][0..$-1];
}
