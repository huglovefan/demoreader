/**
 * core bits of bitbuf.d
 */
module demoreader.valve.bitbufpure;

import core.bitop : bsf;

// -----------------------------------------------------------------------------

/*
 * convert an arbitrary-bit unsigned number to signed
 * 
 * (what this really does is sign-extension with the sign being at an arbitrary position)
 */

auto toSigned(U)(U value, uint numbits)
if (__traits(isUnsigned, U))
{
	/**/ static if (is(U == ubyte )) alias S = byte;
	else static if (is(U == ushort)) alias S = short;
	else static if (is(U == uint  )) alias S = int;
	else static if (is(U == ulong )) alias S = long;
	else static assert(0, "no corresponding signed type for "~U.stringof);

	debug assert(numbits >= 2 && numbits <= U.sizeof*8);

	// no bits above "numbits" set
	debug assert(numbits == U.sizeof*8 || (value >> numbits) == 0);

	const U topbit = cast(U)( U(1) << (numbits-1) );
	if (value & topbit)
	{
		value ^= topbit;                 // remove sign bit
		value = cast(U)(topbit - value); // reverse value
		value = cast(U)-value;           // negate
	}

	return cast(S)value;
}

static assert(toSigned(ubyte(1), 8) is byte(1));
static assert(toSigned(ubyte(0xff), 8) is byte(-1));

static assert(toSigned(cast(ubyte )-42,  8) is byte (-42));
static assert(toSigned(cast(ushort)-42, 16) is short(-42));
static assert(toSigned(cast(uint  )-42, 32) is int  (-42));
static assert(toSigned(cast(ulong )-42, 64) is long (-42));

static assert(toSigned(uint(0b11), 2) is -1);
static assert(toSigned(uint(0b10), 2) is -2);
static assert(toSigned(uint(0b1111), 4) is -1);
static assert(toSigned(uint(0b1111_1111), 8) is -1);

// -----------------------------------------------------------------------------

// note: might read past the end if T is bigger than the remaining data

pragma(inline, true)
T PureReadOneBit(T)(const(T)* data, uint bitNum)
if (__traits(isUnsigned, T))
{
	enum SHIFT = bsf(T.sizeof*8);
	enum MASK  =    (T.sizeof*8)-1;

	return (data[bitNum >> SHIFT] >> (bitNum & MASK)) & 1;
}

// -----------------------------------------------------------------------------

// note: might read past the end by `ReadType.sizeof-1` bytes
// but using a bigger type here makes this faster

void PureReadBits(void* pOut, const(void)* pIn, uint readPos, uint readEnd)
{
	alias ReadType = size_t;

	static if (ReadType.sizeof >= 8)
	{
		while (readEnd-readPos >= 64)
		{
			*cast(ulong*)pOut = cast(ulong)PureReadUBitLong(cast(ReadType*)pIn, readPos, 64);
			pOut += 8;
			readPos += 64;
		}
	}

	while (readEnd-readPos >= 32)
	{
		*cast(uint*)pOut = cast(uint)PureReadUBitLong(cast(ReadType*)pIn, readPos, 32);
		pOut += 4;
		readPos += 32;
	}

	while (readEnd-readPos >= 8)
	{
		*cast(ubyte*)pOut = cast(ubyte)PureReadUBitLong(cast(ReadType*)pIn, readPos, 8);
		pOut += 1;
		readPos += 8;
	}

	if (readEnd-readPos)
	{
		*cast(ubyte*)pOut = cast(ubyte)PureReadUBitLong(cast(ReadType*)pIn, readPos, readEnd-readPos);
	}
}

// -----------------------------------------------------------------------------

/*
 * the algorithm goes as follows:
 * 
 * 1. convert the bit position to a dword position, then get the dword there
 * 2. right shift the dword value to skip low bits that have already been read
 * 3. mask it to remove extra high bits, so we return only the requested number of them
 * 
 * then, if the last bit would be part of the next dword, we need to read it too
 * 
 * 1. get the second dword
 * 2. mask it to include only the (low) bits we need
 * 3. shift it to the right position in the return value
 * 
 * [*] by "dword" i mean "whatever type T is"
 * 
 * based on:
 * https://github.com/Source-SDK-Archives/source-sdk-2006-ep1/blob/master/public/tier1/bitbuf.h#L591
 */

// note: might read past the end by `ReadType.sizeof-1` bytes
// but a bigger type is less likely to need to merge dwords = faster

T PureReadUBitLong(T = size_t)(const(T)* m_pData, uint bitPos, uint numBits)
if (__traits(isUnsigned, T))
{
	enum SHIFT = bsf(T.sizeof*8);
	enum MASK  =    (T.sizeof*8)-1;

	uint idword1 = bitPos >> SHIFT;
	T rv = (m_pData[idword1] >> (bitPos & MASK)) & ExtraMasks!T[numBits];

	uint idword2 = bitPos+numBits-1 >> SHIFT;
	if (idword2 != idword1)
	{
		uint dw2useBits = bitPos+numBits & MASK;

		rv |= (m_pData[idword2] & ExtraMasks!T[dw2useBits]) << (numBits - dw2useBits);
	}

	return rv;
}

private template ExtraMasks(T)
if (__traits(isUnsigned, T))
{
	static immutable ExtraMasks = {
		T[T.sizeof*8+1] rv = void;
		rv[0] = 0;
		rv[T.sizeof*8] = T.max;
		foreach (i, ref v; rv[1..$-1])
			v = cast(T)((T(1) << (i+1)) - 1);
		foreach (i; 0..T.sizeof*8)
			assert(rv[i] == (rv[i+1]>>1));
		return rv;
	}();
}

static assert(ExtraMasks!ubyte[0] == ubyte.min);
static assert(ExtraMasks!ubyte[1] == 1);
static assert(ExtraMasks!ubyte[7] == ubyte.max>>1);
static assert(ExtraMasks!ubyte[8] == ubyte.max);

static assert(ExtraMasks!ushort[ 0] == ushort.min);
static assert(ExtraMasks!ushort[ 1] == 1);
static assert(ExtraMasks!ushort[15] == ushort.max>>1);
static assert(ExtraMasks!ushort[16] == ushort.max);

static assert(ExtraMasks!uint[ 0] == uint.min);
static assert(ExtraMasks!uint[ 1] == 1);
static assert(ExtraMasks!uint[31] == uint.max>>1);
static assert(ExtraMasks!uint[32] == uint.max);

static assert(ExtraMasks!ulong[ 0] == ulong.min);
static assert(ExtraMasks!ulong[ 1] == 1);
static assert(ExtraMasks!ulong[63] == ulong.max>>1);
static assert(ExtraMasks!ulong[64] == ulong.max);
