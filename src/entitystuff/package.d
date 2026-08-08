/**
 * Entity Stuff mostly borrowed from:
 * https://github.com/UncraftedName/UncraftedDemoParser
 */
module demoreader.entitystuff;

import core.stdc.stdio;
import std.array;
import std.container.dlist;
import std.exception;
import std.string;
import demoreader.entitystuff.datatable;
import demoreader.entitystuff.decode;
import demoreader.globals;
import demoreader.player : Player;
import demoreader.valve.bitbuf;

__gshared GameState gameState;

struct Vector2 { float x,y; }
struct Vector3 { float x,y,z; }

enum DELTASIZE_BITS = 20;
enum MAX_EDICT_BITS = 11;
enum MAX_EDICTS = 1 << MAX_EDICT_BITS;
enum MAX_SERVER_CLASS_BITS = 9;
enum NUM_NETWORKED_EHANDLE_SERIAL_NUMBER_BITS = 10;
enum PROPINFOBITS_FLAGS = 16;
enum PROPINFOBITS_NUMBITS = 7;
enum PROPINFOBITS_NUMELEMENTS = 10;
enum PROPINFOBITS_NUMPROPS = 10;
enum PROPINFOBITS_TYPE = 5;
enum SPROP_EXCLUDE = 1<<6;

alias nothing_t = void[0];
enum nothing = nothing_t.init;

// -----------------------------------------------------------------------------

// src/Parser/Components/Messages/SvcPacketEntities.cs

// search: CL_ProcessPacketEntities

