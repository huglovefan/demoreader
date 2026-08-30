/**
 * data tables stuff
 * 
 * status: works, leave it alone now
 */
module demoreader.entitystuff.datatable;

import core.stdc.stdio;
import std.algorithm.mutation : swap;
import std.array;
import std.exception;
import demoreader.entitystuff;
import demoreader.entitystuff.decode;
import demoreader.globals;
import demoreader.stringtable;
import demoreader.valve.bitbuf;

enum SendPropType
{
	Int,
	Float,
	Vector3,
	Vector2,
	String,
	Array,
	DataTable,
}

enum PropFlag
{
	Unsigned       = 1<<0,
	Coord          = 1<<1,
	NoScale        = 1<<2,
	RoundDown      = 1<<3,
	RoundUp        = 1<<4,
	Normal         = 1<<5,
	Exclude        = 1<<6,
	XyzE           = 1<<7,
	InsideArray    = 1<<8,
	ProxyAlwaysYes = 1<<9,
	ChangesOften   = 1<<10,
	IsVectorElem   = 1<<11,
	Collapsible    = 1<<12,
	CoordMp        = 1<<13,
	CoordMpLp      = 1<<14,
	CoordMpInt     = 1<<15,
	VarInt         = Normal,
}

enum FloatParseType
{
	Standard,
	Coord,
	BitCoordMp,
	BitCoordMpLp,
	BitCoordMpInt,
	NoScale,
	Normal,
}

// -----------------------------------------------------------------------------

// src/Parser/Components/Packets/DataTables.cs

void parseDataTables(bf_read buf, ref const(StringTables) stringTables)
{
	alias DataTable = GameState.DataTable;
	alias Class = GameState.Class;

	// data tables (DT_SomeStuff)
	auto ap = appender!(DataTable[])();
	while (buf.ReadOneBit())
	{
		ap ~= DataTable(buf);
	}
	gameState.dataTables = ap[];

	// classes (CSomeStuff)
	int classCount = buf.ReadShort();
	auto cls = uninitializedArray!(Class[])(classCount);
	foreach (i, ref clsRef; cls)
	{
		int classid = buf.ReadShort();
		string name = cast(string)buf.ReadDString();
		string dataTableName = cast(string)buf.ReadDString();

		// same ones as we already have, no need to store them
		assert(classid == i);
		assert(dataTableName == gameState.dataTables[i].name);

		clsRef = Class(name);
	}
	gameState.classes = cls;

	// do the flattening
	DataTablesManager.flattenClasses();

	// parse instance baselines now that we're able to do that
	if (TRACE1)
		printf("  -> parse the stored instance baselines\n");
	auto st = stringTables.get("instancebaseline");
	assert(st, "missing instance baseline string table");
	foreach (ent; st.entries)
	{
		scope sbuf = new bf_read(ent.data);
		if (!parseInstanceBaseline(sbuf, ent.name))
			assert(0, "instance baseline wasn't parsed");
	}
}

// -----------------------------------------------------------------------------

// src/Parser/EntityStuff/SendTableProp.cs

struct SendTableProp
{
	SendPropType   type;
	string         name;
	PropFlag       flags;

	string         excludeDtName;
	alias          dataTableName = excludeDtName; /// for dt properties, this is what table to put there
	alias          excludeFromTable = excludeDtName; /// for exclude properties, this is what table to exclude the named property from

	float          lowValue;
	float          highValue;
	uint           numBits;

	uint           numElements;

	FloatParseType floatType = cast(FloatParseType)-1;

	this(bf_read buf)
	{
		type = cast(SendPropType)buf.ReadUBitLong(PROPINFOBITS_TYPE);
		name = cast(string)buf.ReadDString();
		flags = cast(PropFlag)buf.ReadUBitLong(PROPINFOBITS_FLAGS);

		if (type == SendPropType.DataTable || (flags & SPROP_EXCLUDE))
		{
			excludeDtName = cast(string)buf.ReadDString();
		}
		else
		{
			switch (type)
			{
				case SendPropType.Int:
				case SendPropType.String:
					lowValue = buf.ReadFloat();
					highValue = buf.ReadFloat();
					numBits = buf.ReadUBitLong(PROPINFOBITS_NUMBITS);
					break;
				case SendPropType.Float:
				case SendPropType.Vector3:
				case SendPropType.Vector2:
					floatType = getFloatParseType(flags);
					goto case SendPropType.Int;
				case SendPropType.Array:
					numElements = buf.ReadUBitLong(PROPINFOBITS_NUMELEMENTS);
					break;
				default:
					assert(0, "unknown send prop type");
			}
		}
	}
}

// -----------------------------------------------------------------------------

// src/Parser/GameState/DataTablesManager.cs

struct DataTablesManager
{
	alias DataTable = GameState.DataTable;

