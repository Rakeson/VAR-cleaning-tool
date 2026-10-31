# VAR-cleaning-tool
Windows batch script that keeps only the newest version of each Virt-A-Mate (VaM) .var package and permanently deletes the old ones. Preview and confirm first. Optional Safe mode reads meta.json to keep old versions that other packages pin by exact version.


One double-click to clean up the old versions of your **Virt-A-Mate (VaM)** `.var` packages.

For every package named `Creator.Package.Version.var` inside `AddonPackages` (all subfolders included), the script keeps the newest version and permanently deletes the older ones. It always shows a preview first and asks for confirmation before it deletes anything.

When you update packages, the new version is saved next to the old one, so old versions pile up and eat disk space. This script removes them in one pass.

## Features

- **Highest version wins.** Versions are compared as numbers (`10` is newer than `9`), and package names are matched case-insensitively.
- **Two modes.** *Simple* decides by file name only. *Safe* also reads `meta.json` from your other packages and keeps old versions that something else depends on by exact version number.
- **Preview and confirm.** You see exactly what will be kept and deleted, plus the space you will free. Nothing happens until you type `Y`.
- **Subfolders included.** Packages you sorted into folders under `AddonPackages` are handled too.
- **Fast Safe mode.** It reads only the zip directory and the one small `meta.json` entry of each package (never the whole file), using up to 8 threads, with a progress counter.
- **Log file.** Every run that deletes something writes a log next to the script.
- **Nothing to install.** One `.bat` file that uses the Windows PowerShell already built into Windows 10/11.

## Quick start

1. Download `VaM_Clean_Old_Var.bat`.
2. Put it in your **VaM root folder**, the one that contains `AddonPackages`.
3. **Close VaM.**
4. Double-click the file.
5. Pick a mode, read the preview, then type `Y` and press Enter to delete (anything else cancels).

Good to know:

- If you are not sure, choose **mode 2 (Safe)**. To only look, run it, read the preview, and cancel.
- Windows may show a SmartScreen warning for downloaded scripts. The file is plain text, so you can open it in Notepad and read it first. If you trust it, choose *More info → Run anyway*.
- **Deletion is permanent** (no Recycle Bin). Back up anything you cannot re-download.

## Modes

| | 1 - Simple | 2 - Safe |
|---|---|---|
| Decides by | File name only | File name plus the `meta.json` of every package that stays |
| Speed | Instant | Reads one small entry per package, (still fast...) |
| Old version that another package pins by exact version | Deleted | **Kept** |
| Extra work | None | Also checks what the kept old versions depend on, repeating until nothing new turns up |

Why Safe mode exists: most packages refer to their dependencies as `.latest` or `.minN` (a minimum version), and those are satisfied by the newest version. Some packages pin an exact version such as `Creator.Package.7`. If you delete version 7, that package reports a missing dependency. Safe mode finds those pins and keeps the version they need.

## How it decides

1. Scan `AddonPackages` and every subfolder for `*.var`.
2. Parse `Creator.Package.Version.var`. The version must be a whole number.
3. Group by `Creator.Package` (case-insensitive). Groups with a single file are left alone.
4. Keep the highest version. If the same version exists more than once, keep the larger file, then the one in the shallower folder.
5. Everything else goes into the delete plan (Safe mode removes the pinned versions from it).
6. Show the preview, ask for `Y`, delete, write the log.

## What it will not touch

- Files whose names do not follow `Creator.Package.Version.var` (for example copies like `Name.5 (1).var`). They are only counted and reported.
- `.var.disabled` files.
- Anything outside `AddonPackages`.
- Linked folders (symlinks and junctions) inside `AddonPackages`. They are not entered, so files in a linked repository are never deleted.

It also refuses to run while `VaM.exe` or `VaMX.exe` is running.

## Example output (shortened; numbers are illustrative)

```
Scanning: D:\VaM\AddonPackages
Found 8421 .var files.
37 files do not follow the Creator.Package.Version.var naming (for example copies ending in (1)). They were left untouched.

Select a mode:
  1 = Simple: decide by file name only. Fastest. (Just press Enter to pick this one)
  2 = Safe: also read meta.json in the other 8100 packages and keep old versions that another package depends on by exact version number
Enter 1 or 2 and press Enter: 2
Reading meta.json from 8100 packages (multi-threaded)...
  Read 8100 / 8100
Done reading meta.json in 12.3 s.

2 old versions are depended on by exact version number by other packages and will be kept:
  SomeCreator.SomePlugin.7  <-  OtherCreator.SomeScene.3, Another.Look.1

SomeCreator.SomePlugin  keep .9  delete .8 .5 .4
SomeCreator.SomeLook  keep .12  delete .11 .10
...

312 packages have extra versions. 640 files (about 9.80 GB) will be PERMANENTLY deleted.
Deleted files cannot be recovered (they do not go to the Recycle Bin).
Type Y and press Enter to delete. Anything else (or closing this window) cancels without touching any file: Y
Done: deleted 640 files, freed about 9.80 GB.
Log: D:\VaM\VaM_Clean_Var_Log_20261031_120000.txt
```

## FAQ

**Can it break my scenes?**
In Simple mode, a scene or look that pins an exact old version can report a missing dependency after that version is deleted. Safe mode prevents this for every pin that is listed in a package's `meta.json`. If it happens anyway, download the missing version again from the Hub.

**Can I preview without deleting?**
Yes. Choose a mode, read the list, and answer anything except `Y`. No file is touched.

**Where is the log?**
In the VaM root folder, named `VaM_Clean_Var_Log_<date>_<time>.txt`. It lists what was kept, deleted, skipped and pinned. It is only written when you confirm a deletion.

**Some files could not be deleted.**
They were probably in use or protected. Close VaM and run the script again, or right-click it and choose *Run as administrator*.

## Limitations

- Safe mode reads only `meta.json`. References that exist only inside scene JSON files and are not listed in `meta.json` cannot be seen.
- `.var.disabled` packages are not scanned, so they are not counted as dependents either.
- Packages with an unreadable or missing `meta.json` are counted and reported, but their dependencies cannot be checked.
- Windows only.

## Other VaM tools

This script does one job. If you want a full package manager, these community projects may suit you better:

- [iHV](https://github.com/BoominBobbyBo/iHV): PowerShell scripts for VAR management, including removing previous versions
- [varManager](https://github.com/bustesoul/varManager): a GUI var manager
- [VarLens](https://pypi.org/project/varlens-tui/): a terminal UI to browse packages, find orphans and delete safely
- [VamToolbox](https://github.com/Kruk2/VamToolbox): scans a VaM folder for errors and missing dependencies

## Disclaimer

This is an unofficial community tool. It is not affiliated with or endorsed by Meshed VR or Virt-A-Mate. **It deletes files permanently.** It is provided as is, without warranty, and you use it at your own risk, so back up what matters first.