void parseSvcPacketEntities(bf_read buf, bool readWithoutParsing)
{
	uint maxEntries     = buf.ReadUBitLong(MAX_EDICT_BITS);
	bool isDelta        = !!buf.ReadOneBit();
	int  deltaFrom      = (isDelta)
	/**/                ? buf.ReadLong()
	/**/                : -1;
	uint baseLineIdx    = buf.ReadOneBit();
	uint updatedEntries = buf.ReadUBitLong(MAX_EDICT_BITS);
	uint dataLen        = buf.ReadUBitLong(DELTASIZE_BITS);
	bool updateBaseline = !!buf.ReadOneBit();

	if (TRACE1)
	{
		if (updateBaseline)
			printf("   *** updateBaseline idx=%d ***\n", baseLineIdx);
		if (isDelta)
			printf("   deltaFrom=%d\n", deltaFrom);
	}

	uint startbit = buf.GetNumBitsRead();

	if (readWithoutParsing)
	{
		buf.Seek(startbit+dataLen);
		return;
	}

	GameState.Snapshot* oldSnapshot;
	GameState.Snapshot* newSnapshot;

	if (isDelta)
	{
		assert(deltaFrom < gameState.serverTick);

		oldSnapshot = gameState.snapshotForTick(deltaFrom);
		assert(oldSnapshot, "deltaFrom snapshot not found");

		assert(oldSnapshot.serverTick < gameState.serverTick);

		newSnapshot = oldSnapshot.shallowCopy;
		newSnapshot.serverTick = gameState.serverTick;
		newSnapshot.deltaFrom = deltaFrom;

		if (gameState.snapshotCount >= 128)
		{
			gameState.snapshots.front.entities[] = null; // gc
			gameState.snapshots.front = null; // gc
			gameState.snapshots.removeFront();
			gameState.snapshotCount -= 1;
		}
		gameState.snapshots.insert(newSnapshot);
		gameState.snapshotCount += 1;
	}
	else
	{
		// clear all snapshots (including the current one)
		foreach (ref snap; gameState.snapshots)
		{
			snap.entities[] = null; // gc
			snap = null; // gc
		}
		gameState.snapshots.clear();

		newSnapshot = new GameState.Snapshot();
		newSnapshot.serverTick = gameState.serverTick;
		newSnapshot.deltaFrom = deltaFrom;

		gameState.snapshots.insert(newSnapshot);
		gameState.snapshotCount = 1;
	}

	if (updateBaseline)
	{
		gameState.baseLines.copyEntityBaseLine(baseLineIdx);
	}

	int entindex = -1;

	foreach (_; 0..updatedEntries)
	{
		entindex += 1 + buf.ReadUBitVar();

		final switch (buf.ReadUBitLong(2))
		{
			/*
			 * Delta
			 */
			case 0:
			{
				assert(oldSnapshot, "Delta on full update");

				if (TRACE1)
				{
					const(char)* classname = "?";
					if (auto ent = oldSnapshot.entities[entindex])
						classname = gameState.classes[ent.classid].name.ptr;
					if (entindex >= 1 && entindex <= Player.maxPlayers)
					{
						if (Player* pl = Player.getByEntIndex(entindex))
							classname = pl.ttyname;
					}
					printf("   Delta %d <%s>\n", entindex, classname);
				}

				EntitySnapshot.processDelta(entindex, buf, oldSnapshot, newSnapshot);

				break;
			}

			/*
			 * LeavePVS
			 */
			case 1:
			{
				assert(oldSnapshot, "LeavePVS on full update");

				if (TRACE1)
				{
					const(char)* classname = "?";
					if (auto ent = oldSnapshot.entities[entindex])
						classname = gameState.classes[ent.classid].name.ptr;
					if (entindex >= 1 && entindex <= Player.maxPlayers)
					{
						if (Player* pl = Player.getByEntIndex(entindex))
							classname = pl.ttyname;
					}
					printf("   LeavePVS %d <%s>\n", entindex, classname);
				}

				EntitySnapshot.processLeavePvs(entindex, oldSnapshot, newSnapshot);

				break;
			}

			/*
			 * EnterPVS
			 */
			case 2:
			{
				int classid = buf.ReadUBitLong(MAX_SERVER_CLASS_BITS);
				int serial = buf.ReadUBitLong(NUM_NETWORKED_EHANDLE_SERIAL_NUMBER_BITS);

				if (TRACE1)
				{
					const(char)* classname = gameState.classes[classid].name.ptr;
					if (entindex >= 1 && entindex <= Player.maxPlayers)
					{
						if (Player* pl = Player.getByEntIndex(entindex))
							classname = pl.ttyname;
					}
					printf("   EnterPVS %d <%s>\n", entindex, classname);
				}

				EntitySnapshot.processEnterPvs(
					buf,
					entindex,
					classid,
					serial,
					updateBaseline,
					baseLineIdx,
					isDelta,
					oldSnapshot,
					newSnapshot,
					);

				break;
			}

			/*
			 * Delete
			 */
			case 3:
			{
				assert(oldSnapshot, "Delete on full update");

				if (TRACE1)
				{
					const(char)* classname = "?";
					if (auto ent = oldSnapshot.entities[entindex])
						classname = gameState.classes[ent.classid].name.ptr;
					if (entindex >= 1 && entindex <= Player.maxPlayers)
					{
						if (Player* pl = Player.getByEntIndex(entindex))
							classname = pl.ttyname;
					}
					printf("   Delete %d <%s>\n", entindex, classname);
				}

				EntitySnapshot.processDelete(entindex, oldSnapshot, newSnapshot);

				break;
			}
		}
	}

	if (isDelta)
	{
		assert(oldSnapshot); // just double checking

		while (buf.ReadOneBit())
		{
			// sometimes the entity is already deleted here (shrug emoji)

			// 2022-11-25_06-51-06_2.dem
			// search: Delete2 690
			// on ticks 1566-1568, it's a CTFProjectile_Rocket
			// on tick 1569, we try to delete it with a delta from 1565 where the
			//  rocket didn't yet exist
			// (was it meant to exist there?)

			entindex = buf.ReadUBitLong(MAX_EDICT_BITS);

			bool ok = EntitySnapshot.processDeleteNoCheck(
				entindex,
				oldSnapshot,
				newSnapshot);

			if (TRACE1)
			{
				if (ok)
				{
					const(char)* classname = "?";
					if (auto ent = oldSnapshot.entities[entindex])
						classname = gameState.classes[ent.classid].name.ptr;
					if (entindex >= 1 && entindex <= Player.maxPlayers)
					{
						if (Player* pl = Player.getByEntIndex(entindex))
							classname = pl.ttyname;
					}
					printf("   Delete2 %d <%s>\n", entindex, classname);
				}
				else
				{
					printf("   Delete2 %d <?>\n", entindex);
					int i;
					int notFoundCnt;
					foreach_reverse (snap; gameState.snapshots)
					{
						if (auto ent = snap.entities[entindex])
						{
							const(char)* classname = "?";
							classname = gameState.classes[ent.classid].name.ptr;
							printf("    -> snapshot %d: %d->%d %s\n", i, snap.deltaFrom, snap.serverTick, classname);
							notFoundCnt = 0;
						}
						else
						{
							printf("    -> snapshot %d: %d->%d <not found>\n", i, snap.deltaFrom, snap.serverTick);
							if (++notFoundCnt >= 10)
							{
								printf("    (...)\n");
								break;
							}
						}
						i--;
					}
				}
			}
		}
	}

	newSnapshot.entities.updateTick = gameState.serverTick;

	assert(buf.GetNumBitsRead() == startbit+dataLen);
}