	static void flattenClasses()
	{
		DataTable*[string] tableLookup;

		foreach (ref dt; gameState.dataTables)
			tableLookup[dt.name] = &dt;

		foreach (classid, ref cls; gameState.classes)
		{
			DataTable* table = &gameState.dataTables[classid];

			nothing_t[Exclude] excludes;
			gatherExcludes(table, tableLookup, excludes);

			auto ap = appender!(FlattenedProp[])();
			gatherProps(cast(int)classid, table, excludes, tableLookup, "", ap, ap);
			auto fProps = ap[];

			sortProps(fProps);

			cls.flattenedProps = fProps;
		}

		// don't need these anymore
		foreach (ref dt; gameState.dataTables)
			dt.rawProps = null;
	}

	struct Exclude
	{
		string dataTableName;
		string propName;
	}

	static void gatherExcludes(
		const DataTable*         table,
		const DataTable*[string] tableLookup,
		ref nothing_t[Exclude]   excludes) pure
	{
		foreach (ref const(SendTableProp) sendProp; table.rawProps)
		{
			if (sendProp.type == SendPropType.DataTable)
			{
				const DataTable* subTable = tableLookup[sendProp.dataTableName];
				gatherExcludes(subTable, tableLookup, excludes);
			}
			else if (sendProp.flags & SPROP_EXCLUDE)
			{
				excludes[Exclude(sendProp.excludeFromTable, sendProp.name)] = nothing;
			}
		}
	}

	static void gatherProps(
		int                            classid,
		const DataTable*               table,
		const nothing_t[Exclude]       excludes,
		const DataTable*[string]       dataTableLookup,
		string                         prefix,
		ref Appender!(FlattenedProp[]) fPropsCurr,
		ref Appender!(FlattenedProp[]) fPropsTop) pure
	{
		// append to a temporary so props from descendants get added first, or something
		auto tmp = appender!(FlattenedProp[])();
		iterateProps(classid, table, excludes, dataTableLookup, prefix, tmp, fPropsTop);
		// write the result to top instead of current (why?)
		// for the top-level dt this makes no difference, but for struct/array
		//  properties this puts their properties earlier in the final list
		fPropsTop ~= tmp[];
	}

	static void iterateProps(
		int                            classid,
		const DataTable*               table,
		const nothing_t[Exclude]       excludes,
		const DataTable*[string]       dataTableLookup,
		string                         prefix,
		ref Appender!(FlattenedProp[]) fPropsCurr,
		ref Appender!(FlattenedProp[]) fPropsTop) pure
	{
		foreach (i, ref const(SendTableProp) prop; table.rawProps)
		{
			if (prop.flags & (PropFlag.Exclude | PropFlag.InsideArray))
				continue;

			if (Exclude(table.name, prop.name) in excludes)
				continue;

			if (prop.type == SendPropType.DataTable)
			{
				const DataTable* subTable = dataTableLookup[prop.dataTableName];

				if (prop.flags & PropFlag.Collapsible)
				{
					// base class (probably)

					iterateProps(classid, subTable, excludes, dataTableLookup, prefix, fPropsCurr, fPropsTop);
				}
				else
				{
					// struct/array property

					string subPrefix = prefix;

					if (prop.name.length)
					{
						auto ap = appender!(char[])();
						ap.reserve(prefix.length+prop.name.length+1);
						ap ~= prefix;
						ap ~= prop.name;
						ap ~= '.';
						subPrefix = ap[].assumeUnique;
					}

					gatherProps(classid, subTable, excludes, dataTableLookup, subPrefix, fPropsCurr, fPropsTop);
				}
			}
			else
			{
				auto ap = appender!(char[])();
				ap.reserve(prefix.length+prop.name.length+1);
				ap ~= prefix;
				ap ~= prop.name;
				ap ~= '\0';
				string name = ap[].assumeUnique[0..$-1];

				const(SendTableProp)* arrayElementProp;
				if (prop.type == SendPropType.Array)
					arrayElementProp = &table.rawProps[i-1];

				fPropsCurr ~= new FlattenedProp(name, &prop, arrayElementProp);
			}
		}
	}

	static void sortProps(FlattenedProp[] fProps) pure
	{
		size_t head = 0;

		foreach (ref prop; fProps)
		{
			if (prop.propInfo.flags & PropFlag.ChangesOften)
			{
				swap(prop, fProps[head++]);
			}
		}
	}
}

final class FlattenedProp
{
	const string name;
	const SendTableProp* propInfo;
	const SendTableProp* arrayElementPropInfo;

	this(string name, const SendTableProp* propInfo, const SendTableProp* arrayElementPropInfo) pure
	{
		this.name = name;
		this.propInfo = propInfo;
		this.arrayElementPropInfo = arrayElementPropInfo;
	}
}
