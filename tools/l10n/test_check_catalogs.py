"""Tests for check_catalogs.py.

Run: python3 -I -m unittest discover -s tools/l10n
"""
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("check_catalogs", HERE / "check_catalogs.py")
cc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cc)


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def plural(**forms):
    return {"variations": {"plural": {form: unit(text) for form, text in forms.items()}}}


def catalog(strings):
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


GOOD_APP = {
    "Done": {"localizations": {"ru": unit("Готово")}},
    "Code %lld of %lld": {"localizations": {"ru": unit("Код %1$lld из %2$lld")}},
    "OK": {"shouldTranslate": False},
}
GOOD_KIT = {
    "Updated codes for %lld buttons": {
        "localizations": {
            "en": plural(one="Updated codes for %lld button", other="Updated codes for %lld buttons"),
            "ru": plural(
                one="Обновлены коды для %lld кнопки", few="Обновлены коды для %lld кнопок",
                many="Обновлены коды для %lld кнопок", other="Обновлены коды для %lld кнопки",
            ),
        }
    },
    "Bluetooth error: %@": {"localizations": {"ru": unit("Ошибка Bluetooth: %@")}},
}
GOOD_PLIST = {
    "CFBundleDisplayName": {
        "extractionState": "extracted_with_value",
        "localizations": {"en": unit("OpenPult", "new"), "ru": unit("Пульт")},
    },
}
GOOD_PBXPROJ = """
    INFOPLIST_KEY_CFBundleDisplayName = OpenPult;
    INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;
    INFOPLIST_KEY_CFBundleDisplayName = OpenPult;
"""
GOOD_SWIFT = '''import SwiftUI
/// Экран настройки — Russian in a doc comment is fine.
struct V: View {
    var body: some View { Text("Done") } // готово
}
'''


class RepoTestCase(unittest.TestCase):
    def make_repo(self, app=None, kit=None, plist=None, pbxproj=GOOD_PBXPROJ, swift=None):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = pathlib.Path(tmp.name)
        files = {
            "app/Pult/Localizable.xcstrings": catalog(GOOD_APP if app is None else app),
            "app/BraviaKit/Sources/BraviaKit/Resources/Localizable.xcstrings": catalog(GOOD_KIT if kit is None else kit),
            "app/Pult/InfoPlist.xcstrings": catalog(GOOD_PLIST if plist is None else plist),
        }
        for rel, doc in files.items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
        (root / "app/Pult.xcodeproj").mkdir(parents=True)
        (root / "app/Pult.xcodeproj/project.pbxproj").write_text(pbxproj, encoding="utf-8")
        for rel, text in (swift or {"app/Pult/Views/V.swift": GOOD_SWIFT}).items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return root

    def errors(self, root, **kwargs):
        errors, _, _ = cc.run(root, **kwargs)
        return errors

    def assertOneError(self, root, fragment, **kwargs):
        errors = self.errors(root, **kwargs)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn(fragment, errors[0])


class SpecifierTests(unittest.TestCase):
    def test_sequential_and_positional(self):
        self.assertEqual(cc.specifiers("%@ · %lld"), {1: "@", 2: "lld"})
        self.assertEqual(cc.specifiers("%2$@, %1$lld"), {1: "lld", 2: "@"})
        self.assertEqual(cc.specifiers("%.2f V"), {1: "f"})

    def test_percent_escape_is_not_a_specifier(self):
        self.assertEqual(cc.specifiers("100%% done"), {})
        self.assertEqual(cc.specifiers("%lld%%"), {1: "lld"})


class StripCommentsTests(unittest.TestCase):
    def test_comments_are_blanked_and_lines_kept(self):
        code = cc.strip_comments('let a = 1 // один\n/* два\n три */ let b = 2\n')
        self.assertEqual(code.count("\n"), 3)
        self.assertNotRegex(code, cc.CYRILLIC)
        self.assertIn("let b = 2", code)

    def test_nested_block_comments(self):
        code = cc.strip_comments("/* a /* б */ в */ x")
        self.assertEqual(code.strip(), "x")

    def test_slashes_in_strings_are_not_comments(self):
        code = cc.strip_comments('let u = "http://host/путь" // коммент\n')
        self.assertIn('"http://host/путь"', code)
        self.assertNotIn("коммент", code)

    def test_raw_multiline_and_interpolated_strings(self):
        source = (
            'let r = #"a " // б"#\n'
            'let m = """\n  "в" // г\n  """\n'
            'let i = "\\(f("//")) д" // е\n'
            'let e = "\\"ж\\"" // з\n'
        )
        code = cc.strip_comments(source)
        for kept in ("б", "г", "д", "ж"):
            self.assertIn(kept, code)
        for dropped in ("е", "з"):
            self.assertNotIn(dropped, code)

    def test_unterminated_string_is_reported(self):
        with self.assertRaises(ValueError):
            cc.strip_comments('let a = "oops\nlet b = 1\n')