// -----------------------------------------------------------------------------

// src/Parser/GameState/EntitySnapshot.cs

struct EntitySnapshot
{
	Entity[MAX_EDICTS] entities;
	int                updateTick;

	alias entities this;

	static void processDelta(
		int entindex,
		bf_read buf,
		GameState.Snapshot* from,
		GameState.Snapshot* to)
	{
		Entity oldEnt = from.entities[entindex];
		assert(oldEnt, "missing entity to delta from");
		assert(oldEnt.inPvs, "delta entity not in pvs");

		Entity newEnt = oldEnt.shallowCopy;
		newEnt.updateTick = gameState.serverTick;
		to.entities[entindex] = newEnt;

		readEntProps!(/* doCopy */ true)(buf, newEnt.props, gameState.classes[newEnt.classid].flattenedProps);
	}

	static void processLeavePvs(
		int entindex,
		GameState.Snapshot* from,
		GameState.Snapshot* to)
	{
		Entity oldEnt = from.entities[entindex];
		assert(oldEnt, "missing entity to remove from pvs");
		assert(oldEnt.inPvs, "leavepvs entity not in pvs");

		// this can use sameProps since we're not changing the array this time

		Entity newEnt = oldEnt.shallowCopySameProps;

		newEnt.inPvs = false;
		newEnt.updateTick = gameState.serverTick;

		to.entities[entindex] = newEnt;
	}

	static void processEnterPvs(
		bf_read buf,
		int entindex,
		int classid,
		int serial,
		bool updateBaseline,
		uint baseLineIdx,
		bool isDelta,
		GameState.Snapshot* from,
		GameState.Snapshot* to)
	{
		Entity newEnt;
		if (
			from &&
			from.entities[entindex] &&
			from.entities[entindex].serial == serial)
		{
			// this never uses the existing props of the entity if it's just
			//  re-entering PVS. i wonder if that's right or i'm missing something?
			newEnt = from.entities[entindex].shallowCopyNoProps;
			assert(!newEnt.inPvs, "enterpvs entity already in pvs");
			newEnt.inPvs = true;
			newEnt.updateTick = gameState.serverTick;
		}
		else
		{
			newEnt = new Entity(classid, serial, null, /* inPvs */ true);
			newEnt.updateTick = gameState.serverTick;
		}
		to.entities[entindex] = newEnt;

		// use the entity baseline if: isDelta && entity baseline has the same classid

		IEntityProperty[] baseline;
		if (
			isDelta &&
			gameState.baseLines.entityBaselines[entindex][baseLineIdx].valid &&
			gameState.baseLines.entityBaselines[entindex][baseLineIdx].classid == classid)
		{
			baseline = gameState.baseLines.entityBaselines[entindex][baseLineIdx].properties;
		}
		else
		{
			baseline = gameState.baseLines.baselines[classid].properties;
		}
		assert(baseline.length);

		if (updateBaseline)
		{
			// 1. apply the network delta onto the baseline (class baseline or entity baseline [idx])
			// 2. store the result in entity baseline [opposite(idx)]
			// 3. create the new entity from the resulting baseline

			// [1]

			// demoreader: try to reuse the array that we'll be replacing here

			IEntityProperty[] newBaseline;

			auto ebl = &gameState.baseLines.entityBaselines[entindex];

			if ((*ebl)[baseLineIdx^1].properties.length == baseline.length)
			{
				newBaseline = (*ebl)[baseLineIdx^1].properties;
				newBaseline[] = baseline[];
			}
			else
			{
				(*ebl)[baseLineIdx^1].properties[] = null; // gc
				newBaseline = baseline.dup;
			}

			readEntProps!(/* doCopy */ true)(buf, newBaseline, gameState.classes[classid].flattenedProps);

			// [2]

			(*ebl)[baseLineIdx^1].valid = true;
			(*ebl)[baseLineIdx^1].classid = classid;
			(*ebl)[baseLineIdx^1].properties = newBaseline;

			// [3]

			newEnt.props = newBaseline.dup;
		}
		else
		{
			// 1. create entity from baseline
			// 2. apply network delta onto entity

			newEnt.props = baseline.dup;
			readEntProps!(/* doCopy */ true)(buf, newEnt.props, gameState.classes[classid].flattenedProps);
		}
	}

