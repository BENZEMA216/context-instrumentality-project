#!/usr/bin/env python3
"""Mark ditto's UTF-8 ZIP filenames without changing file data or Unix modes."""
from pathlib import Path
import struct
import sys
import zipfile


def normalize(path):
    data = bytearray(path.read_bytes())
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        central = archive.start_dir
        for entry in entries:
            if data[central:central + 4] != b'PK\x01\x02':
                raise ValueError('Invalid ZIP central directory')
            name_length, extra_length, comment_length = struct.unpack_from('<HHH', data, central + 28)
            raw_name = data[central + 46:central + 46 + name_length]
            local = entry.header_offset
            if data[local:local + 4] != b'PK\x03\x04':
                raise ValueError('Invalid ZIP local header')
            local_length = struct.unpack_from('<H', data, local + 26)[0]
            if data[local + 30:local + 30 + local_length] != raw_name:
                raise ValueError('ZIP filename headers disagree')
            if any(byte > 127 for byte in raw_name):
                raw_name.decode('utf-8')  # Refuse to relabel a non-UTF-8 archive.
                for offset in (central + 8, local + 6):
                    flags = struct.unpack_from('<H', data, offset)[0]
                    struct.pack_into('<H', data, offset, flags | 0x800)
            central += 46 + name_length + extra_length + comment_length
    path.write_bytes(data)
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError('ZIP integrity check failed')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: normalize-zip-utf8.py ARCHIVE.zip')
    normalize(Path(sys.argv[1]))
