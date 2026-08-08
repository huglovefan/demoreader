/**
 * tracks in-game votes between the different events about them
 */
module demoreader.vote;

import core.stdc.stdio;

/*
 * points of interest:
 * - UserMessage.VoteStart
 * - UserMessage.VotePass
 * - UserMessage.VoteFailed
 * - "vote_cast" game event
 * - "vote_options" game event
 */

struct Votes
{
	Vote*[int] activeVotes;

	void reset()
	{
		activeVotes = null;
	}

	Vote* get(int wantIndex)
	{
		if (Vote** vp = wantIndex in activeVotes)
			return *vp;

		return (activeVotes[wantIndex] = new Vote(wantIndex));
	}

	void remove(int wantIndex)
	{
		activeVotes.remove(wantIndex);
	}
}

struct Vote
{
	int      index;
	uint     team;
	char[][] options;

	const(char)* optionName(uint optionNo)
	{
		if (optionNo < options.length)
		{
			if (char[] s = options[optionNo])
				return s.ptr;
		}

		// didn't get the options for this vote
		assert(options is null);

		char[] name = new char[32];
		snprintf(name.ptr, name.length, "<option %u>", optionNo);
		return name.ptr;
	}
}