	static void processDelete(
		int entindex,
		GameState.Snapshot* from,
		GameState.Snapshot* to)
	{
		Entity oldEnt = from.entities[entindex];
		assert(oldEnt, "missing entity to delete");
		assert(oldEnt.inPvs, "delete entity not in pvs"); // seems to hold

		to.entities[entindex] = null;
	}

	static bool processDeleteNoCheck(
		int entindex,
		GameState.Snapshot* from,
		GameState.Snapshot* to)
	{
		// entity may or may not exist here
		// also may or may not be in pvs

		if (from.entities[entindex])
		{
			to.entities[entindex] = null;
			return true;
		}
		else
		{
			return false;
		}
	}
}

// -----------------------------------------------------------------------------

// src/Parser/EntityStuff/Entity.cs

final class Entity
{
	int               classid;
	int               serial;
	IEntityProperty[] props;
	bool              inPvs;
	int               updateTick;

	this(int classid, int serial, IEntityProperty[] props, bool inPvs = true)
	{
		this.classid = classid;
		this.serial = serial;
		this.props = props;
		this.inPvs = inPvs;
	}

	pragma(inline, true)
	auto prop(T)(string name, T defval = T.init) inout
	{
		int i = gameState.classes[classid].propertyIndex(name);
		if (i != -1)
		{
			// property might not have been set: skial/null2.dem
			if (auto prop = props[i])
				return prop.value!T;
		}
		return defval;
	}

	Entity shallowCopy()
	{
		Entity ent = new Entity(
			classid,
			serial,
			props.dup,
			inPvs
		);
		ent.updateTick = updateTick;
		return ent;
	}

	Entity shallowCopySameProps()
	{
		Entity ent = new Entity(
			classid,
			serial,
			props,
			inPvs
		);
		ent.updateTick = updateTick;
		return ent;
	}

	Entity shallowCopyNoProps()
	{
		Entity ent = new Entity(
			classid,
			serial,
			null,
			inPvs
		);
		ent.updateTick = updateTick;
		return ent;
	}
}

// -----------------------------------------------------------------------------

// src/Parser/EntityStuff/EntityProperty.cs

class IEntityProperty
{
	pragma(inline, true)
	final ref inout(T) value(T)() inout
	{
		auto self = cast(inout(EntityProperty!T))this;
		debug assert(this);
		assert(self);
		return self.value;
	}
}

final class EntityProperty(T) : IEntityProperty
{
	enum IsArray = is(T : X[], X) && !is(T == string);

	T value;

	this(T value)
	{
		this.value = value;
	}

	this()
	{
	}
}

// -----------------------------------------------------------------------------

// src/Parser/Components/Packets/StringTableEntryTypes/InstanceBaseline.cs