class CatalogTests(RepoTestCase):
    def test_good_repository_passes(self):
        self.assertEqual(self.errors(self.make_repo()), [])

    def test_missing_translation(self):
        app = dict(GOOD_APP, Close={})
        self.assertOneError(self.make_repo(app=app), "'Close' [ru]: not translated")

    def test_translation_must_be_marked_translated(self):
        app = dict(GOOD_APP, Close={"localizations": {"ru": unit("Закрыть", "needs_review")}})
        self.assertOneError(self.make_repo(app=app), "expected 'translated'")

    def test_should_translate_false_needs_no_translation(self):
        app = dict(GOOD_APP, **{"HDMI %lld": {"shouldTranslate": False}})
        self.assertEqual(self.errors(self.make_repo(app=app)), [])

    def test_specifier_mismatch(self):
        app = dict(GOOD_APP, **{"Invalid TV address: %@": {"localizations": {"ru": unit("Неверный адрес: %lld")}}})
        self.assertOneError(self.make_repo(app=app), "format specifiers %1$lld differ from %1$@")

    def test_lost_specifier(self):
        app = dict(GOOD_APP, **{"Code %lld of %lld": {"localizations": {"ru": unit("Код %lld")}}})
        self.assertOneError(self.make_repo(app=app), "differ from %1$lld, %2$lld")

    def test_russian_plural_needs_all_forms(self):
        kit = dict(GOOD_KIT)
        kit["Updated codes for %lld buttons"] = {"localizations": {
            "en": GOOD_KIT["Updated codes for %lld buttons"]["localizations"]["en"],
            "ru": plural(one="%lld кнопка", many="%lld кнопок", other="%lld кнопки"),
        }}
        self.assertOneError(self.make_repo(kit=kit), "plural lacks few")

    def test_plural_form_specifiers_are_checked(self):
        kit = dict(GOOD_KIT)
        kit["Updated codes for %lld buttons"] = {"localizations": {
            "en": GOOD_KIT["Updated codes for %lld buttons"]["localizations"]["en"],
            "ru": plural(one="Одна кнопка", few="%lld кнопки", many="%lld кнопок", other="%lld кнопки"),
        }}
        self.assertOneError(self.make_repo(kit=kit), "[ru] [one]: format specifiers none")

    def test_english_plural_needs_a_russian_plural(self):
        kit = dict(GOOD_KIT)
        kit["Updated codes for %lld buttons"] = {"localizations": {
            "en": GOOD_KIT["Updated codes for %lld buttons"]["localizations"]["en"],
            "ru": unit("Обновлено кнопок: %lld"),
        }}
        self.assertOneError(self.make_repo(kit=kit), "the translation has none")

    def test_english_plural_needs_one_and_other(self):
        kit = {"%lld buttons": {"localizations": {
            "en": plural(other="%lld buttons"),
            "ru": plural(one="%lld кнопка", few="%lld кнопки", many="%lld кнопок", other="%lld кнопки"),
        }}}
        self.assertOneError(self.make_repo(kit=kit), "[en]: plural lacks one")

    def test_source_language_must_be_english(self):
        root = self.make_repo()
        path = root / "app/Pult/Localizable.xcstrings"
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["sourceLanguage"] = "ru"
        path.write_text(json.dumps(doc), encoding="utf-8")
        self.assertOneError(root, "sourceLanguage is 'ru'")

    def test_required_catalog_missing(self):
        root = self.make_repo()
        (root / "app/Pult/InfoPlist.xcstrings").unlink()
        self.assertOneError(root, "app/Pult/InfoPlist.xcstrings: missing")


