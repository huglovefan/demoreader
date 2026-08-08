/**
 * implementation of game event stuff
 */
module demoreader.gameevent;

import core.stdc.stdio;
import std.array;
import demoreader.valve.bitbuf;

version = lazyParsing;

enum GameEventParamType : uint
{
	String = 1,
	Float  = 2,
	Long   = 3, // signed
	Short  = 4, // signed
	Byte   = 5, // unsigned
	Bool   = 6,
}

struct GameEvents
{
	GameEvent*[] defs;

	void reset()
	{
		defs = null;
	}

	GameEvent* get(uint id)
	{
		if (id < defs.length)
			return defs.ptr[id];
		else
			return null;
	}
}

// from: SvcGameEventList
// to:   SvcGameEvent
struct GameEvent
{
	alias Param = GameEventParam;
	alias ParamValue = GameEventParamValue;

	alias EagerArgs = GameEventArgsEager;
	alias LazyArgs = GameEventArgsLazy;

	uint    id;
	char[]  name;

	Param[] params;

	/*
	 * read arguments for this event from the bit buffer
	 */
	EagerArgs parseEager(bf_read buf)
	{
		auto parsed = appender!(ParamValue[])();
		parsed.reserve(params.length);

		foreach (ref p; params)
		{
			ParamValue pv = {spec: &p};
			final switch (p.type)
			{
				case Param.Type.String:
					pv.as.String = buf.ReadDString();
					break;
				case Param.Type.Float:
					pv.as.Float = buf.ReadBitFloat();
					break;
				case Param.Type.Long:
					static assert(typeof(buf.ReadLong()).min < 0); // signed
					pv.as.Signed = buf.ReadLong();
					break;
				case Param.Type.Short:
					static assert(typeof(buf.ReadShort()).min < 0); // signed
					pv.as.Signed = buf.ReadShort();
					break;
				case Param.Type.Byte:
					static assert(typeof(buf.ReadByte()).min == 0); // unsigned
					pv.as.Unsigned = buf.ReadByte();
					break;
				case Param.Type.Bool:
					pv.as.Bool = buf.ReadOneBit() & 1;
					break;
			}
			parsed ~= pv;
		}

		return EagerArgs(parsed[]);
	}

	LazyArgs parseLazy(bf_read buf)
	{
		return LazyArgs(buf, id);
	}

	version (lazyParsing)
	{
		alias parse = parseLazy;
		alias Args = LazyArgs;
	}
	else
	{
		alias parse = parseEager;
		alias Args = EagerArgs;
	}
}

/*
 * result of .parse() on a bit buffer
 */
struct GameEventArgsEager
{
	alias ParamValue = GameEventParamValue;

	enum parsed = true;
	ParamValue[] values;

	auto get(T)(const(char)[] name, ref GameEvents gameEvents)
	{
		foreach (ref v; values)
		{
			if (v.spec.name == name)
				return v.get!T;
		}
		debug
		{
			fprintf(stderr, "error: game event has no parameter named '%s'\n", name.ptr);
		}
		assert(0, "unknown game event parameter name");
	}

	auto get(T)(const(char)[] name, T defval, ref GameEvents gameEvents)
	{
		foreach (ref v; values)
		{
			if (v.spec.name == name)
				return v.get!T;
		}
		return defval;
	}

	bool has(const(char)[] name)
	{
		foreach (ref v; values)
		{
			if (v.spec.name == name)
				return true;
		}
		return false;
	}
}

/*
 * result of .parse() on a bit buffer (lazy version, parsing on the first access)
 */
struct GameEventArgsLazy
{
	alias EagerArgs = GameEventArgsEager;

	bf_read   buf;
	uint      eventId;

	bool      parsed;
	EagerArgs args;

	auto get(T)(const(char)[] name, ref GameEvents gameEvents)
	{
		if (!parsed)
			doParse(gameEvents);
		return args.get!T(name, gameEvents);
	}
	auto get(T)(const(char)[] name, T defval, ref GameEvents gameEvents)
	{
		if (!parsed)
			doParse(gameEvents);
		return args.get!T(name, defval, gameEvents);
	}

	void doParse(ref GameEvents gameEvents)
	{
		args = gameEvents.get(eventId).parseEager(buf);
		parsed = true;
	}
}

/*
 * information about a parameter (its name and type)
 */
struct GameEventParam
{
	alias Type = GameEventParamType;

	char[] name;
	Type   type;

static:
	string typeName(uint t)
	{
		final switch (t)
		{
			case Type.String: return "string";
			case Type.Float:  return "float";
			case Type.Long:   return "long";
			case Type.Short:  return "short";
			case Type.Byte:   return "byte";
			case Type.Bool:   return "bool";
		}
	}
}

/*
 * parsed parameter value (just a tagged union)
 */
struct GameEventParamValue
{
	alias Param = GameEventParam;

	union U
	{
		char[] String;
		float  Float;
		int    Signed;
		uint   Unsigned;
		bool   Bool;
	}

	Param* spec;
	U      as;

	T get(T)() if (is(T == char[]))
	{
		assert(spec.type == Param.Type.String);
		return as.String;
	}
	T get(T)() if (is(T == float))
	{
		assert(spec.type == Param.Type.Float);
		return as.Float;
	}
	T get(T)() if (is(T == bool))
	{
		assert(spec.type == Param.Type.Bool);
		return as.Bool;
	}

	uint get(T)() if (is(T == int) || is(T == short) || is(T == ubyte))
	{
		static if (is(T == int))
			enum wanttype = Param.Type.Long;
		static if (is(T == short))
			enum wanttype = Param.Type.Short;
		static if (is(T == ubyte))
			enum wanttype = Param.Type.Byte;

		debug
		{
			if (spec.type != wanttype)
			{
				fprintf(stderr, "-tried to get %s as %s but it is %s\n", spec.name.ptr, T.stringof.ptr, Param.typeName(spec.type).ptr);
				assert(0);
			}
		}
		else
		{
			assert(spec.type == wanttype);
		}

		static if (is(T == ubyte))
			return as.Unsigned;
		else
			return as.Signed;
	}

	// wrong sign versions
	T get(T)() if (is(T == uint))
	{
		static assert(0, "int arguments are signed, use .get!int(...) instead");
	}
	T get(T)() if (is(T == ushort))
	{
		static assert(0, "short arguments are signed, use .get!short(...) instead");
	}
	T get(T)() if (is(T == byte))
	{
		static assert(0, "byte arguments are unsigned, use .get!ubyte(...) instead");
	}
}
