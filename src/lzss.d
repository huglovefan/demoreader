/**
 * lzss decompression (for ancient demos that aren't using snappy instead)
 */
module demoreader.lzss;

import core.stdc.stdio;

// test demo:
// https://web.archive.org/web/20160813103712/https://dl.dropboxusercontent.com/u/31103105/benchmark1.dem
// https://github.com/ValveSoftware/Source-1-Games/issues/1056
// posted on github 2013-07-11, highest steamid in the demo joined 2011-10-19
// so it's from around that time frame
// the demo has "Build: 4769" but i don't know where to look that up to find its date

ubyte[] LZSS_Uncompress(const ubyte[] pInput, ubyte[] pOutput) @safe
{
	uint actualSize = pInput[0]
	/**/            | pInput[1] << 8
	/**/            | pInput[2] << 16
	/**/            | pInput[3] << 24;

	assert(pOutput.length >= actualSize, "lzss decompression error: output buffer too small");

	size_t inidx = 4;
	size_t outidx;

	uint cmdByte;
	for (size_t loopIdx = 0; /* true */; loopIdx++)
	{
		if ((loopIdx % 8) == 0)
			cmdByte = pInput[inidx++];

		bool doCopy = cmdByte & 1;
		cmdByte >>= 1;

		if (doCopy)
		{
			uint b1 = pInput[inidx++]; // part of offset
			uint b2 = pInput[inidx++]; // part of offset + repeat count

			uint length = (b2 & 0b1111) + 1;
			if (length == 1)
				break;

			uint offset = b1 << 4
			/**/        | b2 >> 4;
			size_t startidx = (outidx-1) - offset;

			// note: might overlap, assign byte by byte
			foreach (i; 0..length)
				pOutput[outidx+i] = pOutput[startidx+i];

			outidx += length;
		} 
		else
		{
			pOutput[outidx++] = pInput[inidx++];
		}
	}

	assert(outidx == actualSize, "lzss decompression error: wrong decompressed size");

	return pOutput[0..outidx];
}
