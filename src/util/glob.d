/**
 * D-ish wrapper for glob(), matching directory entries by a unix glob pattern
 */
module demoreader.util.glob;

// fallback implementation for windows using dirEntries
// this works but it has more primitive globbing syntax (no [a-z] ranges, no
//  {a,b,c} alternations, no "**/pat" to search recursively)
version(Windows)
{
	import std.file;
	import std.path;

	string[] dirGlob(string dir, string pattern)
	{
		string[] rv;
		foreach (ent; dirEntries(dir, pattern, SpanMode.shallow))
		{
			rv ~= ent.baseName;
		}
		return rv;
	}
}
else:

import core.stdc.errno;
import core.stdc.stdio;
import core.stdc.string;
import core.sys.posix.fcntl;
import core.sys.posix.unistd;
import std.array;
import std.exception;
import std.path;
import std.string;

string[] dirGlob(string dir, string pattern)
{
	// save the current working directory to restore it later

	int oldpwd = open(".", O_PATH);
	if (oldpwd == -1)
		throw new ErrnoException("failed to save working directory");

	scope(exit)
		close(oldpwd);

	// change to the target directory

	if (chdir(dir.toStringz) == -1)
	{
		// target dir doesn't exist
		// just pretend the glob returned nothing
		if (errno == ENOENT)
			return null;

		throw new ErrnoException("failed to search "~dir);
	}

	scope(exit)
	{
		if (fchdir(oldpwd) == -1)
		{
			fprintf(stderr, "fchdir %d: %s\n", oldpwd, strerror(errno));

			// can't reasonably recover from this
			assert(0, "failed to restore working directory");
		}
	}

	// perform glob

	glob_t gl;

	int rv = glob(pattern.toStringz, GLOB_BRACE, /* errfunc */ null, &gl);
	debug gl.check();

	scope(exit)
	{
		globfree(&gl);
		debug gl.check();
	}

	if (rv != 0)
	{
		if (rv == GLOB_NOSPACE)
			throw new Exception("glob failed (out of memory)");

		if (rv == GLOB_ABORTED)
			throw new Exception("glob failed (read error)");
	}

	// convert the results to D strings (paths relative to target directory)

	auto ap = appender!(string[]);

	foreach (i; 0..gl.pathc)
	{
		ap ~= dir.buildNormalizedPath(gl.pathv[i].fromStringz);
	}

	return ap[];
}

unittest
{
	import std.algorithm;
	import std.file;
	string oldpwd = std.file.getcwd();

	assert("/".dirGlob("*").canFind("/tmp"));
	assert("/".dirGlob("t*").canFind("/tmp"));
	assert(!"/".dirGlob("z*").canFind("/tmp"));

	assert("/".dirGlob(".") == ["/"]);
	assert("/tmp".dirGlob(".") == ["/tmp"]);

	assert("/nonexistent".dirGlob(".") is null);
	assert("/".dirGlob("nonexistent") is null);

	assert(std.file.getcwd() == oldpwd);
}

private:

enum GLOB_NOSPACE = 1;
enum GLOB_ABORTED = 2;

enum GLOB_BRACE = 1 << 10; // enable the {a,b,c} alternation syntax

extern(C) int glob(const(char)* pattern, int flags, glob_errfunc_t errfunc, glob_t* pglob) nothrow;
extern(C) void globfree(glob_t* pglob) nothrow;
struct glob_t
{
	size_t pathc;
	char** pathv;
	size_t offs;
	int    flags;
	// debug: detect mismatches between this struct and the C library's version
	// this specifically catches writes to nonexistent members past the ones defined here
	debug
	{
		align(1) ubyte[size_t.sizeof*10] padding = 42;
		void check()
		{
			foreach (b; padding)
				assert(b == 42);
		}
	}
}
alias glob_errfunc_t = extern(C) int function(const(char)* epath, int eerrno) nothrow;
