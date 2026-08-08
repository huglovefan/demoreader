module demoreader.entitystuff.decode;

import core.stdc.stdio;
import core.bitop;
import std.array;
import std.math;
import demoreader.entitystuff;
import demoreader.entitystuff.datatable;
import demoreader.globals : TRACE1;
import demoreader.player : Player;
import demoreader.valve.bitbuf;

// -----------------------------------------------------------------------------

// src/Utils/BitStreams/PropDecodeReader.cs

/**
 * doCopy: don't modify existing properties, create copies of newly read ones instead
 * doClear: set all props that weren't read to null
 */
size_t readEntProps(bool doCopy = false, bool doClear = false)(bf_read buf, IEntityProperty[] entProps, const FlattenedProp[] fProps)
{
	int propIndex = -1;
	size_t count;

	// these should always match......... i think
	if (fProps.length)
		assert(entProps.length, "entity has no properties");
	assert(entProps.length == fProps.length, "entity has wrong number of properties");

	while (buf.ReadOneBit())
	{
		int prevPropIndex = propIndex;

		propIndex += cast(int)buf.ReadUBitVar()+1;
		count++;

		static if (doClear)
		{
			assert(propIndex > prevPropIndex);
			entProps[prevPropIndex+1..propIndex] = null;
		}

		const FlattenedProp fProp = fProps[propIndex];
		IEntityProperty *dst = &entProps[propIndex];

		alias Type = SendPropType;

		switch (fProp.propInfo.type)
		{
			case Type.Int:     updateFrom!(EntityProperty!int    , doCopy)(*dst, buf, fProp); break;
			case Type.Float:   updateFrom!(EntityProperty!float  , doCopy)(*dst, buf, fProp); break;
			case Type.Vector3: updateFrom!(EntityProperty!Vector3, doCopy)(*dst, buf, fProp); break;
			case Type.Vector2: updateFrom!(EntityProperty!Vector2, doCopy)(*dst, buf, fProp); break;
			case Type.String:  updateFrom!(EntityProperty!string , doCopy)(*dst, buf, fProp); break;
			case Type.Array:
			{
				switch (fProp.arrayElementPropInfo.type)
				{
					case Type.Int:     updateFrom!(EntityProperty!(int    []), doCopy)(*dst, buf, fProp); break;
					case Type.Float:   updateFrom!(EntityProperty!(float  []), doCopy)(*dst, buf, fProp); break;
					case Type.Vector3: updateFrom!(EntityProperty!(Vector3[]), doCopy)(*dst, buf, fProp); break;
					case Type.Vector2: updateFrom!(EntityProperty!(Vector2[]), doCopy)(*dst, buf, fProp); break;
					case Type.String:  updateFrom!(EntityProperty!(string []), doCopy)(*dst, buf, fProp); break;
					default:
						assert(0);
				}
				break;
			}
			default:
				assert(0);
		}
	}

	static if (doClear)
	{
		entProps[propIndex+1..$] = null;
	}

	return count;
}

void updateFrom(T, bool doCopy = false)(ref IEntityProperty self_, bf_read buf, const FlattenedProp fProp)
if (is(T : EntityProperty!U, U))
{
	alias PropType(_ : EntityProperty!X, X) = X;
	alias U = PropType!T;

	static if (T.IsArray)
	{
		alias ElementType(_ : X[], X) = X;
		alias V = ElementType!U;

		T self;

		static if (doCopy)
		{
			self = new T();
			self_ = self;
		}
		else
		{
			if (self_ is null)
			{
				self = new T();
				self_ = self;
			}
			else
			{
				self = cast(T)self_;
				assert(self);
			}
		}

		int needBits = highestBitIndex(fProp.propInfo.numElements);
		needBits += 1;

		int length = buf.ReadUBitLong(needBits);

		static if (doCopy)
			self.value = uninitializedArray!(V[])(length);
		else
			self.value.length = length;

		foreach (ref valRef; self.value)
			valRef = buf.decode!V(fProp.arrayElementPropInfo);

		if (TRACE1)
		{
			printf("    %s=[\n", fProp.name.ptr);
			foreach (i, val; self.value)
			{
				static if (is(V == int))
				{
					printf("      %d", val);
					if (fProp.arrayElementPropInfo.numBits == 21 && (fProp.arrayElementPropInfo.flags & PropFlag.Unsigned))
					{
						int entindex = val & 0x7ff;

						const(char)* name;

						static if (0) // TODO
						if (!name && entindex >= 1 && entindex <= Player.maxPlayers)
						{
							Player* pl = Player.getByEntIndex(entindex);
							if (pl)
								name = pl.ttyname;
						}

						if (!name)
						{
							auto ent = gameState.entities[entindex];
							if (ent)
								name = gameState.classes[ent.classid].name.ptr;
						}

						if (!name)
							name = "?";

						printf(" <entity %d: %s>", entindex, name);
					}
					printf(",\n");
				}
				static if (is(V == float))   printf("      %f,\n", val);
				static if (is(V == Vector3)) printf("      (%f %f %f),\n", val.x, val.y, val.z);
				static if (is(V == Vector2)) printf("      (%f %f),\n", val.x, val.y);
				static if (is(V == string))  printf("      %s,\n", val.ptr);
			}
			printf("    ]\n");
		}
	}
	else
	{
		U value = buf.decode!U(fProp.propInfo);

		T self;

		if (self_ is null)
		{
			self = new T(value);
			self_ = self;
		}
		else
		{
			self = cast(T)self_;
			assert(self);

			if (self.value is value)
			{
				// nothing to do, existing prop has the same value
				// pretend we never read it (skip the doCopy thing)
			}
			else
			{
				static if (doCopy)
				{
					self = new T(value);
					self_ = self;
				}
				else
				{
					self.value = value;
				}
			}
		}

		if (TRACE1)
		{
			static if (is(U == int))
			{
				if (fProp.propInfo.numBits == 21 && (fProp.propInfo.flags & PropFlag.Unsigned))
				{
					int entindex = self.value & 0x7ff;

					const(char)* classname = "?";
					int pvs = -1;
					if (auto ent = gameState.entities[entindex])
					{
						classname = gameState.classes[ent.classid].name.ptr;
						pvs = ent.inPvs;
					}
					static if (0) // TODO
					if (entindex >= 1 && entindex <= Player.maxPlayers)
					{
						if (Player* pl = Player.getByEntIndex(entindex))
							classname = pl.ttyname;
					}

					printf("    %s=%d <entity %d: %s pvs=%d>\n", fProp.name.ptr, self.value, entindex, classname, pvs);
				}
				else
				{
					printf("    %s=%d\n", fProp.name.ptr, self.value);
				}
			}
			static if (is(U == float))   printf("    %s=%f\n", fProp.name.ptr, self.value);
			static if (is(U == Vector3)) printf("    %s=(%f %f %f)\n", fProp.name.ptr, self.value.x, self.value.y, self.value.z);
			static if (is(U == Vector2)) printf("    %s=(%f %f)\n", fProp.name.ptr, self.value.x, self.value.y);
			static if (is(U == string))  printf("    %s=%s\n", fProp.name.ptr, self.value.ptr);
		}
	}
}

