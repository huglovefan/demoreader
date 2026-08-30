/**
 * print a byte array in human-readable form
 */
module demoreader.util.byteprinter;

import core.stdc.stdio;
import std.utf;

enum BYTEPRINTER_NO_UNICODE = 1; // disable utf-8 support, don't treat it as text
enum BYTEPRINTER_NO_TEXT = 2; // print bytes only

void printbytes(ubyte[] data, int flags = 0)
{
	bool advancePrintable(ref int i, ref bool hasalnum)
	{
		// printable ascii
		if (
			(data[i] >= ' ' && data[i] < 0x7f) ||
			data[i] == '\n' ||
			(data[i] == '\r' && i != data.length-1 && data[i+1] == '\n')) // \r if followed by \n
		{
			if (!hasalnum &&
				(data[i] >= 'A' && data[i] <= 'Z' ||
				data[i] >= 'a' && data[i] <= 'z' ||
				data[i] >= '0' && data[i] <= '9'))
				hasalnum = true;
			i++;
			return true;
		}
		// utf-8 start byte
		if (data[i] >= 0xc2 && data[i] <= 0xf4 && !(flags & BYTEPRINTER_NO_UNICODE))
		{
			// count continuation bytes
			int len;
			for (int j = i+1; j < data.length && j < i+4; j++)
			{
				if (data[j] >= 0x80 && data[j] <= 0xbf)
				{
					len++;
					continue;
				}
				else
				{
					break;
				}
			}
			// valid if start byte + 1-3 continuation bytes
			if (len && len < 4)
			{
				// validate character
				try
				{
					validate(cast(char[])data[i..i+1+len]);
				}
				catch (Throwable)
				{
					return false;
				}
				i++;
				i += len;
				hasalnum = true; // assume it might be alnum. valid utf-8 has less false positives anyway
				return true;
			}
		}
		return false;
	}

	printf("[");
	int i = 0;
	const(char)* sep = "";
	outer:
	while (i < data.length)
	{
		int j = i;
		bool alnum;
		if (!(flags & BYTEPRINTER_NO_TEXT))
		while (j < data.length)
		{
			if (advancePrintable(j, alnum))
			{
				continue;
			}
			else if (
				data[j] == 0 &&
				data[i] != '\n' && // doesn't start at a newline
				j != i && // not empty
				j != i+1 && // at least 2 chars
				alnum)
			{
				// print
				if (!(i % 4) && *sep) sep = "-";
				printf("%s\"", sep);
				sep = " ";
				for (;;)
				{
					char c = data[i++];
					if (c == '\n')
						printf("\\n");
					else if (c == 0)
						break;
					else
					{
						if (c == '"' || c == '\\')
							printf("\\");
						printf("%c", c);
					}
				}
				printf("\\0\"");
				continue outer;
			}
			else
			{
				// not a string
				break;
			}
		}
		if (!(i % 4) && *sep) sep = "-";
		printf("%s%02hhx", sep, data[i]);
		sep = " ";
		i++;
	}
	printf("]");
}
