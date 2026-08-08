/**
 * read a file byte-by-byte into numbers, arrays, structs, etc
 */
module demoreader.util.bytereader;

import core.sys.posix.fcntl;
import core.sys.posix.unistd;
import core.sys.linux.sys.mman;
import std.array : uninitializedArray;
import std.exception;
import std.file;
import std.stdio;
import std.string;

final class ByteReaderRangeException : Exception
{
	mixin basicExceptionCtors;
}

struct ByteReader
{
	ubyte[] data;
	ulong   totalSize; /// total size of the file on disk

	version(Posix)
	{
		private void*  mapbase; /// mmap base address
		private size_t mapsize; /// mmap total size
	}

	@disable this(this); // disallow copying (mmap file would need special care)

	/// current read offset from the beginning of the file
	ulong offset()
	{
		return totalSize-data.length;
	}

	size_t remaining()
	{
		return data.length;
	}

	this(string path, ulong offset, bool useMmap = true)
	{
		if (useMmap)
		{
			assert(!offset); // not implemented (currently isn't needed)
			createMmap(path);
			//totalSize = data.length;
			//// todo: when implemented, it should mmap only the required area
			//if (offset)
			//	data = data[offset..$];
		}
		else
		{
			createRead(path, offset);
		}
	}

	this(string path, bool useMmap = true)
	{
		this(path, 0, useMmap);
	}

	version(Posix)
	~this()
	{
		if (mapbase)
		{
			errnoEnforce(munmap(mapbase, mapsize) != -1, "failed to unmap file");
			mapbase = null;
		}
	}

	version(Windows)
	private void createMmap(string path)
	{
		createRead(path, /* offset */ 0);
	}

	version(Posix)
	private void createMmap(string path)
	{
		int fd = open(path.toStringz, O_RDONLY);
		errnoEnforce(fd != -1, "failed to open file");

		scope(exit)
			close(fd);

		stat_t sb = void;
		if (fstat(fd, &sb) == -1)
			errnoEnforce(0, "failed to stat file");

		// if not empty...
		// (mmap() can't do zero-length files)
		if (sb.st_size)
		{
			// 32-bit
			static if (size_t.sizeof < sb.st_size.sizeof)
			{
				enforce(sb.st_size <= size_t.max, "file too large to fit in memory");
			}

			void* p = mmap(null, cast(size_t)sb.st_size, PROT_READ, MAP_PRIVATE|MAP_POPULATE, fd, 0);
			errnoEnforce(p != MAP_FAILED, "failed to map file");

			data = (cast(ubyte*)p)[0..cast(size_t)sb.st_size];
			totalSize = sb.st_size;
			mapbase = p;
			mapsize = cast(size_t)sb.st_size;
		}
	}

	private void createRead(string path, ulong offset)
	{
		if (!offset)
		{
			data = cast(ubyte[])std.file.read(path);
			totalSize = data.length;
		}
		else
		{
			auto f = File(path);

			// get the size: seek to end, check file position
			f.seek(0, SEEK_END);
			totalSize = f.tell;

			// offset is in bounds (byte position or one past the end)
			assert(offset <= totalSize);

			// get & check size
			ulong readSize = totalSize-offset;
			static if (ulong.sizeof > size_t.sizeof)
				enforce(totalSize-offset <= size_t.max, "file too large to fit in memory");

			// if not empty...
			// (rawRead explodes if given an empty array for some reason)
			if (readSize)
			{
				// seek to requested offset and read the data
				f.seek(offset, SEEK_SET);
				data = uninitializedArray!(ubyte[])(cast(size_t)readSize);
				if (f.rawRead(data).length != data.length)
					assert(0, "short read");
			}
		}
	}

	void read(ubyte[] arg)
	{
		if (data.length >= arg.length)
		{
			arg.ptr[0..arg.length] = data.ptr[0..arg.length];
			data                   = data.ptr[arg.length..data.length];
		}
		else
		{
			boundsError();
		}
	}

	void skip(size_t bytes)
	{
		if (data.length >= bytes)
		{
			data = data.ptr[bytes..data.length];
		}
		else
		{
			boundsError();
		}
	}

	T read(T)()
	if (IsSafeToRead!T)
	{
		T arg = void;
		read((cast(ubyte*)&arg)[0..arg.sizeof]);
		return arg;
	}

	T read(T)(size_t length)
	if (IsSlice!T && IsSafeToRead!(ElementType!T))
	{
		alias X = ElementType!T;

		X[] arr = uninitializedArray!(X[])(length);
		read((cast(ubyte*)arr.ptr)[0..length*X.sizeof]);
		return arr;
	}
}

static assert( __traits(compiles, ByteReader.init.read!(int)()));
static assert( __traits(compiles, ByteReader.init.read!(int[1])()));
static assert(!__traits(compiles, ByteReader.init.read!(int*)())); // pointer
static assert(!__traits(compiles, ByteReader.init.read!(int*[1])())); // pointer

static assert( __traits(compiles, ByteReader.init.read!(int[])(1)));
static assert(!__traits(compiles, ByteReader.init.read!(int[1])(1))); // length with static array

// -----------------------------------------------------------------------------

private:

enum IsArithmetic(T)  = __traits(isArithmetic, T);
enum IsStaticArray(T) = __traits(isStaticArray, T);
enum IsStruct(T)      = is(T == struct);
enum IsUnion(T)       = is(T == union);
enum IsSlice(T)       = is(T == X[], X);
enum HasPointers(T)   = __traits(getPointerBitmap, T)[1] != 0;
alias ElementType(T : X[], X) = X;

// safe to read if:
// 1. it's a basic numeric type
// 2. it's a struct, union or static array that doesn't contain any pointers
enum IsSafeToRead(T) =
	IsArithmetic!T ||
	(IsStruct!T || IsUnion!T || IsStaticArray!T) && !HasPointers!T;

void boundsError()
{
	throw new ByteReaderRangeException("");
}
