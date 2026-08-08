module demoreader.valve.bitbuf;

import core.stdc.stdio;
import std.array : uninitializedArray;
import demoreader.util.byteprinter;
import demoreader.valve.bitbufpure;
import demoreader.valve.demofile : Vector;

final class bf_read
{
	private
	{
		// The current buffer.
		const(ubyte)* m_pData;
		uint          m_nDataBits;

		// Where we are in the buffer.
		uint          m_iCurBit;
	}

	this(const(void)[] data, uint nBits = -1)
	{
		StartReading(data, nBits);
	}

	/**
	 * create a new bf_read to contain just the next "nBits" bits from the
	 *  existing buffer
	 * 
	 * this'll skip over the bits in the old buffer
	 * 
	 * note: the beginning of the buffer is the same, so Seek(0) might cause you
	 *  to lose your position and GetNumBitsRead() might return non-zero
	 */
	this(bf_read buf, uint nBits)
	{
		buf.CheckOverflow(nBits);

		const(ubyte)[] data = buf.m_pData[0..cast(size_t)buf.m_nDataBits*8];

		uint bufBitsRead = buf.GetNumBitsRead();

		StartReading(data, bufBitsRead+nBits);
		m_iCurBit += bufBitsRead;

		buf.m_iCurBit += nBits;
	}

	void StartReading(const(void)[] data, uint nBits = -1)
	{
		if (nBits == -1)
		{
			debug assert(data.length <= uint.max/8);
			nBits = cast(uint)(data.length*8);
		}
		else
		{
			assert(BitByte(nBits) <= data.length);
		}

		m_pData = cast(ubyte*)data.ptr;
		m_nDataBits = nBits;
		m_iCurBit = 0;
	}

	void Reset()
	{
		m_iCurBit = 0;
	}

	void Seek(int pos)
	{
		// allow setting the pos to length+1 (fully consumed)
		if (pos >= 0 && pos <= m_nDataBits)
			m_iCurBit = pos;
		else
		{
			debug printf("pos=%d\n", pos);
			assert(0, "bf_read: bad seek");
		}
	}

	void CheckOverflow(uint nBits)
	{
		debug
		{
			if (nBits > GetNumBitsLeft())
			{
				printf("have=%u want=%u\n", GetNumBitsLeft(), nBits);
				assert(0, "bf_read overflow");
			}
		}
		else
		{
			pragma(inline, true);
			assert(nBits <= GetNumBitsLeft(), "bf_read overflow");
		}
	}

	uint GetNumBitsRead()
	{
		return m_iCurBit;
	}

	uint GetNumBitsLeft()
	{
		return m_nDataBits - m_iCurBit;
	}

	uint GetNumBytesLeft()
	{
		return (m_nDataBits - m_iCurBit) / 8;
	}

	// debug
	int PeekBit(int ahead)
	{
		if (GetNumBitsLeft() < ahead+1)
			return -1;
		auto oldpos = m_iCurBit;
		m_iCurBit += ahead;
		uint rv = ReadOneBit();
		m_iCurBit = oldpos;
		return rv;
	}

	pragma(inline, false)
	void PrintBytes(const(char)* name = null)
	{
		if (name)
			printf("%s: ", name);

		if (!GetNumBitsLeft())
		{
			printf("(null)\n");
			return;
		}

		uint needBytes = BitByte(GetNumBitsLeft());

		ubyte[512] stackbuf = void;
		ubyte[] tmp;
		if (needBytes <= stackbuf.length)
			tmp = stackbuf[0..needBytes];
		else
			tmp = uninitializedArray!(ubyte[])(needBytes);

		tmp[$-1] = 0;
		PureReadBits(tmp.ptr, m_pData, m_iCurBit, m_iCurBit+GetNumBitsLeft());
		printbytes(tmp);
		printf(" (%u bytes + %u bits)\n", GetNumBytesLeft(), GetNumBitsLeft % 8);
	}

	//
	// reading: basic functions
	//

	uint ReadOneBit()
	{
		CheckOverflow(1);
		return PureReadOneBit(m_pData, m_iCurBit++ /* increment */);
	}

	uint ReadUBitLong(uint numbits)
	{
		debug assert(numbits >= 1 && numbits <= 32);

		CheckOverflow(numbits);

		uint pos = m_iCurBit;
		m_iCurBit = pos+numbits;

		return cast(uint)PureReadUBitLong(cast(size_t*)m_pData, pos, numbits);
	}

	int ReadSBitLong(uint numbits)
	{
		debug assert(numbits >= 2 && numbits <= 32);

		CheckOverflow(numbits);

		uint pos = m_iCurBit;
		m_iCurBit = pos+numbits;

		uint r = cast(uint)PureReadUBitLong(cast(size_t*)m_pData, pos, numbits);

		return toSigned(r, numbits);
	}

	void ReadBits(void* pOutData, uint nBits)
	{
		CheckOverflow(nBits);

		uint readPos = m_iCurBit;
		m_iCurBit = readPos+nBits;

		PureReadBits(pOutData, m_pData, readPos, readPos+nBits);
	}

