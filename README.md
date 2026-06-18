# IGS PolyGame Master MiSTer FPGA core

The PolyGame Master (PGM) is an arcade system board released in 1997 by IGS. It has a lot of similarities to SNK's Neo Geo - cartridge based with multiple buses, heavily sprite focused graphics hardware, 68000 main CPU, Z80 for audio.

- Main processor: Motorola 68000 @ 20 MHz
- Sound processor: Zilog Z80 @ 8.4 MHz
- Sound chip: Wavefront ICS2115
- Graphics chip: IGS023

Games come with several flavors of protection hardware on the cartridge. Most feature an ARM7 CPU and in later games the ARM takes on a larger portion of the game update processing.

## Status
This core is currently BETA. Most games work, but the core needs more testing. The PGM platform features a large amount of variants and bootlegs that all require testing. If you encounter issues please report them via github. Save state files can be especially useful for tracking down and reproducing issues, so if you have some then please include them.

## Core Features
- Save States. The core supports save states for all games. It is expected that you can save and restore a save state at any point. If you encounter issues restoring save states, please report them.
- H-Scale. The PGM video signal tends to be squashed horizontally by consumer CRTs. In the Video Settings menu there is an H-Scale option that can be enabled which allows you to scale the width of the image up and down. This only works for analog video and does not play well with the HDMI scaler.
- NVRAM. The 128KB of main RAM on the PGM is battery backed. On the original system this is often used for bookkeeping data such as earning per game. Some games (CAVE shooters) use it for storing per-game settings. It might also be used for high score saving by some games.
- RTC. The PGM also has a battery backed clock. As far as I know this is not used by any games, but it does get displayed at startup by the BIOS. The timer can be adjusted in the BIOS, but at startup it will always be set to the MiSTers current system time.

## Supported games

- Oriental Legend
- Oriental Legend Super
- Dragon World 3
- Dragon World 3 EX
- Dragon World 2001
- The Killing Blade
- The Killing Blade Plus
- Photo Y2K
- Knights of Valour Super Heroes
- Knights of Valour 2
- Martial Masters
- Demon Front
- The Gladiator
- S.V.G. - Spectral vs Generation
- DoDonPachi II - Bee Storm
- DoDonPachi III / Dai-Ou-Jou
- Ketsui: Kizuna Jigoku Tachi
- Espgaluda

## Not yet working

- Knights of Valour
- Knights of Valour Plus
- Knights of Valour 2 Plus - Nine Dragons
- Dragon World Pretty Chance
- Happy 6-in-1

## Sources
Multiple different sources have been used as reference when developing this core.

[MAME](https://www.mamedev.org/) - Tons of information about the PGM system and especially its protection mechanisms. Also used as the source for the initial ICS2115 implementation.

[igspgm.com](https://igspgm.com/) - Motherboard images, cartridge images, archived documents. Super valuable archive of information that could easily have been lost to history.

[PGMTech](https://github.com/laoo/PGMTech) - Solid documentation of PGM memory maps and system architecture

[GUS GF1 Decap](https://github.com/nukeykt/LPC-GUS) - Coming from the same hardware lineage, the GF1 source was a useful reference for how things might be done inside the ICS2115

[Game Bub](https://github.com/elipsitz/gamebub) - ARM7TDMI implementation


## Special Thanks
Thanks to [James](https://www.retrohq.co.uk/) for all the additional insights he was able to provide. The stars aligned and we ended up exploring parts of the system as the same time. I hope I was able to help him half as much as he helped me.

Thanks to [Tim](https://igspgm.com/) for keeping valuable sources of PGM information alive on the internet over the years. It has been an invaluable source of information.

laoo, Xolod, augitesoul and everyone who has playtested, provided feedback and/or support.