bool parseInstanceBaseline(bf_read buf, const(char)[] entryName)
{
	if (!gameState.classes.length)
		return false;

	int classid;
	int n;
	if (sscanf(entryName.ptr, "%03d%n", &classid, &n) != 1 || n != entryName.length)
		assert(0, "bad string table key in instance baselines");

	if (!(classid >= 0 && classid < gameState.classes.length))
	{
		static char[128] msg = 0;
		snprintf(msg.ptr, msg.length, "bad class id %d in instance baselines (max=%zu)",
			classid,
			gameState.classes.length);
		assert(0, msg.fromStringz);
	}

	if (TRACE1)
		printf("   instancebaselines %s\n", gameState.classes[classid].name.ptr);

	// hack: disable trace for this because it's not very interesting
	bool oldtrace = TRACE1;
	TRACE1 = false;

	gameState.baseLines.initialize();

	if (!gameState.baseLines.readInstanceBaseline(classid, buf))
		assert(0, "empty baseline");

	/*
	 * pitch can be set to a funny value in the class baseline: 2022-10-22_21-41-16.dem
	 * 
	 * hopefully their lifeState is correct so this doesn't cause problems...
	 */
	//if (gameState.classes[classid].name == "CTFPlayer")
	//{
	//	float* defaultPitch = &gameState.baseLines.getDefaultValue!float(classid, "tfnonlocaldata.m_angEyeAngles[0]");
	//
	//	if (*defaultPitch < -0x1.652d3p+6 || *defaultPitch > 0x1.652d2cp+6)
	//		printf("-note: default pitch is %f\n", *defaultPitch);
	//
	//	//if (*defaultPitch < -0x1.652d3p+6)
	//	//	*defaultPitch = -0x1.652d3p+6;
	//	//else if (*defaultPitch > 0x1.652d2cp+6)
	//	//	*defaultPitch = 0x1.652d2cp+6;
	//}

	TRACE1 = oldtrace;

	if (int rem = buf.GetNumBytesLeft()) // byte-aligned
	{
		static char[128] msg = 0;
		snprintf(msg.ptr, msg.length, "baseline parsing failed for class %d <%s>: %d byte(s) left over",
			classid,
			gameState.classes[classid].name.ptr,
			rem);
		assert(0, msg.fromStringz);
	}

	// this seems to pass here
	// only reached at the start of the demo though
	debug
	{
		auto cls = &gameState.classes[classid];
		if (cls.name == "CTFPlayer")
		{
			// should be 2
			//assert(gameState.baseLines.getDefaultValue!int(classid, "m_lifeState") != 0);
			// fails in skial/Boris.dem, wtf
		}
	}

	return true;
}

// -----------------------------------------------------------------------------

// src/Parser/GameState/EntityBaseLines.cs

struct BaseLines
{
	struct BaseLine
	{
		IEntityProperty[] properties;
	}
	BaseLine[] baselines;

	struct EntityBaseLine
	{
		bool              valid;
		int               classid;
		IEntityProperty[] properties;
	}
	EntityBaseLine[2][MAX_EDICTS] entityBaselines;

	void initialize()
	{
		if (!baselines)
			baselines = new BaseLine[gameState.classes.length];
	}

	// CBaseClientState::CopyEntityBaseline
	void copyEntityBaseLine(uint idx)
	{
		uint idxFrom = idx;
		uint idxTo = idx^1;

		foreach (i; 0..entityBaselines.length)
		{
			EntityBaseLine* from = &entityBaselines[i][idxFrom];
			EntityBaseLine* to = &entityBaselines[i][idxTo];

			if (!from.valid)
			{
				if (to.valid)
					to.properties[] = null; // gc
				to.valid = false;
				to.classid = 0;
				continue;
			}

			to.valid = true;
			to.classid = from.classid;

			// avoid dup if possible
			// the performance of this matters a lot (use gcopt=profile:1 to benchmark changes)

			if (to.properties.length == from.properties.length)
			{
				to.properties[] = from.properties[];
			}
			else
			{
				to.properties[] = null; // gc
				to.properties = from.properties.dup;
			}
		}
	}