	void ReadBytes(void* pOut, size_t nBytes)
	{
		debug assert(nBytes <= uint.max/8);
		ReadBits(pOut, cast(uint)(nBytes*8));
	}

	//
	// reading: type wrappers
	//

	uint ReadByte()
	{
		return ReadUBitLong(ubyte.sizeof * 8);
	}
	alias ReadChar = ReadByte; // same thing

	int ReadShort()
	{
		return ReadSBitLong(short.sizeof * 8);
	}

	uint ReadWord()
	{
		return ReadUBitLong(ushort.sizeof * 8);
	}

	int ReadLong()
	{
		return ReadSBitLong(int.sizeof * 8);
	}

	float ReadFloat()
	{
		union U
		{
			uint  a;
			float b;
		}
		return U(ReadUBitLong(32)).b;
	}
	alias ReadBitFloat = ReadFloat; // same thing

	//
	// reading: varint stuff
	//

	// simplified version from UncraftedDemoParser
	uint ReadUBitVar()
	{
		final switch (ReadUBitLong(2))
		{
			case 0: return ReadUBitLong(4);
			case 1: return ReadUBitLong(8);
			case 2: return ReadUBitLong(12);
			case 3: return ReadUBitLong(32);
		}
	}

	uint ReadVarInt32()
	{
		uint result;
	
		foreach (i; 0..kMaxVarint32Bytes)
		{
			uint b = ReadUBitLong(8);
			result |= (b & 0x7f) << (7 * i);
			if (!(b & 0x80))
				break;
		}
	
		return result;
	}

	int ReadSignedVarInt32()
	{
		uint value = ReadVarInt32();
		static int ZigZagDecode32(uint n) 
		{
			return (n >> 1) ^ -cast(int)(n & 1);
		}
		return ZigZagDecode32(value);
	}

	//
	// reading: floats and angles/coordinates
	//

	float ReadBitAngle(uint numbits)
	{
		float shift = cast(float)GetBitForBitnum(numbits);

		int i = ReadUBitLong(numbits);
		float fReturn = cast(float)i * (360.0f / shift);

		return fReturn;
	}

	float ReadBitNormal()
	{
		bool sign = !!ReadOneBit();

		int fractVal = ReadUBitLong(NORMAL_FRACTIONAL_BITS);

		float value = cast(float)fractVal * NORMAL_RESOLUTION;

		if (sign)
			value = -value;

		return value;
	}

	float ReadBitCoord()
	{
		float value = 0;

		bool hasIntVal = !!ReadOneBit();
		bool hasFractVal = !!ReadOneBit();

		if (hasIntVal || hasFractVal)
		{
			bool sign = !!ReadOneBit();

			int intVal;
			if (hasIntVal)
				intVal = ReadUBitLong(COORD_INTEGER_BITS) + 1;

			int fractVal;
			if (hasFractVal)
				fractVal = ReadUBitLong(COORD_FRACTIONAL_BITS);

			value = intVal + (cast(float)fractVal * COORD_RESOLUTION);

			if (sign)
				value = -value;
		}

		return value;
	}

	float ReadBitCoordMP(EBitCoordType type)()
	{
		float	value = 0;
		bool sign;

		uint isInBounds = ReadOneBit();

		static if (type == kCW_Integral)
		{
			if (ReadOneBit())
			{
				sign = !!ReadOneBit();

				if (isInBounds)
					value = ReadUBitLong(COORD_INTEGER_BITS_MP) + 1;
				else
					value = ReadUBitLong(COORD_INTEGER_BITS) + 1;
			}
		}
		else
		{
			bool hasIntVal = !!ReadOneBit();

			sign = !!ReadOneBit();

			int intVal;
			if (hasIntVal)
			{
				if (isInBounds)
					intVal = ReadUBitLong(COORD_INTEGER_BITS_MP) + 1;
				else
					intVal = ReadUBitLong(COORD_INTEGER_BITS) + 1;
			}

			static if (type == kCW_LowPrecision)
			{
				enum fractBits = COORD_FRACTIONAL_BITS_MP_LOWPRECISION;
				enum resolution = COORD_RESOLUTION_LOWPRECISION;
			}
			else
			{
				enum fractBits = COORD_FRACTIONAL_BITS;
				enum resolution = COORD_RESOLUTION;
			}

			int fractVal = ReadUBitLong(fractBits);

			value = intVal + (cast(float)fractVal * resolution);
		}

		if (sign)
			value = -value;

		return value;
	}

	void ReadBitVec3Coord(ref Vector fa)
	{
		// This vector must be initialized! Otherwise, If any of the flags aren't set,
		// the corresponding component will not be read and will be stack garbage.
		fa.Init(0, 0, 0);
		// ^ if you didn't know that by now, you're probably going to get fired

		uint xflag = ReadOneBit();
		uint yflag = ReadOneBit();
		uint zflag = ReadOneBit();

		if (xflag)
			fa[0] = ReadBitCoord();
		if (yflag)
			fa[1] = ReadBitCoord();
		if (zflag)
			fa[2] = ReadBitCoord();
	}

	//
	// reading: D stuff
	//

