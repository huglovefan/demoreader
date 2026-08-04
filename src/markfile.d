/**
 * mark players to add a bit of text before their name
 * 
 * the mark definitions are read from a file at startup
 */
module demoreader.markfile;

import core.stdc.stdlib : exit;
import std.file;
import std.stdio;

import core.stdc.stdio : stdout, stderr; // override std.stdio

struct Mark
{
	string color;
	string name;
}

Mark*[string] parseMarks(string path)
{
	Mark*[string] marks;
	Mark* curmark;

	if (!path.exists)
		return null;

	string stripPrefix(string self, string other)
	{
		return self.length >= other.length && self[0..other.length] == other ? self[other.length..$] : null;
	}

	foreach (line; File(path).byLineCopy)
	{
		if (!line.length || line[0] == '#')
			continue;

		if (line[0] == '!')
		{
			line = line[1..$];

			if (line == "new")
				curmark = new Mark;
			else if (string color = stripPrefix(line, "color="))
				curmark.color = color;
			else if (string name = stripPrefix(line, "name="))
				curmark.name = name;
			else
			{
				fprintf(stderr, "unknown line in mark file: %.*s\n", cast(int)line.length, line.ptr);
				exit(1);
			}
		}
		else if (line[0] == '[')
		{
			foreach (i, c; line)
			{
				if (c == ']')
				{
					line = line[0..i+1];
					break;
				}
			}

			assert(curmark);
			marks[line] = curmark;
		}
		else
		{
			fprintf(stderr, "unknown line in mark file: %.*s\n", cast(int)line.length, line.ptr);
			exit(1);
		}
	}

	return marks;
}
