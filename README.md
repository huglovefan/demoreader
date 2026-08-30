# demoreader

this is my tf2 demo file reader from 2022, originally written to have
way to auto-flag bots and cheaters back when that was a
[bigger issue](#they-just-announced-it)

output is a basic summary of the game, with any "detections" on lines
starting with a `-`. they're intended to be exported using grep, for
example:

    # gather steamids that set their friendsName
    ./demoreader -1 | grep -Po '^-.*(friendsName).*\K\[U:1:[0-9]+]' > evildoers.list

![](doc/Screenshot_2026-08-04_11-50-20.png)

![](doc/Screenshot_2026-08-04_12-21-37.png)

thanks:

- <https://github.com/ValveSoftware/csgo-demoinfo> (basics of demo parsing)
- <https://github.com/UncraftedName/UntitledParser> (more complicated entity stuff)
- some glances at leaked source code

### command-line documentation

    ./demoreader [options] [demofile|range|glob]...

The program takes one or more demo files as an argument. Alternatively,
a range or glob pattern can be used to look them up in the configured
search directories. See **Examples** below.

**Options:**

-   `-color`: 		always colorize output (default: only to terminal)
-   `-pager`:		show output in a pager
-   `-keepgoing`:	when reading multiple demos, don't exit if one has errors
-   `-l`:		don't read, only list found/matched demo files
-   `-live`:		continuously parse a demo currently being recorded
-   `-nowait`:		disable automatic live demo functionality (for scripting)
-   `-steamids`:	include player steamids in output
-   `-trace`:		include detailed low-level output from parsing
-   `-wrap`:		wrap long lines in pager

**Developer options:**

-   `-debug`:		run with a debug build, recompiling if necessary
-   `-json`:		force writing json file
-   `-livestat`:	print debug stats for -live
-   `-sizestat`:	gather size stat
-   `-skipentities`:	skip parsing entity data
-   `-userids`:		include player userids in output
-   `-v`:		verbose output (useless)

**Examples:**

Below are some examples that show how the range and glob syntax can be
used. Both forms require that some
[search directories](searchDirs.txt.example) have been configured.

    ./demoreader -1     # read the last demo
    ./demoreader -100-  # read the last 100 demos
    ./demoreader +1     # read the first demo
    ./demoreader +100-  # read from the 100th demo onwards

<P></P>

    # read demos with a matching filename
    ./demoreader '2022-01-*'

-   Ranges are applied after all demos from the search directories have
    been gathered and **sorted by filename** (independent of their
    containing directory).
-   To just list what's matched, add `-l`.

### inspiring quote

    https://news.ycombinator.com/item?id=33037121

    dboreham on Sept 30, 2022

    I've noticed that the people running automated flagging systems seem to
    become inordinately smug to the point that they believe their false
    positive result over all forms of external evidence. So to them you are
    a criminal and that's that.


### they JUST announced it

    Date: Fri, 24 Jul 2026 11:32:37 -0700

    JoriKos left a comment (ValveSoftware/Source-1-Games#3477)

    Since June 2024, I believe the 'bot crisis' is pretty much over. There
    are still bot accounts as there have always been, and some of them are
    doing mildly noticeable things (changing the Casual map selection screen
    bars), but I think this issue can be pretty confidently closed. There is
    no more bot crisis, and the remaining bots are nowhere near the amount
    of disruptive bots to call it a 'bot crisis'.
