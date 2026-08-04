/**
 * stuff that uses terminal colors
 */
module demoreader.ttycolor;

import core.stdc.stdio;
import demoreader.globals : g_useColor;
import demoreader.util.sprint;

const(char)* teamcolorize(const(char)* str, int team = 0)
{
	if (!g_useColor)
		return str;

	const(char)* color = "34;38;2;251;236;203"; // unknown
	if (team == 2)
		color = "34;38;2;184;56;59".ptr; // red
	if (team == 3)
		color = "34;38;2;88;133;162".ptr; // blu
	if (team == 666)
		color = "1;5;37;41".ptr; // crit blink

	return printf_tmp("\x1b[%sm%s\x1b[0m", color, str);
}

string getteamcolor(int team)
{
	if (team == 2)
		return "34;38;2;184;56;59"; // red
	if (team == 3)
		return "34;38;2;88;133;162"; // blu

	return "34;38;2;251;236;203"; // unknown
}

/**
 * used by:
 * - SayText2 user message
 * - TextMsg user message
 */
void printSourceModColoredText(const(char)[] s)
{
	size_t skipuntil;
	int inColor;

	foreach (i, c; s)
	{
		if (c == 1 || c == 3 || c == 4)
		{
			// not sure what 3 is
			// it appears in player chat messages but not system messages
			// 4 appears in rtd messages before the number of seconds
			if (inColor)
			{
				if (g_useColor)
					printf("\x1b[0m");
				inColor--;
			}
			continue;
		}

		if (c == 7)
		{
			const(char)[] color = s[i+1..i+7]; // RRGGBB
			uint r, g, b;
			sscanf(color.ptr, "%02x%02x%02x", &r, &g, &b);
			if (g_useColor)
				printf("\x1b[34;38;2;%d;%d;%dm", r, g, b);
			skipuntil = i + 7;
			inColor++;
			continue;
		}

		//if (c < ' ') { printf("<%d>", cast(int)c); continue; }

		if (c < ' ' && c != '\n') assert(0, "unknown control character");

		if (i >= skipuntil)
			putchar(c);
	}

	if (g_useColor)
		while (inColor --> 0) printf("\x1b[0m");
}
