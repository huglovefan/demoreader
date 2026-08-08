/**
 * watch a file/dir for changes
 */
module demoreader.util.filewatch;

import core.stdc.errno;
import core.stdc.limits : NAME_MAX;
import core.stdc.stdio;
import core.sys.linux.sys.inotify;
import core.sys.posix.fcntl;
import core.sys.posix.unistd;
import core.thread.osthread;
import core.time;
import std.exception;
import std.string;

version(Windows)
{
	import core.sys.windows.stat;
	import std.utf : toUTF16z;

	private alias stat_t = struct_stat;
}

struct FileWatch
{
	string path;
	stat_t sb;
	stat_t oldsb;

	this(string filePath)
	{
		int statrv;
		version(Windows)
			statrv = _wstat(filePath.toUTF16z, &sb);
		else
			statrv = stat(filePath.toStringz, &sb);

		if (statrv == -1)
			throw new ErrnoException("failed to stat "~filePath);

		path = filePath;
		oldsb = sb;
	}

	ulong currentSize()
	{
		return sb.st_size;
	}

	bool isFile()
	{
		return !S_ISDIR(sb.st_mode);
	}

	bool isDir()
	{
		return !!S_ISDIR(sb.st_mode);
	}

	/**
	 * check if the file has changed since the last call to hasChanged()/waitChanged()
	 */
	bool hasChanged()
	in (path)
	{
		stat_t newsb = void;

		int statrv;
		version(Windows)
			statrv = _wstat(path.toUTF16z, &newsb);
		else
			statrv = stat(path.toStringz, &newsb);

		if (statrv == -1)
		{
			// file became inaccessible
			// count as changed and let the caller receive the error

			// set max values to make sure the caller thinks it's changed
			newsb = stat_t.init;
			newsb.st_size  = stat_t().st_size.max;
			newsb.st_mtime = stat_t().st_mtime.max;

			oldsb = sb;
			sb = newsb;

			return true;
		}

		if (
			newsb.st_size  != sb.st_size || // data definitely changed
			newsb.st_mtime != sb.st_mtime)  // data possibly changed
		{
			oldsb = sb;
			sb = newsb;
			return true;
		}

		return false;
	}

	/**
	 * magically wait for a change to occur, then call hasChanged()
	 */
	version(linux)
	pragma(inline, false) // not performance-critical
	void waitChanged()
	in (path)
	{
		// check manually before doing the inotify thing
		if (hasChanged)
			return;

		/*
		 * boot up inotify
		 */

		int fd = inotify_init();
		if (fd == -1)
		{
			perror("inotify_init");
			return waitChangedFallback();
		}
		scope(exit)
			close(fd);

		/*
		 * add a watch for our file
		 */

		uint flags = IN_ATTRIB|IN_DELETE_SELF|IN_MOVE_SELF;
		if (isFile)
			flags |= IN_MODIFY;
		else
			flags |= IN_CREATE|IN_DELETE|IN_MOVED_FROM|IN_MOVED_TO;

		int watch = inotify_add_watch(fd, path.toStringz, flags);
		if (watch == -1)
		{
			int err = errno;

			// file became inaccessible?
			if (hasChanged)
				return;

			// inotify can't be used
			errno = err;
			perror("inotify_add_watch");
			return waitChangedFallback();
		}

		/*
		 * do the loop
		 */

		// check manually with the inotify fd added to fix a race condition
		// it could've changed between the first hasChanged and inotify_add_watch
		if (hasChanged)
			return;

		enum bufsize = inotify_event.sizeof + NAME_MAX + 1; // from inotify(7) man page
		for (;;)
		{
			ubyte[bufsize] buf = void;

			ssize_t rv = read(fd, buf.ptr, buf.length);
			if (rv == -1)
			{
				if (errno == EINTR)
					continue;

				throw new ErrnoException("error reading inotify event");
			}

			if (hasChanged)
				break;
		}
	}
	else // !version(linux)
	pragma(inline, false) // not performance-critical
	void waitChanged()
	in (path)
	{
		return waitChangedFallback();
	}

	pragma(inline, false)
	private void waitChangedFallback()
	{
		while (!hasChanged)
			Thread.sleep(1.seconds);
	}
}