T decode(T)(bf_read buf, const SendTableProp* propInfo)
if (is(T == int))
{
	if (propInfo.flags & PropFlag.VarInt)
	{
		return (propInfo.flags & PropFlag.Unsigned)
			? buf.ReadVarInt32()
			: buf.ReadSignedVarInt32();
	}
	else
	{
		return (propInfo.flags & PropFlag.Unsigned)
			? buf.ReadUBitLong(propInfo.numBits)
			: buf.ReadSBitLong(propInfo.numBits);
	}
}

T decode(T)(bf_read buf, const SendTableProp* propInfo)
if (is(T == float))
{
	alias Type = FloatParseType;

	final switch (propInfo.floatType)
	{
		case Type.Standard:      return buf.readStandardFloat(propInfo);
		case Type.Coord:         return buf.ReadBitCoord();
		case Type.BitCoordMp:    return buf.ReadBitCoordMP!(kCW_None);
		case Type.BitCoordMpLp:  return buf.ReadBitCoordMP!(kCW_LowPrecision);
		case Type.BitCoordMpInt: return buf.ReadBitCoordMP!(kCW_Integral);
		case Type.NoScale:       return buf.ReadFloat();
		case Type.Normal:        return buf.ReadBitNormal();
	}
}

T decode(T)(bf_read buf, const SendTableProp* propInfo)
if (is(T == Vector3))
{
	Vector3 vec3 = {
		x: buf.decode!float(propInfo),
		y: buf.decode!float(propInfo),
	};

	if (propInfo.floatType == FloatParseType.Normal)
	{
		uint sign = buf.ReadOneBit();
		float distSqr = vec3.x*vec3.x + vec3.y*vec3.y;
		if (distSqr < 1)
			vec3.z = sqrt(1 - distSqr);
		else
			vec3.z = 0;
		if (sign)
			vec3.z = -vec3.z;
	}
	else
	{
		vec3.z = buf.decode!float(propInfo);
	}

	return vec3;
}

T decode(T)(bf_read buf, const SendTableProp* propInfo)
if (is(T == Vector2))
{
	Vector2 vec2 = {
		x: buf.decode!float(propInfo),
		y: buf.decode!float(propInfo),
	};

	return vec2;
}

T decode(T)(bf_read buf, const SendTableProp* propInfo)
if (is(T == string))
{
	int length = buf.ReadUBitLong(9);

	char[] bytes = uninitializedArray!(char[])(length+1);
	buf.ReadBytes(bytes.ptr, length);
	bytes[length] = 0;

	return cast(string)bytes[0..length];
}

float readStandardFloat(bf_read buf, const SendTableProp* propInfo)
{
	// "dwInterp"
	float meaninglessname = cast(float)buf.ReadUBitLong(propInfo.numBits);

	float meaninglessname_max = cast(float)((1 << propInfo.numBits) - 1);

	// 0 to 1.0
	float fraction = meaninglessname / meaninglessname_max;

	float start = propInfo.lowValue;
	float range = (propInfo.highValue - propInfo.lowValue);

	return start + range*fraction;
}

FloatParseType getFloatParseType(PropFlag flags) pure
{
	alias Flag = PropFlag;
	alias ParseType = FloatParseType;

	ParseType type = ParseType.Standard;

	/**/ if (flags & Flag.Coord)      type = ParseType.Coord;
	else if (flags & Flag.CoordMp)    type = ParseType.BitCoordMp;
	else if (flags & Flag.CoordMpLp)  type = ParseType.BitCoordMpLp;
	else if (flags & Flag.CoordMpInt) type = ParseType.BitCoordMpInt;
	else if (flags & Flag.NoScale)    type = ParseType.NoScale;
	else if (flags & Flag.Normal)     type = ParseType.Normal;

	return type;
}

// -----------------------------------------------------------------------------

// src/Utils/ParserUtils.cs

int highestBitIndex(uint i)
{
	debug assert(i); // bsr is undefined for zero
	return bsr(i);
}