class SourceTests(RepoTestCase):
    def test_cyrillic_in_code_is_reported_with_its_line(self):
        swift = {"app/Pult/Views/V.swift": GOOD_SWIFT + 'let t = Text("Готово")\n'}
        self.assertOneError(self.make_repo(swift=swift), "app/Pult/Views/V.swift:6: Cyrillic outside comments")

    def test_braviakit_sources_are_scanned(self):
        swift = {"app/BraviaKit/Sources/BraviaKit/E.swift": 'let m = "Ошибка"\n'}
        self.assertOneError(self.make_repo(swift=swift), "E.swift:1")

    def test_build_folders_are_skipped(self):
        swift = {"app/Pult/build/G.swift": 'let m = "Ошибка"\n'}
        self.assertEqual(self.errors(self.make_repo(swift=swift)), [])

    @mock.patch.object(cc, "ALLOW_CYRILLIC", {
        "app/Pult/Views/IRSetupViews.swift", "app/BraviaKit/Sources/BraviaKit/ProfileCatalog.swift"})
    def test_allow_list(self):
        swift = {"app/Pult/Views/IRSetupViews.swift": 'let m = "Пульт"\n'}
        root = self.make_repo(swift=swift)
        errors, notes, _ = cc.run(root)
        self.assertEqual(errors, [])
        self.assertTrue(any("IRSetupViews.swift: Russian text allowed" in note for note in notes), notes)
        self.assertTrue(any("ProfileCatalog.swift has no Russian text" in note for note in notes), notes)


class InfoPlistTests(RepoTestCase):
    def test_build_setting_must_be_english(self):
        pbxproj = GOOD_PBXPROJ + '    INFOPLIST_KEY_NSLocalNetworkUsageDescription = "Нужно для поиска ТВ.";\n'
        self.assertOneError(self.make_repo(pbxproj=pbxproj), "must be English")

    def test_build_setting_must_match_the_catalog(self):
        pbxproj = GOOD_PBXPROJ.replace("= OpenPult;", '= "Open Pult";', 1)
        self.assertOneError(self.make_repo(pbxproj=pbxproj), "differs from the English value")

    def test_quoted_settings_are_unescaped(self):
        settings = cc.pbxproj_settings('INFOPLIST_KEY_A = "Say \\"hi\\"";\nINFOPLIST_KEY_B = Plain;\n')
        self.assertEqual(settings, [("A", 'Say "hi"'), ("B", "Plain")])


class ExtractedTests(RepoTestCase):
    def write_stringsdata(self, root, source_rel, keys):
        derived = root / "DerivedData" / "Objects-normal" / "arm64"
        derived.mkdir(parents=True, exist_ok=True)
        data = {
            "source": str(root / source_rel),
            "tables": {"Localizable": [
                {"comment": "", "key": key, "location": {"startingColumn": 1, "startingLine": n}}
                for n, key in enumerate(keys, 1)
            ]},
        }
        (derived / (pathlib.Path(source_rel).stem + ".stringsdata")).write_text(json.dumps(data), encoding="utf-8")
        return root / "DerivedData"

    def test_extracted_keys_must_be_in_the_nearest_catalog(self):
        root = self.make_repo()
        derived = self.write_stringsdata(root, "app/Pult/Views/V.swift", ["Done", "Forgotten"])
        self.assertOneError(root, "V.swift:2: 'Forgotten' is missing from app/Pult/Localizable.xcstrings", stringsdata=derived)

    def test_package_sources_use_their_resources_catalog(self):
        root = self.make_repo(swift={"app/BraviaKit/Sources/BraviaKit/E.swift": "let x = 1\n"})
        derived = self.write_stringsdata(root, "app/BraviaKit/Sources/BraviaKit/E.swift", ["Bluetooth error: %@"])
        self.assertEqual(self.errors(root, stringsdata=derived), [])

    @mock.patch.object(cc, "ALLOW_CYRILLIC", {"app/Pult/Views/IRSetupViews.swift"})
    def test_allow_listed_sources_are_skipped(self):
        root = self.make_repo()
        derived = self.write_stringsdata(root, "app/Pult/Views/IRSetupViews.swift", ["Бренды"])
        self.assertEqual(self.errors(root, stringsdata=derived), [])


class RepositoryTests(unittest.TestCase):
    def test_repository_catalogs_pass(self):
        errors, _, _ = cc.run(cc.ROOT)
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
