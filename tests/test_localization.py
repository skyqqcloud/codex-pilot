"""Validate bilingual catalogs and native bundle/format contracts without real accounts."""
import json
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENTRY = re.compile(r'^\s*("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");\s*$')
FORMAT = re.compile(r'%(?:%|(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:lld|ld|d|f|@))')


def catalog(language, name='Localizable'):
    entries = {}
    for line in (ROOT / 'app/Resources' / (language + '.lproj') / (name + '.strings')).read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('/*'):
            continue
        match = ENTRY.fullmatch(line)
        if not match:
            raise AssertionError('Invalid catalog entry: ' + line)
        key, value = map(json.loads, match.groups())
        if key in entries:
            raise AssertionError('Duplicate localization key: ' + key)
        entries[key] = value
    return entries


class LocalizationTests(unittest.TestCase):
    def test_catalogs_cover_the_same_interface(self):
        english, chinese = catalog('en'), catalog('zh-Hans')
        self.assertGreaterEqual(len(english), 170)
        self.assertEqual(english.keys(), chinese.keys())
        self.assertTrue(all(value for value in english.values()))
        self.assertTrue(all(not re.search(r'[\u3400-\u9fff]', value) for value in english.values()))
        self.assertEqual(english['保存登录'], 'Save login')
        self.assertEqual(chinese['保存登录'], '保存登录')

    def test_formats_preserve_argument_types_and_literal_percent(self):
        for key, translation in catalog('en').items():
            signature = lambda value: [part for part in FORMAT.findall(value) if part != '%%']
            with self.subTest(key=key):
                self.assertEqual(signature(key), signature(translation))
        self.assertEqual(catalog('en')['%@剩余 %lld%%'], '%@ remaining: %lld%%')
        self.assertEqual(catalog('en')['%.2f 秒'], '%.2f s')

    def test_macos_can_select_both_app_languages(self):
        info = plistlib.loads((ROOT / 'app/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleDevelopmentRegion'], 'en')
        self.assertEqual(set(info['CFBundleLocalizations']), {'en', 'zh-Hans'})
        for language in ('en', 'zh-Hans'):
            self.assertIn('NSAppleEventsUsageDescription', catalog(language, 'InfoPlist'))
        self.assertEqual(info['CFBundleIdentifier'], 'local.wmy.CodexSwap')

    def test_request_count_plural_rules(self):
        for language in ('en', 'zh-Hans'):
            path = ROOT / 'app/Resources' / (language + '.lproj/Localizable.stringsdict')
            rules = plistlib.loads(path.read_bytes())['%lld 条']
            self.assertEqual(rules['NSStringLocalizedFormatKey'], '%#@count@')
            self.assertEqual(rules['count']['NSStringFormatValueTypeKey'], 'lld')
            self.assertEqual(rules['count']['NSStringFormatSpecTypeKey'], 'NSStringPluralRuleType')
        english = plistlib.loads((ROOT / 'app/Resources/en.lproj/Localizable.stringsdict').read_bytes())
        self.assertEqual(english['%lld 条']['count']['one'], '%lld request')
        self.assertEqual(english['%lld 条']['count']['other'], '%lld requests')


if __name__ == '__main__':
    unittest.main()
