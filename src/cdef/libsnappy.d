/**
 * https://github.com/google/snappy/blob/main/snappy-c.h
 */
module demoreader.cdef.libsnappy;

version(linux)
	version(X86_64)
		version = no_dynamicload;

version(no_dynamicload)
	{}
else
	version = dynamicload;

enum snappy_status
{
	SNAPPY_OK = 0,
	SNAPPY_INVALID_INPUT = 1,
	SNAPPY_BUFFER_TOO_SMALL = 2,
}
alias SNAPPY_OK = snappy_status.SNAPPY_OK;
alias SNAPPY_INVALID_INPUT = snappy_status.SNAPPY_INVALID_INPUT;
alias SNAPPY_BUFFER_TOO_SMALL = snappy_status.SNAPPY_BUFFER_TOO_SMALL;

version(dynamicload)
{
	private alias snappy_uncompress_t = extern(C) snappy_status function(const ubyte* compressed,
	/**/                                                                 size_t compressed_length,
	/**/                                                                 ubyte* uncompressed,
	/**/                                                                 size_t* uncompressed_length) nothrow @nogc;

	static immutable snappy_uncompress_t snappy_uncompress;

	shared static this()
	{
		import core.sys.windows.winbase;
		import core.sys.windows.windef;

		version(Windows)
			HMODULE dll = LoadLibrary("libsnappy.dll");
		else
			void* dll = dlopen("libsnappy.so", RTLD_LAZY);

		if (!dll)
		{
			static extern(C) snappy_status stub(const ubyte* compressed,
			/**/                                size_t compressed_length,
			/**/                                ubyte* uncompressed,
			/**/                                size_t* uncompressed_length) nothrow @nogc
			{
				assert(0, "snappy library failed to load, decompression not available");
			}
			snappy_uncompress = &stub;
			return;
		}

		version(Windows)
			snappy_uncompress = cast(snappy_uncompress_t)GetProcAddress(dll, "snappy_uncompress");
		else
			snappy_uncompress = cast(snappy_uncompress_t)dlsym(dll, "snappy_uncompress");

		assert(snappy_uncompress);
	}
}
else
{
	pragma(lib, "snappy");
	extern(C) snappy_status snappy_uncompress(const ubyte* compressed,
	/**/                                      size_t compressed_length,
	/**/                                      ubyte* uncompressed,
	/**/                                      size_t* uncompressed_length) nothrow @nogc;
}
