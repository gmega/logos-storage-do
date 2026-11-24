import importlib.util
import unittest

spec = importlib.util.spec_from_file_location('release', 'scripts/resolve-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

class ReleaseTests(unittest.TestCase):
    def entry(self, version, date, platforms=None):
        return {'releasedAt': date, 'sha256': 'a'*64,
                'manifest': {'version': version, 'main': platforms or {'linux-amd64': 'plugin.so'}}}

    def test_latest_publication_not_version_lexical_order(self):
        old = self.entry('3.0.2-9.gabc', '2026-11-09T00:00:00Z')
        new = self.entry('3.0.2-10.gdef', '2026-11-23T00:00:00Z')
        self.assertIs(release.select_release({'packages': [{'name':'storage_module', 'versions':[old,new]}]}), new)

    def test_refuse_duplicate_unless_forced(self):
        with self.assertRaisesRegex(ValueError, 'already deployed'):
            release.check_version('3.0.2-10.gdef', {'version':'3.0.2-10.gdef'})
        release.check_version('3.0.2-10.gdef', {'version':'3.0.2-10.gdef'}, True)
        release.check_version('3.0.2-11.gabc', {'version':'3.0.2-10.gdef'})
        release.check_version('3.0.2-11.gabc', None)

    def test_latest_missing_platform_is_not_silently_skipped(self):
        entries=[self.entry('3.0.2-10.gdef','2026-11-23',{'darwin-arm64':'plugin.dylib'}),
                 self.entry('3.0.2-9.gabc','2026-11-09')]
        with self.assertRaisesRegex(ValueError, 'no linux-amd64'):
            release.select_release({'packages':[{'name':'storage_module','versions':entries}]})

if __name__=='__main__': unittest.main()