	/**
	 * update the baseline by reading new properties from a buffer
	 */
	size_t readInstanceBaseline(int classid, bf_read buf)
	{
		FlattenedProp[] fProps = gameState.classes[classid].flattenedProps;

		BaseLine* baseline = &baselines[classid];

		if (!baseline.properties.length)
		{
			baseline.properties = new IEntityProperty[fProps.length];
			return readEntProps(buf, baseline.properties, fProps);
		}
		else
		{
			return readEntProps!(/* doCopy */ true, /* doClear */ true)(buf, baseline.properties, fProps);
		}
	}

	/**
	 * create a temp entity (they have nothing in the baseline)
	 */
	Entity createTempEntity(int classid) const
	{
		assert(!baselines[classid].properties.length);

		IEntityProperty[] props = new IEntityProperty[gameState.classes[classid].flattenedProps.length];

		enum serial = 0;
		enum inPvs = true;
		return new Entity(classid, serial, props, inPvs);
	}

	ref T getDefaultValue(T)(int classid, int propertyIndex)
	{
		// do the cast here so we can return a reference to the value
		auto prop = cast(EntityProperty!T)baselines[classid].properties[propertyIndex];
		return prop.value;
	}

	ref T getDefaultValue(T)(int classid, string propertyName)
	{
		return getDefaultValue!T(classid, gameState.classes[classid].propertyIndex(propertyName));
	}
}

// -----------------------------------------------------------------------------

// src/Parser/GameState/GameState.cs

struct GameState
{
	DataTablesManager dataTablesManager;

	struct Snapshot
	{
		EntitySnapshot entities;
		int serverTick;
		int deltaFrom;

		Snapshot* shallowCopy()
		{
			// i hope it does something reasonable with copying the big entity array.....
			return new Snapshot(entities, serverTick, deltaFrom);
		}
	}
	DList!(Snapshot*) snapshots;
	size_t            snapshotCount; // DList doesn't keep its length so here it is

	Snapshot* currentSnapshot()
	{
		return !snapshots.empty ? snapshots.back : null;
	}

	Snapshot* snapshotForTick(int tick)
	{
		foreach_reverse (snap; snapshots)
		{
			if (snap.serverTick == tick)
				return snap;
			if (snap.serverTick < tick)
				break;
		}
		return null;
	}

	/**
	 * get the current entity snapshot
	 * 
	 * this is for places that don't care about snapshots & just want to check
	 *  if an entity is there (and maybe get some property from it)
	 */
	ref const(Entity[MAX_EDICTS]) entities()
	{
		// fallback for when we don't have any entities yet (don't use)
		static immutable Entity[MAX_EDICTS] dontuse;

		if (!snapshots.empty)
			return snapshots.back.entities.entities;
		else
			return dontuse;
	}

	/// latest server tick from svc_tick
	int serverTick;

	BaseLines baseLines;

	struct DataTable
	{
		string          name;
		SendTableProp[] rawProps; /// discarded after parsing flattenedProps

		this(bf_read buf)
		{
			bool   needsDecoder = !!buf.ReadOneBit(); // unused
			string name         = buf.ReadDString().assumeUnique;
			int    numProps     = buf.ReadUBitLong(PROPINFOBITS_NUMPROPS);

			this.name = name;
			this.rawProps = uninitializedArray!(SendTableProp[])(numProps);

			foreach (ref propRef; this.rawProps)
				propRef = SendTableProp(buf);
		}
	}
	DataTable[] dataTables;

	struct Class
	{
		string          name;
		FlattenedProp[] flattenedProps;
		int[string]     propertyIndexCache;

		pragma(inline, true)
		int propertyIndex(string name)
		{
			if (int* p = name in propertyIndexCache)
				return *p;
			else
				return searchPropertyIndex(name);
		}

		pragma(inline, false)
		int searchPropertyIndex(string name)
		{
			foreach (i, prop; flattenedProps)
			{
				if (prop.name == name)
				{
					propertyIndexCache[name] = cast(int)i;
					return cast(int)i;
				}
			}

			fprintf(stderr, "%s: not found\n", name.ptr);

			propertyIndexCache[name] = -1;
			return -1;
		}
	}
	Class[] classes;

	void reset()
	{
		this.tupleof = this.init.tupleof;
	}
}
