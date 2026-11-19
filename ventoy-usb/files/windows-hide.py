#!/usr/bin/env python3
# Sets the exFAT "hidden" attribute on the Linux and Ventoy entries of
# this stick, so Windows Explorer hides them like Dolphin and Nautilus
# do through .hidden:
#   ventoy/           at the top
#   .Trash-*/         at the top, not descended into
#   .hidden           in every folder
#   .ventoyignore     in every folder
# Only names and attributes are touched, no file is read. Run it again
# after new folders got their .hidden copy:
#   python3 /run/media/$USER/USB/ventoy/windows-hide.py
# --dry-run only lists what would change.
import fcntl, os, struct, sys

FAT_IOCTL_GET_ATTRIBUTES = 0x80047210   # _IOR('r', 0x10, __u32)
FAT_IOCTL_SET_ATTRIBUTES = 0x40047211   # _IOW('r', 0x11, __u32)
ATTR_HIDDEN = 0x02

root = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
dry = "--dry-run" in sys.argv


def targets():
    for name in sorted(os.listdir(root)):
        if name == "ventoy" or name.startswith(".Trash-"):
            yield os.path.join(root, name)
    for d, dirs, files in os.walk(root):
        if d == root:
            dirs[:] = [x for x in dirs if not x.startswith(".Trash-")]
        for name in (".hidden", ".ventoyignore"):
            if name in files:
                yield os.path.join(d, name)


changed = already = failed = 0
for path in targets():
    rel = os.path.relpath(path, root)
    try:
        fd = os.open(path, os.O_RDONLY)
        try:
            buf = fcntl.ioctl(fd, FAT_IOCTL_GET_ATTRIBUTES, struct.pack("I", 0))
            attr = struct.unpack("I", buf)[0]
            if attr & ATTR_HIDDEN:
                already += 1
                continue
            if not dry:
                fcntl.ioctl(fd, FAT_IOCTL_SET_ATTRIBUTES,
                            struct.pack("I", attr | ATTR_HIDDEN))
            changed += 1
            print(("would hide " if dry else "hidden ") + rel)
        finally:
            os.close(fd)
    except OSError as e:
        failed += 1
        print(f"FAILED {rel}: {e.strerror}", file=sys.stderr)

print(f"{'would change' if dry else 'changed'} {changed}, already hidden {already}, failed {failed}")
sys.exit(1 if failed else 0)
