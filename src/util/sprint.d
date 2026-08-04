/**
 * printf to string
 */
module demoreader.util.sprint;

import core.stdc.stdarg;
import core.stdc.stdio;

/// printf to a thread-local temporary buffer (space reused after `CNT` calls)
extern(C)
pragma(printf)
char* printf_tmp(const(char)* fmt, ...)
{
	enum LEN = 256;
	enum CNT = 5;

	static ubyte[LEN][CNT] bufs;
	static int bufidx;

	char* p = cast(char*)bufs[bufidx].ptr;
	bufidx = (bufidx + 1) % CNT;
	va_list ap;
	va_start(ap, fmt);
	int rv = vsnprintf(p, LEN, fmt, ap);
	debug assert(rv >= 0);
	debug assert(rv <= LEN); // increase LEN if strings are cut off and this asserts
	va_end(ap);
	return p;
}
