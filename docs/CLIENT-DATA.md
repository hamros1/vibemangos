# Client data reference

Start with [Prepare the data](SETUP.md#2-prepare-the-data) for the directories needed by
a local server. The extractor takes the client directory containing `Data/` and a separate
output directory. Existing CMaNGOS-format files can also be used.

```sh
./bin/extractor -i "/path/to/WoW 1.12.1" -o /path/to/data   # writes data/dbc/*.dbc and data/maps/*.map
./bin/extractor -i "/path/to/WoW 1.12.1" -o /path/to/data -e 1   # maps only (-e 2: DBC files only)
./bin/extractor -i "/path/to/WoW 1.12.1" -o /path/to/data -e 4   # vmaps: buildings and doodads
./bin/extractor -o /path/to/data -e 8   # movement maps, from maps/ and vmaps/ (--map ID for one map)
```

What it does:

* It opens `model`, `dbc`, `terrain`, `patch` and `patch-2.MPQ` from the client's `Data` folder,
  and looks files up newest archive first, so patches win.
* It copies every `.dbc` named in the archives' listfiles unchanged.
* It checks that each file is a complete DBC, and skips one-byte placeholders that patches use
  for removed files.

* It converts every map's terrain tiles (`World\Maps\NAME\NAME_X_Y.adt`, as each map's WDT lists
  them) into `maps/MMMYYXX.map`: area flags, ground heights (packed to bytes or shorts where the terrain
  is flat enough), liquids and holes, in map file version "z1.4".

* With `-e 4` it extracts the buildings and doodads into `Buildings/`, then assembles them into
  `vmaps/`: a tree over each map's models, a file per tile, and each model with trees over its
  groups and triangles (version "VMAP_7.0"). `Buildings/` is kept as the raw extraction.

* With `-e 8` it builds movement maps into `mmaps/`: a navigation mesh per map tile from the
  terrain and the buildings, with Recast. It needs
  `maps/` and `vmaps/`, not the client. Maps that are one building (most dungeons) get the tiles their
  models cover. Creatures find their way over them.

A 1.12.1 client yields 158 DBC files in well under a second, 2429 map tiles of 44 maps (150 MB)
in about 13 seconds, and vmaps of 815 buildings and 3138 doodads, placed 505,837 times
(276 MB, with 152 MB of `Buildings/`), in about 30 seconds. The MPQ reader (`source/dmangos/mpq/`)
handles plain, encrypted, sector and single-unit files, compressed with zlib or PKWare DCL, which
are the encodings 1.12 data files use. Movement maps for all 2,604 tiles of the 43 maps (956 MB)
take under three minutes on 32 cores.