	/**
	 * read a GC-allocated string from the buffer
	 */
	char[] ReadDString()
	{
		/*
		 * if we happen to be byte-aligned, we can search the buffer directly
		 * 
		 * (the if-else is swapped to have the common case first)
		 */

		CheckOverflow(8);

		if (m_iCurBit % 8)
		{
			// uh, it turns out that strings in bitbufs usually aren't very long
			// so this can get away with a hardcoded length limit
			StringReadBuf!256 sb;
			for (;;)
			{
				assert(!sb.full, "bf_read: string exceeds hardcoded length limit");
				uint c = ReadChar();
				sb ~= cast(char)c;
				if (!c)
					break;
			}
			if (sb.length > 1)
				return sb[].dup.ptr[0..sb.length-1];
			else
				return null;
		}
		else
		{
			char* base = cast(char*)&m_pData[m_iCurBit/8];
			foreach (i, c; base[0..GetNumBytesLeft()])
			{
				if (!c)
				{
					m_iCurBit += (i+1)*8;
					if (i != 0)
						return base[0..i+1].dup.ptr[0..i];
					else
						return null;
				}
			}
			// shouldn't happen
			assert(0, "bf_read: unterminated string");
		}
	}

	/**
	 * read a GC-allocated byte array
	 */
	ubyte[] ReadDByteArray(size_t length)
	{
		ubyte[] data = uninitializedArray!(ubyte[])(length);

		ReadBytes(data.ptr, length);

		return data;
	}

	/**
	 * read a GC-allocated bit array
	 */
	ubyte[] ReadDBitArray(uint length)
	{
		ubyte[] data = uninitializedArray!(ubyte[])(BitByte(length));

		ReadBits(data.ptr, length);

		return data;
	}
}

// -----------------------------------------------------------------------------

public:

// -----------------------------------------------------------------------------

/*
 * demofilebitbuf.h
 * https://github.com/ValveSoftware/csgo-demoinfo/blob/571604c/demoinfogo/demofilebitbuf.h
 */

enum EBitCoordType
{
	kCW_None,
	kCW_LowPrecision,
	kCW_Integral,
}
alias kCW_None = EBitCoordType.kCW_None;
alias kCW_LowPrecision = EBitCoordType.kCW_LowPrecision;
alias kCW_Integral = EBitCoordType.kCW_Integral;

// -----------------------------------------------------------------------------

private:

// -----------------------------------------------------------------------------

/// bit count to byte count (rounded up)
pragma(inline, true)
T BitByte(T)(T v)
{
	//return v + 7 >> 3; // not overflow-safe!!
	return v / 8 + !!(v % 8);
}

static assert(BitByte(0) == 0);
static assert(BitByte(1) == 1);
static assert(BitByte(7) == 1);
static assert(BitByte(8) == 1);
static assert(BitByte(9) == 2);
static assert(BitByte(uint.max) == 536870912);
static assert(BitByte(ulong.max) == 2305843009213693952);

// -----------------------------------------------------------------------------

/*
 * demofilebitbuf.h
 * https://github.com/ValveSoftware/csgo-demoinfo/blob/571604c/demoinfogo/demofilebitbuf.h
 */

// OVERALL Coordinate Size Limits used in COMMON.C MSG_*BitCoord() Routines (and someday the HUD)
enum COORD_INTEGER_BITS    = 14;
enum COORD_FRACTIONAL_BITS = 5;
enum COORD_DENOMINATOR     = 1<<COORD_FRACTIONAL_BITS;
enum COORD_RESOLUTION      = 1.0f/COORD_DENOMINATOR;

// Special threshold for networking multiplayer origins
enum COORD_INTEGER_BITS_MP                 = 11;
enum COORD_FRACTIONAL_BITS_MP_LOWPRECISION = 3;
enum COORD_DENOMINATOR_LOWPRECISION        = 1<<COORD_FRACTIONAL_BITS_MP_LOWPRECISION;
enum COORD_RESOLUTION_LOWPRECISION         = 1.0f/COORD_DENOMINATOR_LOWPRECISION;

enum NORMAL_FRACTIONAL_BITS = 11;
enum NORMAL_DENOMINATOR     = (1<<NORMAL_FRACTIONAL_BITS) - 1;
enum NORMAL_RESOLUTION      = 1.0f/NORMAL_DENOMINATOR;

enum kMaxVarintBytes = 10;
enum kMaxVarint32Bytes = 5;

pragma(inline, true)
uint GetBitForBitnum(uint bitNum)
{
	return 1 << (bitNum % 32); 
}

// -----------------------------------------------------------------------------

// for ReadDString()
// assumes that you check full() before every append (there's no automatic overflow checking)
struct StringReadBuf(size_t capacity)
{
	size_t length;
	char[capacity] data = void;

	pragma(inline, true)
	void opOpAssign(string op)(char c) if (op == "~")
	{
		data.ptr[length++] = c;
	}

	pragma(inline, true)
	char[] opSlice()
	{
		return data.ptr[0..length];
	}

	pragma(inline, true)
	bool full()
	{
		return length == capacity;
	}
}
