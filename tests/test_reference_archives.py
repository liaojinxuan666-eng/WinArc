import importlib.util
import pathlib
import struct
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('audit', ROOT / 'wine/check-reference-archives.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def macho(symbols, platform=2, cpu=0x100000c):
    strings = b'\0'
    entries = b''
    for name, typ, value in symbols:
        entries += struct.pack('<IBBHQ', len(strings), typ, 1 if typ & 0xe else 0, 0, value)
        strings += name.encode() + b'\0'
    header = struct.pack('<8I', 0xfeedfacf, cpu, 0, 1, 2, 48, 0, 0)
    commands = struct.pack('<6I', 0x32, 24, platform, 17 << 16, 26 << 16, 0)
    commands += struct.pack('<6I', 2, 24, 80, len(symbols), 80 + len(entries), len(strings))
    return header + commands + entries + strings


def archive(data):
    header = f'{"unit.o/":16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(data):<10}`\n'.encode()
    return b'!<arch>\n' + header + data + (b'\n' if len(data) % 2 else b'')


class ReferenceAuditTests(unittest.TestCase):
    def inputs(self, directory):
        for index, lib in enumerate(audit.LIBRARIES):
            symbols = [(audit.REQUIRED.get(lib, '_library_' + str(index)), 0xf, 1)]
            if lib == 'libwineserver.a':
                symbols += [('_ws_' + name, 0xf, 1) for name in audit.ISOLATED]
            (directory / lib).write_bytes(archive(macho(symbols)))

    def test_valid_set_and_missing_host_import_are_distinct(self):
        with tempfile.TemporaryDirectory() as path:
            root = pathlib.Path(path)
            self.inputs(root)
            (root / 'libgmp.a').write_bytes(archive(macho([('_host_missing', 1, 0)])))
            result = audit.audit(root)
            self.assertEqual(result['status'], 'PASS')
            self.assertIn('_host_missing', result['unresolved_imports'])
            self.assertFalse(result['executable_link_verified'])
            self.assertFalse(result['runtime_execution_verified'])

    def test_undefined_entry_does_not_pass_as_definition(self):
        with tempfile.TemporaryDirectory() as path:
            root = pathlib.Path(path)
            self.inputs(root)
            (root / 'libntdll_unix.a').write_bytes(archive(macho([('___wine_main', 1, 0)])))
            self.assertEqual(audit.audit(root)['status'], 'FAIL')

    def test_common_and_hidden_collision_are_rejected(self):
        for typ, value in [(1, 8), (0x1f, 1), (0xf, 1)]:
            with self.subTest(typ=typ), tempfile.TemporaryDirectory() as path:
                root = pathlib.Path(path)
                self.inputs(root)
                for lib in ('libgmp.a', 'libnettle.a'):
                    (root / lib).write_bytes(archive(macho([('_state', typ, value)])))
                result = audit.audit(root)
                self.assertEqual(result['status'], 'FAIL')
                self.assertIn('_state', result['duplicate_definitions'])

    def test_server_import_must_be_renamed_too(self):
        with tempfile.TemporaryDirectory() as path:
            root = pathlib.Path(path)
            self.inputs(root)
            data = (root / 'libwineserver.a').read_bytes()
            data += archive(macho([('_native_machine', 1, 0)]))[8:]
            (root / 'libwineserver.a').write_bytes(data)
            self.assertIn('server still imports client state: _native_machine', audit.audit(root)['errors'])

    def test_wrong_platform_or_cpu(self):
        for platform, cpu in [(1, 0x100000c), (7, 0x100000c), (2, 0x1000007)]:
            with self.subTest(platform=platform, cpu=cpu), self.assertRaises(ValueError):
                audit.object_symbols(macho([], platform, cpu))

    def test_truncated_input_rejected(self):
        data = archive(macho([('_test', 0xf, 1)]))
        for cut in (0, 7, 20, len(data) - 3):
            with self.subTest(cut=cut), self.assertRaises(ValueError):
                list(audit.archive_members(data[:cut]))
        with self.assertRaises(ValueError):
            audit.object_symbols(macho([])[:-1])


if __name__ == '__main__':
    unittest.main()
