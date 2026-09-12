#!/usr/bin/env python3
"""Inspect every Mach-O archive member before linking the pinned reference.

No Apple tools are needed to inspect CI artifacts. Undefined imports are
reported, not treated as implemented. Duplicate external state is rejected
including common/private-external definitions that a linker might coalesce.
"""
import argparse
import collections
import json
import pathlib
import struct
import sys

LIBRARIES = ('libwineserver.a', 'libntdll_unix.a', 'libwin32u_unix.a',
             'libgnutls.a', 'libhogweed.a', 'libnettle.a', 'libgmp.a')
REQUIRED = {'libwineserver.a': '_wineserver_main',
            'libntdll_unix.a': '___wine_main',
            'libwin32u_unix.a': '_win32u_unix_lib_init'}
ISOLATED = ('native_machine', 'server_start_time', 'supported_machines',
            'supported_machines_count')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def archive_members(data):
    require(data[:8] == b'!<arch>\n', 'not a regular ar archive')
    offset = 8
    long_names = b''
    while offset < len(data):
        require(offset + 60 <= len(data), 'truncated ar header')
        header = data[offset:offset + 60]
        require(header[58:60] == b'`\n', 'invalid ar header trailer')
        size = int(header[48:58])
        require(size >= 0 and offset + 60 + size <= len(data), 'invalid ar member size')
        body = data[offset + 60:offset + 60 + size]
        offset += 60 + size
        if size % 2:
            require(offset < len(data) and data[offset:offset + 1] == b'\n', 'missing ar padding')
            offset += 1
        name = header[:16].decode('ascii').strip()
        if name.startswith('#1/'):
            length = int(name[3:])
            require(0 <= length <= len(body), 'invalid extended member name')
            name = body[:length].rstrip(b'\0').decode('utf-8')
            body = body[length:]
        if name == '//':
            long_names = body
            continue
        if name.startswith('__.SYMDEF') or name in ('/', '/SYM64/'):
            continue
        if name.startswith('/') and name[1:].isdigit():
            index = int(name[1:])
            require(index < len(long_names), 'invalid GNU member name offset')
            end = long_names.find(b'/\n', index)
            require(end >= 0, 'unterminated GNU member name')
            name = long_names[index:end].decode('utf-8')
        yield name.rstrip('/'), body


def object_symbols(data):
    require(len(data) >= 32, 'truncated Mach-O header')
    magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from('<8I', data)
    require(magic == 0xfeedfacf and cpu == 0x100000c and subtype == 0,
            'expected plain ARM64 Mach-O (not simulator/x86/arm64e)')
    require(kind == 1, 'expected MH_OBJECT')
    require(32 + size <= len(data), 'load commands exceed object')
    offset = 32
    platform = None
    symbols = None
    for _ in range(count):
        require(offset + 8 <= 32 + size, 'truncated load command')
        command, length = struct.unpack_from('<II', data, offset)
        require(length >= 8 and offset + length <= 32 + size, 'invalid load command size')
        if command == 0x32:  # LC_BUILD_VERSION
            require(length >= 24, 'truncated build version')
            platform = struct.unpack_from('<I', data, offset + 8)[0]
        if command == 2:  # LC_SYMTAB
            require(length >= 24 and symbols is None, 'invalid symbol table command')
            symbols = struct.unpack_from('<4I', data, offset + 8)
        offset += length
    require(offset == 32 + size, 'load command count/size mismatch')
    require(platform == 2, 'expected iPhoneOS platform, not macOS/simulator or unspecified')
    require(symbols is not None, 'missing symbol table')
    symoff, nsyms, stroff, strsize = symbols
    require(symoff + nsyms * 16 <= len(data) and stroff + strsize <= len(data),
            'symbol table outside object')
    strings = data[stroff:stroff + strsize]
    result = []
    for index in range(nsyms):
        strx, typ, section, desc, value = struct.unpack_from('<IBBHQ', data, symoff + index * 16)
        if not typ & 1 or typ & 0xe0:  # external and not STAB
            continue
        require(strx < len(strings), 'symbol name outside string table')
        end = strings.find(b'\0', strx)
        require(end >= 0, 'unterminated symbol name')
        name = strings[strx:end].decode('utf-8')
        undefined = typ & 0x0e == 0 and value == 0
        result.append((name, undefined, bool(desc & 0x80)))  # N_WEAK_DEF
    return result


def audit(directory):
    definitions = collections.defaultdict(list)
    imports = collections.defaultdict(list)
    counts = {}
    errors = []
    for library in LIBRARIES:
        counts[library] = 0
        try:
            for member, data in archive_members((directory / library).read_bytes()):
                origin = library + ':' + member
                symbols = object_symbols(data)
                counts[library] += 1
                for name, undefined, weak in symbols:
                    if undefined:
                        imports[name].append(origin)
                    else:
                        definitions[name].append({'member': origin, 'weak': weak})
            require(counts[library] > 0, library + ' contains no objects')
        except (ValueError, OSError, UnicodeError, struct.error) as exc:
            errors.append(library + ': ' + str(exc))
    duplicates = {name: entries for name, entries in definitions.items()
                  if len(entries) > 1 and not all(e['weak'] for e in entries)}
    if duplicates:
        errors.append('duplicate external definitions (including common/hidden state)')
    for library, symbol in REQUIRED.items():
        if not any(e['member'].startswith(library + ':') for e in definitions.get(symbol, [])):
            errors.append('missing definition: ' + library + ':' + symbol)
    for name in ISOLATED:
        server = 'libwineserver.a:'
        if not any(e['member'].startswith(server) for e in definitions.get('_ws_' + name, [])):
            errors.append('missing isolated server state: _ws_' + name)
        if any(e['member'].startswith(server) for e in definitions.get('_' + name, [])):
            errors.append('unisolated server state: _' + name)
        if any(o.startswith(server) for o in imports.get('_' + name, [])):
            errors.append('server still imports client state: _' + name)
    unresolved = {name: origins for name, origins in sorted(imports.items()) if name not in definitions}
    return {'schema': 1, 'stage': 'ARCHIVE_AUDIT', 'status': 'FAIL' if errors else 'PASS',
            'objects': counts, 'duplicate_definitions': duplicates,
            'unresolved_imports': unresolved, 'errors': errors,
            'executable_link_verified': False, 'runtime_execution_verified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    report = audit(args.directory)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('WINARC_REFERENCE_ARCHIVE_AUDIT=' + report['status'])
    print('WINARC_REFERENCE_UNRESOLVED_IMPORTS=' + str(len(report['unresolved_imports'])))
    for error in report['errors']:
        print(error, file=sys.stderr)
    return int(bool(report['errors']))


if __name__ == '__main__':
    sys.exit(main())
